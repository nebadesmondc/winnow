function Invoke-WinnowClean {
    <#
    .SYNOPSIS
    Removes findings from a scan. Supports -WhatIf and -Confirm.

    .DESCRIPTION
    Acts only on findings from a scan, never on a path. Without -Id it removes
    every Clean finding. With -Id it removes the named findings; Your call
    findings go to the Recycle Bin. Each path is checked again for live use
    right before it is removed.

    .PARAMETER Report
    A report from Get-WinnowReport. Omit to run a fresh scan.

    .PARAMETER Id
    Finding ids to act on.

    .PARAMETER Force
    Lifts the size limits on a plan. Never bypasses the guard.

    .EXAMPLE
    Invoke-WinnowClean -WhatIf

    .EXAMPLE
    $r = Get-WinnowReport
    Invoke-WinnowClean -Report $r -Id w-3f9a2c
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [object]$Report,
        [string[]]$Id,
        [switch]$Force,
        [switch]$Quiet
    )

    $freshScan = (-not $Report)
    if ($freshScan) { $Report = Invoke-WinnowScan -NoProgress:$Quiet }

    $selected = @()
    if ($Id) {
        foreach ($m in $Id) {
            $hit = @($Report.Findings | Where-Object { $_.Id -eq $m }) | Select-Object -First 1
            if (-not $hit) {
                Write-Warning "Winnow: '$m' is not in the scan. Run winnow to see the current ids."
                continue
            }
            $why = Get-WinnowNotActionableReason -Finding $hit -ById
            if ($why) {
                Write-Warning "Winnow: '$m' ($($hit.Title)) will not be removed: $why."
                continue
            }
            $selected += $hit
        }
    } else {
        $selected = @($Report.Findings | Where-Object { Test-WinnowFindingActionable -Finding $_ })
    }

    if ($selected.Count -eq 0) {
        if (-not $Quiet) { Write-WinnowLine '  Nothing to do.' -Style Dim }
        return
    }

    $plannedBytes = 0
    $plannedFiles = 0
    foreach ($f in $selected) { $plannedBytes += $f.Bytes; $plannedFiles += $f.Files }

    # Limits that suggest a bug rather than intent
    if (-not $Force) {
        $stop = $null

        if ($plannedFiles -gt 250000) {
            $stop = "the plan touches $plannedFiles files, which suggests a runaway rule"
        }

        foreach ($g in ($selected | Group-Object RuleId)) {
            $rb = 0
            foreach ($f in $g.Group) { $rb += $f.Bytes }
            if ($rb -gt 25GB) {
                $stop = "rule '$($g.Name)' alone accounts for $(Format-WinnowBytes $rb), which suggests a path-resolution bug"
            }
        }

        foreach ($v in $Report.Volumes) {
            $used = $v.TotalBytes - $v.FreeBytes
            $onVol = 0
            foreach ($f in $selected) {
                if ($f.Path -and $f.Path.Substring(0, 1).ToUpper() -eq $v.Letter) { $onVol += $f.Bytes }
            }
            if ($used -gt 0 -and ($onVol / $used) -gt 0.60) {
                $stop = "the plan would remove $([math]::Round(100 * $onVol / $used))% of the used space on $($v.Letter): "
            }
        }

        if ($stop) {
            Write-WinnowLine "  Refusing to proceed: $stop." -Style Bad
            Write-WinnowLine '  Check the items with winnow explain. Use -Force only if this is intended.' -Style Dim
            return
        }
    }

    $planLabel = '{0} item(s), {1}' -f $selected.Count, (Format-WinnowBytes $plannedBytes).Trim()
    if (-not $PSCmdlet.ShouldProcess($planLabel, 'Remove')) {
        if (-not $Quiet) {
            Write-WinnowLine "  Would remove $planLabel. Nothing was changed." -Style Dim
            foreach ($f in ($selected | Sort-Object Bytes -Descending)) {
                Write-WinnowLine ('    {0}  {1}' -f (Format-WinnowBytes $f.Bytes), (Format-WinnowPath $f.Path)) -Style Dim
            }
        }
        return
    }

    $before = @{}
    foreach ($v in (Get-WinnowVolumeInfo)) { $before[$v.Letter] = $v.FreeBytes }

    # Live state can change between the scan and now.
    Reset-WinnowProcessMap
    $inFlight = @(Get-WinnowUpdateInFlight)

    $results = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($f in ($selected | Sort-Object Bytes -Descending)) {
        $n++
        if (-not $Quiet) {
            Write-Progress -Activity 'Winnow' -Status $f.Title -PercentComplete ([int](100 * $n / $selected.Count))
        }

        $outcome = $null
        $hold = Get-WinnowHoldReason -Path $f.Path -RequiresClosed @($f.RequiresClosed) -InFlight $inFlight
        if ($hold) {
            $outcome = [pscustomobject]@{
                Path = $f.Path; Removed = $false; BytesClaimed = [double]0; BytesLeft = $f.Bytes
                Reason = "held back: $hold"; Method = 'None'
            }
        }

        # The tool's own command keeps its metadata consistent.
        if (-not $outcome -and $f.Action -eq 'VendorCli') {
            $step = @($f.Reclaim | Where-Object { $_.Type -eq 'VendorCli' })[0]
            if ($step) {
                $pre = [double](Measure-WinnowTree -Path $f.Path).Bytes
                $null = Invoke-WinnowCli -Command $step.Command -Arguments $step.Args -TimeoutSec 120
                $after = Measure-WinnowTree -Path $f.Path
                $claimed = [math]::Max([double]0, $pre - [double]$after.Bytes)
                # Nothing freed: fall back to removal.
                if ($claimed -gt 0) {
                    $outcome = [pscustomobject]@{
                        Path = $f.Path; Removed = $true; BytesClaimed = $claimed
                        BytesLeft = [double]$after.Bytes; Reason = $null
                        Method = "VendorCli:$($step.Command)"
                    }
                }
            }
        }

        if (-not $outcome) {
            $outcome = Remove-WinnowPath -Path $f.Path -AllowsInsideProject @($f.AllowsInsideProject) `
                -Recycle:($f.Verdict -eq 'YourCall') -Confirm:$false
        }

        $results.Add([pscustomobject]@{
            Id           = $f.Id
            RuleId       = $f.RuleId
            Title        = $f.Title
            Path         = $f.Path
            Verdict      = $f.Verdict
            Removed      = $outcome.Removed
            BytesClaimed = $outcome.BytesClaimed
            BytesLeft    = $outcome.BytesLeft
            Method       = $outcome.Method
            Reason       = $outcome.Reason
        })
    }
    if (-not $Quiet) { Write-Progress -Activity 'Winnow' -Completed }

    $after = @{}
    foreach ($v in (Get-WinnowVolumeInfo)) { $after[$v.Letter] = $v.FreeBytes }

    $deltas = New-Object System.Collections.Generic.List[object]
    foreach ($k in $before.Keys) {
        $d = $after[$k] - $before[$k]
        if ([math]::Abs($d) -lt 1MB) { continue }
        $deltas.Add([pscustomobject]@{ Letter = $k; FreedBytes = $d })
    }

    $claimedBytes = [double]0
    $recycledBytes = [double]0
    foreach ($r in $results) {
        $claimedBytes += [double]$r.BytesClaimed
        if ($r.Method -eq 'RecycleBin') { $recycledBytes += [double]$r.BytesLeft }
    }

    $summary = [pscustomobject]@{
        RunId         = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
        ScanRunId     = $Report.RunId
        WhenUtc       = (Get-Date).ToUniversalTime()
        Planned       = $selected.Count
        Removed       = @($results | Where-Object { $_.Removed }).Count
        LeftBehind    = @($results | Where-Object { -not $_.Removed })
        PlannedBytes  = $plannedBytes     # from the scan
        ClaimedBytes  = $claimedBytes     # measured on the items
        RecycledBytes = $recycledBytes    # in the Recycle Bin, still on the drive
        VolumeDeltas  = $deltas           # measured on the drives
        Results       = $results
    }

    Write-WinnowManifest -Summary $summary

    if (-not $Quiet) { Show-WinnowCleanSummary -Summary $summary }
    return $summary
}

function Show-WinnowCleanSummary {
    param([Parameter(Mandatory)][object]$Summary)

    Write-Host ''
    foreach ($d in $Summary.VolumeDeltas) {
        if ($d.FreedBytes -gt 0) {
            Write-WinnowLine ('  {0}:  {1} freed' -f $d.Letter, (Format-WinnowBytes $d.FreedBytes).Trim()) -Style Good
        } else {
            Write-WinnowLine ('  {0}:  {1} change' -f $d.Letter, (Format-WinnowBytes $d.FreedBytes).Trim()) -Style Dim
        }
    }
    if ($Summary.VolumeDeltas.Count -eq 0) {
        Write-WinnowLine '  No measurable change in free space.' -Style Dim
    }

    Write-WinnowLine ('  {0} of {1} item(s) removed.' -f $Summary.Removed, $Summary.Planned) -Style Normal
    if ($Summary.RecycledBytes -gt 0) {
        Write-WinnowLine ('  {0} went to the Recycle Bin; empty it to get that space back.' -f (Format-WinnowBytes $Summary.RecycledBytes).Trim()) -Style Normal
    }

    if ($Summary.LeftBehind.Count -gt 0) {
        Write-Host ''
        Write-WinnowLine '  Left behind:' -Style Warn
        foreach ($l in $Summary.LeftBehind) {
            Write-WinnowLine ('    {0}  {1}' -f (Format-WinnowPath $l.Path), $l.Reason) -Style Dim
        }
    }
    Write-Host ''
}

function Write-WinnowManifest {
    <#
    .SYNOPSIS
    Writes the run record to %LOCALAPPDATA%\Winnow\runs.
    #>
    param([Parameter(Mandatory)][object]$Summary)

    $base = Get-WinnowEnvRoot -Base 'LOCALAPPDATA'
    if (-not $base) { return }
    $dir = Join-Path (Join-Path $base 'Winnow') 'runs'
    try {
        [void][System.IO.Directory]::CreateDirectory((ConvertTo-WinnowLongPath $dir))
        $file = Join-Path $dir ($Summary.RunId + '.json')
        $Summary | ConvertTo-Json -Depth 6 | Out-File -LiteralPath $file -Encoding utf8
        Write-Verbose "Winnow: manifest written to $file"
    } catch {
        Write-Warning "Winnow: could not write manifest: $($_.Exception.Message)"
    }
}

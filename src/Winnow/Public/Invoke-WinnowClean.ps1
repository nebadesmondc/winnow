function Invoke-WinnowClean {
    <#
    .SYNOPSIS
    Removes selected findings from a scan. Supports -WhatIf and -Confirm.

    .DESCRIPTION
    Acts only on findings from a scan, never on a path. Without -Tier or -Id it
    acts on Transient and Rebuildable findings.

    .PARAMETER Report
    A report object from Get-WinnowReport -AsObject. Omit to run a fresh scan.

    .PARAMETER Id
    Finding ids to act on, from the same scan as -Report.

    .PARAMETER Tier
    Which tiers to act on. Defaults to Transient and Rebuildable.

    .PARAMETER Force
    Lifts the size limits on a plan. Never bypasses the guard.

    .EXAMPLE
    Invoke-WinnowClean -WhatIf

    .EXAMPLE
    Invoke-WinnowClean -Tier Transient

    .EXAMPLE
    $r = Get-WinnowReport -AsObject
    Invoke-WinnowClean -Report $r -Id wnw-3f9a2c,wnw-88b1de
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [object]$Report,
        [string[]]$Id,
        [ValidateSet('Transient', 'Rebuildable', 'Orphaned', 'Superseded')]
        [string[]]$Tier = @('Transient', 'Rebuildable'),
        [switch]$Force,
        [switch]$Quiet
    )

    $freshScan = (-not $Report)
    if ($freshScan) { $Report = Invoke-WinnowScan }

    $selected = @($Report.Findings | Where-Object { Test-WinnowFindingActionable -Finding $_ })
    if ($Id) {
        $selected = @($selected | Where-Object { $Id -contains $_.Id })
        foreach ($m in $Id) {
            $hit = @($Report.Findings | Where-Object { $_.Id -eq $m }) | Select-Object -First 1
            if ($hit) {
                $why = Get-WinnowNotActionableReason -Finding $hit
                if ($why) {
                    Write-Warning "Winnow: '$m' ($($hit.Title)) will not be cleaned: $why."
                }
            } elseif ($freshScan) {
                Write-Warning "Winnow: '$m' is not in the scan just run. Ids belong to the scan that showed them; pass that scan with -Report, or scan again and use the new id."
            } else {
                Write-Warning "Winnow: '$m' is not in this report."
            }
        }
    } else {
        $selected = @($selected | Where-Object { $Tier -contains $_.Tier })
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

        $byRule = $selected | Group-Object RuleId
        foreach ($g in $byRule) {
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
            Write-WinnowLine '  Review with Get-WinnowReport -All. Use -Force only if this is genuinely intended.' -Style Dim
            return
        }
    }

    # One confirmation for the whole plan
    $planLabel = '{0} item(s), {1}' -f $selected.Count, (Format-WinnowBytes $plannedBytes).Trim()
    if (-not $PSCmdlet.ShouldProcess($planLabel, 'Reclaim')) {
        if (-not $Quiet) {
            Write-WinnowLine "  Would reclaim $planLabel. Nothing was changed." -Style Dim
            foreach ($f in ($selected | Sort-Object Bytes -Descending)) {
                Write-WinnowLine ('    {0}  {1}' -f (Format-WinnowBytes $f.Bytes), (Format-WinnowPath $f.Path)) -Style Dim
            }
        }
        return
    }

    $before = @{}
    foreach ($v in (Get-WinnowVolumeInfo)) { $before[$v.Letter] = $v.FreeBytes }

    $results = New-Object System.Collections.Generic.List[object]
    $n = 0
    foreach ($f in ($selected | Sort-Object Bytes -Descending)) {
        $n++
        if (-not $Quiet) {
            Write-Progress -Activity 'Winnow reclaim' -Status $f.Title `
                -PercentComplete ([int](100 * $n / $selected.Count))
        }

        $outcome = $null

        # The tool's own command keeps its metadata consistent.
        if ($f.Action -eq 'VendorCli') {
            $step = @($f.Reclaim | Where-Object { $_.Type -eq 'VendorCli' })[0]
            if ($step) {
                $pre = [double](Measure-WinnowTree -Path $f.Path).Bytes
                $null = Invoke-WinnowCli -Command $step.Command -Arguments $step.Args -TimeoutSec 120
                $after = Measure-WinnowTree -Path $f.Path
                $claimed = $pre - [double]$after.Bytes
                if ($claimed -lt 0) { $claimed = 0 }
                $outcome = [pscustomobject]@{
                    Path = $f.Path; Removed = ($claimed -gt 0)
                    BytesClaimed = $claimed
                    BytesLeft = [double]$after.Bytes
                    Reason = $null
                    Method = "VendorCli:$($step.Command)"
                }
                # Nothing freed: fall back to removal.
                if ($claimed -le 0) { $outcome = $null }
            }
        }

        if (-not $outcome) {
            $outcome = Remove-WinnowPath -Path $f.Path `
                -AllowsInsideProject @($f.AllowsInsideProject) -Confirm:$false
        }

        $results.Add([pscustomobject]@{
            Id           = $f.Id
            RuleId       = $f.RuleId
            Title        = $f.Title
            Path         = $f.Path
            Tier         = $f.Tier
            Removed      = $outcome.Removed
            BytesClaimed = $outcome.BytesClaimed
            BytesLeft    = $outcome.BytesLeft
            Method       = $outcome.Method
            Reason       = $outcome.Reason
        })
    }
    if (-not $Quiet) { Write-Progress -Activity 'Winnow reclaim' -Completed }

    $after = @{}
    foreach ($v in (Get-WinnowVolumeInfo)) { $after[$v.Letter] = $v.FreeBytes }

    $deltas = New-Object System.Collections.Generic.List[object]
    foreach ($k in $before.Keys) {
        $d = $after[$k] - $before[$k]
        if ([math]::Abs($d) -lt 1MB) { continue }
        $deltas.Add([pscustomobject]@{ Letter = $k; FreedBytes = $d })
    }

    $claimedBytes = [double]0
    foreach ($r in $results) { $claimedBytes += [double]$r.BytesClaimed }

    $summary = [pscustomobject]@{
        RunId          = $Report.RunId
        Caller         = 'cli'
        WhenUtc        = (Get-Date).ToUniversalTime()
        Planned        = $selected.Count
        Removed        = @($results | Where-Object { $_.Removed }).Count
        LeftBehind     = @($results | Where-Object { -not $_.Removed })
        PlannedBytes   = $plannedBytes     # from the scan
        ClaimedBytes   = $claimedBytes     # measured on the items
        VolumeDeltas   = $deltas           # measured on the drives
        Results        = $results
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
            Write-WinnowLine ('  {0}:  {1} returned to the volume' -f $d.Letter, (Format-WinnowBytes $d.FreedBytes)) -Style Good
        } else {
            Write-WinnowLine ('  {0}:  {1} change' -f $d.Letter, (Format-WinnowBytes $d.FreedBytes)) -Style Dim
        }
    }
    if ($Summary.VolumeDeltas.Count -eq 0) {
        Write-WinnowLine '  No measurable change in volume free space.' -Style Dim
    }

    Write-WinnowLine ('  {0} of {1} item(s) removed; {2} measured on them as they went.' -f `
        $Summary.Removed, $Summary.Planned, (Format-WinnowBytes $Summary.ClaimedBytes).Trim()) -Style Normal

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

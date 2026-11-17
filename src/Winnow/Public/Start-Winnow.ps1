function Start-Winnow {
    <#
    .SYNOPSIS
    Guided cleanup: scans, shows the cost of each group and asks once per tier
    before removing anything.

    .PARAMETER Yes
    Accept the risk-free tiers (Transient, Rebuildable) without prompting.
    Tiers that involve judgement are still asked about.

    .EXAMPLE
    Start-Winnow

    .EXAMPLE
    Start-Winnow -Yes
    #>
    [CmdletBinding()]
    param(
        [switch]$Yes,
        [int]$Top = 8
    )

    $interactive = $true
    try {
        if ($Host.Name -eq 'Default Host' -or -not $Host.UI.RawUI) { $interactive = $false }
    } catch { $interactive = $false }

    if (-not $interactive -and -not $Yes) {
        Write-WinnowLine '  Start-Winnow needs an interactive console. Use Get-WinnowReport, or pass -Yes.' -Style Warn
        return
    }

    Write-Host ''
    Write-WinnowLine '  Scanning. Nothing is changed during a scan.' -Style Dim
    $report = Invoke-WinnowScan

    Show-WinnowReport -Report $report -Top $Top

    $groups = Get-WinnowTierSummary -Findings $report.Findings
    $actionable = @($groups | Where-Object { $script:WinnowActionableTiers -contains $_.Tier -and $_.Actionable.Count -gt 0 })

    if ($actionable.Count -eq 0) {
        Write-WinnowLine '  Nothing safe to reclaim was found.' -Style Dim
        Show-WinnowReportOnly -Report $report
        return
    }

    $chosen = New-Object System.Collections.Generic.List[string]

    foreach ($g in $actionable) {
        $bytes = 0
        foreach ($f in $g.Actionable) { $bytes += $f.Bytes }

        Write-WinnowLine ('  ' + ('-' * 74)) -Style Dim
        Write-WinnowLine ('  {0}  -  {1} across {2} item(s)' -f $g.Tier, (Format-WinnowBytes $bytes), $g.Actionable.Count) -Style Accent

        switch ($g.Tier) {
            'Transient' {
                Write-WinnowLine '  Caches applications rebuild by themselves. No user-visible effect.' -Style Dim
            }
            'Rebuildable' {
                Write-WinnowLine '  Caches that regenerate at a cost: a re-download or a slower first build.' -Style Dim
            }
            'Orphaned' {
                Write-WinnowLine '  Data belonging to software that is no longer installed. Deleted; it cannot be restored.' -Style Dim
            }
            'Superseded' {
                Write-WinnowLine '  Older versions of software that is still installed. Deleted; it cannot be restored.' -Style Dim
            }
        }

        $seen = @{}
        foreach ($f in $g.Actionable) {
            if (-not $f.Consequence) { continue }
            if ($seen.ContainsKey($f.Consequence)) { continue }
            $seen[$f.Consequence] = $true
            Write-WinnowLine ('    - {0}' -f $f.Consequence) -Style Normal
        }

        $autoYes = ($Yes -and ($g.Tier -eq 'Transient' -or $g.Tier -eq 'Rebuildable'))
        $answer = 'y'
        if (-not $autoYes) {
            $answer = Read-WinnowChoice -Prompt ('  Reclaim this {0}?' -f (Format-WinnowBytes $bytes)) `
                                        -Choices @('y', 'n', 'l', 'q') `
                                        -Help 'y = yes, n = skip this group, l = list every item, q = quit without changes'
        } else {
            Write-WinnowLine ('  Accepted automatically (-Yes): {0}' -f (Format-WinnowBytes $bytes)) -Style Good
        }

        if ($answer -eq 'l') {
            foreach ($f in $g.Actionable) {
                Write-WinnowLine ('      {0}  {1}' -f (Format-WinnowBytes $f.Bytes), (Format-WinnowPath $f.Path)) -Style Normal
                foreach ($e in $f.Evidence) { Write-WinnowLine ('                 {0}' -f $e) -Style Dim }
            }
            $answer = Read-WinnowChoice -Prompt ('  Reclaim this {0}?' -f (Format-WinnowBytes $bytes)) `
                                        -Choices @('y', 'n', 'q') `
                                        -Help 'y = yes, n = skip this group, q = quit without changes'
        }

        if ($answer -eq 'q') {
            Write-Host ''
            Write-WinnowLine '  Stopped. Nothing was changed.' -Style Warn
            return
        }
        if ($answer -eq 'y') {
            foreach ($f in $g.Actionable) { $chosen.Add($f.Id) }
        }
    }

    if ($chosen.Count -eq 0) {
        Write-Host ''
        Write-WinnowLine '  Nothing selected. Nothing was changed.' -Style Dim
        Show-WinnowReportOnly -Report $report
        return
    }

    Write-Host ''
    Write-WinnowLine ('  Reclaiming {0} item(s).' -f $chosen.Count) -Style Accent

    $summary = Invoke-WinnowClean -Report $report -Id $chosen.ToArray() -Confirm:$false

    Show-WinnowReportOnly -Report $report

    if ($summary) {
        Write-WinnowLine '  A manifest of exactly what was removed is in %LOCALAPPDATA%\Winnow\runs.' -Style Dim
        Write-Host ''
    }
}

function Read-WinnowChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Choices,
        [string]$Help
    )
    while ($true) {
        Write-Host ''
        if ($Help) { Write-WinnowLine ('  ' + $Help) -Style Dim }
        Write-WinnowLine ($Prompt + ' [' + ($Choices -join '/') + '] ') -Style Head -NoNewline
        $raw = Read-Host
        if ($null -eq $raw) { return 'q' }
        $v = $raw.Trim().ToLower()
        if ([string]::IsNullOrWhiteSpace($v)) { $v = 'n' }   # bare Enter is the safe answer
        if ($Choices -contains $v) { return $v }
        Write-WinnowLine ('  Please answer one of: ' + ($Choices -join ', ')) -Style Warn
    }
}

function Show-WinnowReportOnly {
    <#
    .SYNOPSIS
    Lists report-only items and the admin commands Winnow does not run.
    #>
    param([Parameter(Mandatory)][object]$Report)

    $groups = Get-WinnowTierSummary -Findings $Report.Findings
    $ro = @($groups | Where-Object { $script:WinnowActionableTiers -notcontains $_.Tier })

    Write-Host ''
    Write-WinnowLine ('  ' + ('-' * 74)) -Style Dim
    Write-WinnowLine '  NOT TOUCHED BY WINNOW' -Style Head
    Write-WinnowLine '  These need your judgement or your administrator rights.' -Style Dim
    Write-Host ''

    if ($ro.Count -gt 0) {
        foreach ($g in $ro) {
            Write-WinnowLine ('    {0}  -  {1}' -f $g.Tier, (Format-WinnowBytes $g.Bytes)) -Style Dim
            foreach ($f in ($g.Items | Select-Object -First 5)) {
                Write-WinnowLine ('      {0}  {1}' -f (Format-WinnowBytes $f.Bytes), (Format-WinnowPath $f.Path)) -Style Dim
            }
        }
        Write-Host ''
    }

    Write-WinnowLine '    Elevated steps Winnow will never run for you:' -Style Dim
    Write-WinnowLine '      Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase   (WinSxS)' -Style Dim
    Write-WinnowLine '      powercfg /h off                                                (hibernation file)' -Style Dim
    Write-WinnowLine '      cleanmgr                                                       (Windows Temp, Update cache)' -Style Dim
    Write-Host ''
}

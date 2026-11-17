function Invoke-Winnow {
    <#
    .SYNOPSIS
    Shows where the system drive's space is, explains an item, or cleans.

    .DESCRIPTION
    winnow                 the space map; changes nothing
    winnow explain <id>    what an item is, what removing it costs, the steps
    winnow clean           removes every Clean item, after one yes
    winnow clean <id>      removes the named items; Your call items go to the
                           Recycle Bin

    explain and clean reuse the last scan of this session when it is less than
    30 minutes old; clean checks each item for live use again before removing it.

    .PARAMETER All
    List every item instead of the largest ones.

    .PARAMETER Yes
    Clean without asking.

    .EXAMPLE
    winnow

    .EXAMPLE
    winnow explain pagefile

    .EXAMPLE
    winnow clean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidateSet('explain', 'clean')][string]$Command,
        [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Id,
        [switch]$All,
        [switch]$Yes
    )

    if (-not $Command) {
        Write-WinnowLine '  Scanning. Nothing is changed.' -Style Dim
        $report = Invoke-WinnowScan
        Show-WinnowReport -Report $report -All:$All
        return
    }

    $report = $script:WinnowLastReport
    if (-not $report -or ((Get-Date).ToUniversalTime() - $report.StartedUtc).TotalMinutes -gt 30) {
        Write-WinnowLine '  Scanning. Nothing is changed.' -Style Dim
        $report = Invoke-WinnowScan
    }

    if ($Command -eq 'explain') {
        if (-not $Id) {
            Write-WinnowLine '  Name an item: winnow explain <id>. Run winnow to see the ids.' -Style Warn
            return
        }
        foreach ($i in $Id) {
            $f = @($report.Findings | Where-Object { $_.Id -eq $i }) | Select-Object -First 1
            if ($f) { Show-WinnowExplain -Finding $f }
            else { Write-WinnowLine "  '$i' is not in the scan. Run winnow to see the current ids." -Style Warn }
        }
        return
    }

    # clean
    $plan = @()
    if ($Id) {
        foreach ($i in $Id) {
            $f = @($report.Findings | Where-Object { $_.Id -eq $i }) | Select-Object -First 1
            if ($f) { $plan += $f }
        }
    } else {
        $plan = @($report.Findings | Where-Object { Test-WinnowFindingActionable -Finding $_ })
    }
    $ready = @($plan | Where-Object { Test-WinnowFindingActionable -Finding $_ -ById:([bool]$Id) })

    if ($ready.Count -gt 0 -and -not $Yes) {
        $sum = 0; foreach ($f in $ready) { $sum += $f.Bytes }
        Write-Host ''
        foreach ($f in ($ready | Sort-Object Bytes -Descending)) {
            $where = ''
            if ($f.Verdict -eq 'YourCall') { $where = '  (to the Recycle Bin)' }
            Write-WinnowLine ('  {0,8}  {1}{2}' -f (Format-WinnowSize $f.Bytes), $f.Title, $where) -Style Normal
            Write-WinnowLine ('            {0}' -f (Format-WinnowPath $f.Path)) -Style Dim
        }
        Write-Host ''
        Write-WinnowLine ('  Remove {0} item(s), {1}? [y/N] ' -f $ready.Count, (Format-WinnowSize $sum)) -Style Head -NoNewline
        $answer = Read-Host
        if ($answer -notmatch '^(?i)y(es)?$') {
            Write-WinnowLine '  Nothing was changed.' -Style Dim
            return
        }
    }

    $cleanArgs = @{ Report = $report; Confirm = $false }
    if ($Id) { $cleanArgs['Id'] = $Id }
    Invoke-WinnowClean @cleanArgs | Out-Null
    $script:WinnowLastReport = $null
}

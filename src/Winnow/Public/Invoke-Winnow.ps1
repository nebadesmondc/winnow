function Invoke-Winnow {
    <#
    .SYNOPSIS
    Shows where the system drive's space is, explains an item, cleans, or
    moves things to another drive.

    .DESCRIPTION
    winnow                 the space map; changes nothing
    winnow explain <id>    what an item is, what removing it costs, the steps
    winnow clean           removes every Clean item, after one yes
    winnow clean <id>      removes the named items; Your call items go to the
                           Recycle Bin
    winnow move            lists what can move to another drive
    winnow move <id>       moves it, after one yes; -To picks the folder
    winnow undo [<id>]     reverses the last move, or the named one

    explain, clean and move reuse the last scan of this session when it is
    less than 30 minutes old; clean and move check each item for live use
    again before acting.

    .PARAMETER All
    List every item instead of the largest ones.

    .PARAMETER To
    The folder a move goes to: empty or new, on another fixed drive.

    .PARAMETER Yes
    Act without asking.

    .EXAMPLE
    winnow

    .EXAMPLE
    winnow explain pagefile

    .EXAMPLE
    winnow move npm -To E:\Caches\npm
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][ValidateSet('explain', 'clean', 'move', 'undo')][string]$Command,
        [Parameter(Position = 1, ValueFromRemainingArguments)][string[]]$Id,
        [switch]$All,
        [string]$To,
        [switch]$Yes
    )

    if (-not $Command) {
        Write-WinnowLine '  Scanning. Nothing is changed.' -Style Dim
        $report = Invoke-WinnowScan
        Show-WinnowReport -Report $report -All:$All
        return
    }

    if ($Command -eq 'undo') {
        $rec = $null
        if ($Id) { $rec = @(Get-WinnowMoveRecord -Id $Id[0] -State 'done')[0] }
        else { $rec = @(Get-WinnowMoveRecord -State 'done')[0] }
        if (-not $rec) {
            Write-WinnowLine '  Nothing to undo.' -Style Dim
            return
        }
        Show-WinnowUndoPlan -Record $rec
        $why = Get-WinnowUndoProblem -Record $rec
        if ($why) {
            Write-WinnowLine "    Cannot undo now: $why." -Style Warn
            Write-Host ''
            return
        }
        if (-not $Yes -and -not (Confirm-WinnowPlan -Question 'Move it back?')) { return }
        Undo-WinnowMove -Id $rec.MoveId -Confirm:$false | Out-Null
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
            if ($f) { Show-WinnowExplain -Finding $f -Movable (Get-WinnowMovableFor -Finding $f -Movable @($report.Movable)) }
            else { Write-WinnowLine "  '$i' is not in the scan. Run winnow to see the current ids." -Style Warn }
        }
        return
    }

    if ($Command -eq 'move') {
        if (-not $Id) {
            Show-WinnowMoveList -Report $report
            return
        }
        if ($To -and $Id.Count -gt 1) {
            Write-WinnowLine '  -To names one folder; move one item at a time with it.' -Style Warn
            return
        }
        $plans = @()
        foreach ($i in $Id) {
            $m = @($report.Movable | Where-Object { $_.Id -eq $i })[0]
            if (-not $m) {
                Write-WinnowLine "  '$i' cannot move. winnow move lists what can." -Style Warn
                continue
            }
            $plan = Get-WinnowMovePlan -Movable $m -To $To
            Show-WinnowMovePlan -Plan $plan
            if (-not $plan.Problem -and $m.Kind -ne 'Guided') { $plans += $plan }
        }
        if ($plans.Count -eq 0) { return }
        if (-not $Yes) {
            $q = 'Move it?'
            if ($plans.Count -gt 1) { $q = "Move these $($plans.Count)?" }
            if (-not (Confirm-WinnowPlan -Question $q)) { return }
        }
        foreach ($p in $plans) {
            Invoke-WinnowMove -Report $report -Id $p.Movable.Id -To $p.Destination -Confirm:$false | Out-Null
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
        if (-not (Confirm-WinnowPlan -Question ('Remove {0} item(s), {1}?' -f $ready.Count, (Format-WinnowSize $sum)))) { return }
    }

    $cleanArgs = @{ Report = $report; Confirm = $false }
    if ($Id) { $cleanArgs['Id'] = $Id }
    Invoke-WinnowClean @cleanArgs | Out-Null
    $script:WinnowLastReport = $null
}

function Confirm-WinnowPlan {
    # One yes for the whole plan; anything else, Enter included, is no.
    param([Parameter(Mandatory)][string]$Question)
    Write-WinnowLine "  $Question [y/N] " -Style Head -NoNewline
    $answer = Read-Host
    if ($answer -match '^(?i)y(es)?$') { return $true }
    Write-WinnowLine '  Nothing was changed.' -Style Dim
    return $false
}

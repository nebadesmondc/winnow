function Invoke-WinnowMove {
    <#
    .SYNOPSIS
    Moves a tool cache or a WSL distribution off the system drive. Supports
    -WhatIf and -Confirm.

    .DESCRIPTION
    A tool cache is copied to a new folder only you can open, the tool's
    environment variable is pointed at it for your account, and the tool is
    asked where its cache is. Only when it names the new folder is the old one
    deleted; until then any failure puts everything back.

    A WSL distribution is stopped and moved by WSL itself (wsl --manage
    --move), then started once to check it works.

    Docker Desktop moves its own disk; for it, this shows the steps.

    Every move writes a record to %LOCALAPPDATA%\Winnow\moves that
    Undo-WinnowMove reverses.

    .PARAMETER Id
    What to move, as winnow move lists it: npm, gradle, wsl-ubuntu-24.04.

    .PARAMETER To
    The folder to move it to: empty or new, on another fixed drive. By default
    <drive>:\DevCache\<id> or <drive>:\WSL\<name> on the drive with most room.

    .EXAMPLE
    Invoke-WinnowMove npm -WhatIf

    .EXAMPLE
    Invoke-WinnowMove gradle -To E:\Caches\gradle
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [string]$To,
        [object]$Report,
        [switch]$Quiet
    )

    if (-not $Report) { $Report = Invoke-WinnowScan -NoProgress:$Quiet }
    $m = @($Report.Movable | Where-Object { $_.Id -eq $Id })[0]
    if (-not $m) {
        Write-Warning "Winnow: '$Id' is not something that can move. Run winnow move to see what can."
        return
    }

    $plan = Get-WinnowMovePlan -Movable $m -To $To
    if ($plan.Problem) {
        Write-Warning "Winnow: $($m.Title) will not be moved: $($plan.Problem)."
        return
    }
    if ($m.Kind -eq 'Guided') {
        if (-not $Quiet) { Show-WinnowMovePlan -Plan $plan }
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($m.Title) to $($plan.Destination)", 'Move')) {
        if (-not $Quiet) { Write-WinnowLine "  Would move $($m.Title) to $($plan.Destination). Nothing was changed." -Style Dim }
        return
    }

    if ($m.Kind -eq 'Wsl') { $rec = Move-WinnowWslHome -Plan $plan }
    else { $rec = Move-WinnowVariableHome -Plan $plan }
    $script:WinnowLastReport = $null

    if (-not $Quiet) { Show-WinnowMoveResult -Record $rec }
    return $rec
}

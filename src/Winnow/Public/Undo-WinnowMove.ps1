function Undo-WinnowMove {
    <#
    .SYNOPSIS
    Reverses a move made by Invoke-WinnowMove. Supports -WhatIf and -Confirm.

    .DESCRIPTION
    A tool cache is copied back, the environment variable is restored to what
    it was before the move, the tool is asked where its cache is, and then the
    moved copy is deleted. A WSL distribution is moved back by WSL.

    .PARAMETER Id
    The item (npm, wsl-ubuntu-24.04) or the move id from the record. Without
    it, the most recent move is undone.

    .EXAMPLE
    Undo-WinnowMove npm -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Position = 0)][string]$Id,
        [switch]$Quiet
    )

    $rec = @(Get-WinnowMoveRecord -Id $Id -State 'done')[0]
    if (-not $rec) {
        if (-not $Quiet) { Write-WinnowLine '  Nothing to undo.' -Style Dim }
        return
    }

    $why = Get-WinnowUndoProblem -Record $rec
    if ($why) {
        Write-Warning "Winnow: the move of $($rec.Title) will not be undone: $why."
        return
    }
    if (-not $PSCmdlet.ShouldProcess("$($rec.Title) back to $($rec.From)", 'Undo move')) {
        if (-not $Quiet) { Write-WinnowLine "  Would move $($rec.Title) back to $(Format-WinnowPath $rec.From). Nothing was changed." -Style Dim }
        return
    }

    if ($rec.Kind -eq 'Wsl') { $err = Undo-WinnowWslHome -Record $rec }
    else { $err = Undo-WinnowVariableHome -Record $rec }
    $script:WinnowLastReport = $null

    if (-not $Quiet) { Show-WinnowUndoResult -Record $rec -Problem $err }
    elseif ($err) { Write-Warning "Winnow: the move of $($rec.Title) was not undone: $err." }
    if ($err) { return }
    return $rec
}

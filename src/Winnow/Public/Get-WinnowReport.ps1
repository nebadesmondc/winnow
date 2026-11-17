function Get-WinnowReport {
    <#
    .SYNOPSIS
    Scans for reclaimable disk space. Changes nothing.

    .DESCRIPTION
    Runs every enabled rule and renders a report grouped by tier. Read-only.

    .PARAMETER RuleId
    Restrict the scan to specific rules. See Get-WinnowRule for the list.

    .PARAMETER All
    List every finding rather than the largest few per tier.

    .PARAMETER AsObject
    Return the report object instead of rendering it, for scripting.

    .PARAMETER Json
    Return the report as JSON (schema winnow/report/1), for tools and agents.

    .EXAMPLE
    Get-WinnowReport

    .EXAMPLE
    Get-WinnowReport -RuleId cache.uv,cache.gradle.caches -All

    .EXAMPLE
    $r = Get-WinnowReport -AsObject; $r.Findings | Where-Object Bytes -gt 1GB
    #>
    [CmdletBinding()]
    param(
        [string[]]$RuleId,
        [switch]$All,
        [switch]$AsObject,
        [switch]$Json,
        [int]$Top = 8
    )

    $report = Invoke-WinnowScan -RuleId $RuleId

    if ($Json) {
        return ($report | ConvertTo-Json -Depth 6)
    }
    if ($AsObject) {
        return $report
    }

    Show-WinnowReport -Report $report -Top $Top -All:$All
    Write-WinnowLine '  Next: Start-Winnow  (guided)   or   Invoke-WinnowClean -WhatIf' -Style Dim
    Write-Host ''
}

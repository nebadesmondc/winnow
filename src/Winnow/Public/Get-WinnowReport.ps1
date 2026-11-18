function Get-WinnowReport {
    <#
    .SYNOPSIS
    Scans the system drive and returns the report object. Changes nothing.

    .DESCRIPTION
    For scripts; people use winnow. The report holds every finding with its
    verdict, size, evidence and what removing it costs.

    .PARAMETER RuleId
    Restrict the scan to specific rules. See Get-WinnowRule for the list.

    .EXAMPLE
    $r = Get-WinnowReport; $r.Findings | Where-Object Verdict -eq 'Clean'

    .EXAMPLE
    Get-WinnowReport | ConvertTo-Json -Depth 6
    #>
    [CmdletBinding()]
    param([string[]]$RuleId)

    return (Invoke-WinnowScan -RuleId $RuleId -NoProgress)
}

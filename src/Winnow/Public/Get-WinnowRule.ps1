function Get-WinnowRule {
    <#
    .SYNOPSIS
    Lists the loaded rules, their verdicts and what removing each item costs.

    .EXAMPLE
    Get-WinnowRule

    .EXAMPLE
    Get-WinnowRule -Id cache.uv | Format-List
    #>
    [CmdletBinding()]
    param(
        [string[]]$Id,
        [switch]$Refresh
    )

    $rules = @(Import-WinnowRule -Refresh:$Refresh)
    if ($Id) { $rules = @($rules | Where-Object { $Id -contains $_.Id }) }

    foreach ($r in $rules) {
        $how = 'Delete'
        foreach ($step in @($r.Reclaim)) {
            if ($step.Type -eq 'VendorCli') { $how = "$($step.Command) $($step.Args)"; break }
            if ($step.Type -eq 'ReportOnly') { $how = 'never removed'; break }
        }
        [pscustomobject]@{
            Id          = $r.Id
            Verdict     = $script:WinnowVerdictNames[$r.Verdict]
            MinBytes    = (Format-WinnowBytes $r.MinBytes).Trim()
            MinAgeDays  = $r.MinAgeDays
            Reclaim     = $how
            Consequence = $r.Consequence
        }
    }
}

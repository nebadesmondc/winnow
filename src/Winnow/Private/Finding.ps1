# Findings and verdicts.

$script:WinnowVerdictNames = [ordered]@{
    Clean    = 'Clean'
    Move     = 'Move'
    YourCall = 'Your call'
    HandsOff = 'Hands off'
}

function Get-WinnowFindingId {
    <#
    .SYNOPSIS
    Short id from rule and path, stable across scans so an id shown by one
    command can be used in the next.
    #>
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Path
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($RuleId + '|' + $Path.ToLowerInvariant()))
        return 'w-' + (-join ($bytes[0..2] | ForEach-Object { $_.ToString('x2') }))
    } finally { $sha.Dispose() }
}

function New-WinnowFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [double]$Bytes = 0,
        [double]$FreeableBytes = -1,
        [long]$Files = 0,
        [datetime]$NewestWrite,
        [string[]]$Evidence = @(),
        [string[]]$Warnings = @(),
        [string]$Verdict,
        [string]$Action = 'Delete',
        [string]$Title,
        [string]$Id,
        [string[]]$Steps,
        [AllowEmptyCollection()][string[]]$RequiresClosed
    )

    if (-not $PSBoundParameters.ContainsKey('RequiresClosed')) { $RequiresClosed = @($Rule.RequiresClosed) }
    if (-not $Verdict) { $Verdict = $Rule.Verdict }
    if (-not $Title) { $Title = $Rule.Title }
    if (-not $Id) { $Id = Get-WinnowFindingId -RuleId $Rule.Id -Path $Path }
    if (-not $PSBoundParameters.ContainsKey('Steps')) { $Steps = @($Rule.Steps) }
    if ($FreeableBytes -lt 0) { $FreeableBytes = $Bytes }

    $newest = $null
    if ($PSBoundParameters.ContainsKey('NewestWrite')) { $newest = $NewestWrite }

    return [pscustomobject]@{
        Id                  = $Id
        RuleId              = $Rule.Id
        Title               = $Title
        Verdict             = $Verdict
        Path                = $Path
        Bytes               = [double]$Bytes
        FreeableBytes       = [double]$FreeableBytes
        Files               = $Files
        NewestWrite         = $newest
        Evidence            = @($Evidence)
        Warnings            = @($Warnings)
        Consequence         = $Rule.Consequence
        Steps               = @($Steps | Where-Object { $_ })
        Docs                = $Rule.Docs
        Action              = $Action
        Reclaim             = $Rule.Reclaim
        RequiresClosed      = @($RequiresClosed | Where-Object { $_ })
        AllowsInsideProject = @($Rule.AllowsInsideProject)
        Suppressed          = $false
        SuppressReason      = $null
    }
}

function Get-WinnowNotActionableReason {
    <#
    .SYNOPSIS
    Why a finding may not be removed, or $null when it may. Your call items
    are removed only when picked by id.
    #>
    param(
        [Parameter(Mandatory)][object]$Finding,
        [switch]$ById
    )

    if ($Finding.Suppressed) { return "held back: $($Finding.SuppressReason)" }
    if ($Finding.Action -eq 'ReportOnly') { return 'Winnow only reports this; it never removes it' }
    switch ($Finding.Verdict) {
        'Clean'    { return $null }
        'YourCall' {
            if ($ById) { return $null }
            return 'it is your call; Winnow removes it only when you name its id'
        }
        'Move'     { return 'it is still needed; it can be moved to another drive, not removed' }
        'HandsOff' { return 'Windows manages it; Winnow never removes it' }
    }
    return "unknown verdict '$($Finding.Verdict)'"
}

function Test-WinnowFindingActionable {
    <#
    .SYNOPSIS
    Whether a finding may be removed at all, before any user consent.
    #>
    param(
        [Parameter(Mandatory)][object]$Finding,
        [switch]$ById
    )

    return ($null -eq (Get-WinnowNotActionableReason -Finding $Finding -ById:$ById))
}

function Test-WinnowFindingRemovable {
    <#
    .SYNOPSIS
    Whether a rule's verdict and action could ever lead to removal. Only these
    findings are guarded, checked for live use and scanned for keys.
    #>
    param([Parameter(Mandatory)][string]$Verdict, [string]$Action = 'Delete')

    return (($Verdict -eq 'Clean' -or $Verdict -eq 'YourCall') -and $Action -ne 'ReportOnly')
}

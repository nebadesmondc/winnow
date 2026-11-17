# Findings and confidence scoring.

$script:WinnowTierOrder = @{
    'Transient'     = 0
    'Rebuildable'   = 1
    'Orphaned'      = 2
    'Superseded'    = 3
    'UserData'      = 4
    'SystemManaged' = 5
}

# Tiers Invoke-WinnowClean may act on; the others are report-only.
$script:WinnowActionableTiers = @('Transient', 'Rebuildable', 'Orphaned', 'Superseded')

function Get-WinnowFindingId {
    <#
    .SYNOPSIS
    Id from rule, path and scan run; valid only within the scan that made it.
    #>
    param(
        [Parameter(Mandatory)][string]$RuleId,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId
    )
    $material = ($RuleId + '|' + $Path.ToLower() + '|' + $RunId)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
        $hex = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
        return 'wnw-' + $hex
    } finally { $sha.Dispose() }
}

function New-WinnowFinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RunId,
        [double]$Bytes = 0,
        [int]$Files = 0,
        [datetime]$NewestWrite,
        [string]$Context = 'LocalFs',
        [string[]]$Evidence = @(),
        [string[]]$Warnings = @(),
        [double]$Confidence = 1.0,
        [string]$Tier,
        [string]$Action = 'Delete',
        [string]$Title,
        [switch]$InsideVirtualDisk
    )

    $effectiveTier = $Rule.Tier
    if ($Tier) { $effectiveTier = $Tier }

    $effectiveTitle = $Rule.Title
    if ($Title) { $effectiveTitle = $Title }

    return [pscustomobject]@{
        Id                = Get-WinnowFindingId -RuleId $Rule.Id -Path $Path -RunId $RunId
        RuleId            = $Rule.Id
        Title             = $effectiveTitle
        Category          = $Rule.Category
        Context           = $Context
        Path              = $Path
        Bytes             = [double]$Bytes
        Files             = $Files
        NewestWrite       = $NewestWrite
        Tier              = $effectiveTier
        Confidence        = [math]::Round($Confidence, 2)
        Evidence          = @($Evidence)
        Warnings          = @($Warnings)
        Consequence       = $Rule.Consequence
        Docs              = $Rule.Docs
        Action            = $Action
        Reclaim           = $Rule.Reclaim
        RequiresAdmin     = [bool]$Rule.RequiresAdmin
        AllowsInsideProject = @($Rule.AllowsInsideProject)
        # False inside a virtual disk: removal frees space in the .vhdx, not the host.
        HostSpaceReturned = (-not $InsideVirtualDisk.IsPresent)
        Suppressed        = $false
        SuppressReason    = $null
    }
}

function Get-WinnowConfidence {
    <#
    .SYNOPSIS
    Scores a candidate from 1.0 down and returns the penalties applied.
    Below 0.60 a finding is never removed.
    #>
    param(
        [string]$ResolveStrategy = 'Path',
        [switch]$ToolMissing,
        [datetime]$NewestWrite,
        [switch]$SentinelDocuments,
        [int]$InstallNegatives = -1,
        [switch]$LiveVersionUnknown
    )

    $score = 1.0
    $notes = New-Object System.Collections.Generic.List[string]

    if ($ResolveStrategy -eq 'Path') {
        $score -= 0.10
        $notes.Add('location found by convention rather than by asking the tool (-0.10)')
    }
    if ($ToolMissing) {
        $score -= 0.15
        $notes.Add('owning tool is not on PATH (-0.15)')
    }
    if ($PSBoundParameters.ContainsKey('NewestWrite') -and $NewestWrite) {
        if ($NewestWrite -gt (Get-Date).ToUniversalTime().AddHours(-24)) {
            $score -= 0.10
            $notes.Add('modified within the last 24 hours (-0.10)')
        }
    }
    if ($SentinelDocuments) {
        $score -= 0.30
        $notes.Add('sentinel scan found document-like files (-0.30)')
    }
    if ($InstallNegatives -ge 0 -and $InstallNegatives -lt 4) {
        $score -= 0.25
        $notes.Add("only $InstallNegatives of 6 install probes were conclusive negatives (-0.25)")
    }
    if ($LiveVersionUnknown) {
        $score -= 0.20
        $notes.Add('the live version could not be determined from a running process (-0.20)')
    }

    if ($score -lt 0) { $score = 0 }
    if ($score -gt 1) { $score = 1 }

    return [pscustomobject]@{
        Score = [math]::Round($score, 2)
        Notes = $notes
    }
}

function Get-WinnowNotActionableReason {
    <#
    .SYNOPSIS
    Why a finding may not be acted on, or $null when it may.
    #>
    param([Parameter(Mandatory)][object]$Finding)

    if ($Finding.Suppressed) { return "held back: $($Finding.SuppressReason)" }
    if ($script:WinnowActionableTiers -notcontains $Finding.Tier) {
        return "$($Finding.Tier) items are report-only; Winnow never removes them"
    }
    if ($Finding.Action -eq 'ReportOnly') { return 'this rule only reports; it never removes' }
    if ($Finding.Confidence -lt 0.6) {
        return ('confidence {0:0.00} is below the 0.60 needed for removal' -f $Finding.Confidence)
    }
    return $null
}

function Test-WinnowFindingActionable {
    <#
    .SYNOPSIS
    Whether a finding may be acted on at all, before any user consent.
    #>
    param([Parameter(Mandatory)][object]$Finding)

    return ($null -eq (Get-WinnowNotActionableReason -Finding $Finding))
}

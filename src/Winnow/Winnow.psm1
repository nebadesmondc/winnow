# Module loader. Only Public functions are exported; the delete primitive
# stays private.

Set-StrictMode -Version 1.0

$script:WinnowModuleRoot = $PSScriptRoot

# Strict mode: lazily filled caches must exist before first read.
$script:WinnowGuardPolicy    = $null
$script:WinnowVolumeCache    = $null
$script:WinnowProcessMap     = $null
$script:WinnowUninstallCache = $null
$script:WinnowRules          = $null
$script:WinnowLastReport     = $null

# Compiled once per session; a changed SpaceWalker.cs needs a new session.
if (-not ('Winnow.SpaceWalker' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'Private\SpaceWalker.cs')
}

$privateOrder = @(
    'Common.ps1'        # path normalisation, sizes, environment roots, CLI runner
    'Guard.ps1'         # the denylist - must load before Remove-Safely
    'Measure-Tree.ps1'  # sizing on top of the native walker
    'Interlock.ps1'     # running processes, in-flight updates, sentinel scan
    'Remove-Safely.ps1' # the ONLY delete primitive in the codebase
    'Discovery.ps1'     # location resolution, install detection
    'Detectors.ps1'     # generic detectors (H3, H4)
    'Finding.ps1'       # the Finding, tiers, confidence
    'Format.ps1'        # console rendering
    'RuleEngine.ps1'    # rule loading and the scan pipeline
)

foreach ($name in $privateOrder) {
    $path = Join-Path (Join-Path $PSScriptRoot 'Private') $name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Winnow: required private file '$name' is missing."
    }
    . $path
}

# Unlisted private files load last.
$loaded = $privateOrder
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -File | Sort-Object Name)) {
    if ($loaded -contains $f.Name) { continue }
    . $f.FullName
}

$publicNames = New-Object System.Collections.Generic.List[string]
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File | Sort-Object Name)) {
    . $f.FullName
    $publicNames.Add([System.IO.Path]::GetFileNameWithoutExtension($f.Name))
}

Set-Alias -Name winnow -Value Invoke-Winnow

Export-ModuleMember -Function $publicNames.ToArray() -Alias 'winnow'

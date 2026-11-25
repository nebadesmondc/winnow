# Stages a release in -OutDir: the module folder, its zip, SHA256SUMS.txt and
# the release notes. The release workflow runs it; it also runs locally.

param(
    [string]$Tag,
    [string]$Repository = $env:GITHUB_REPOSITORY,
    [string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out')
)

$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Winnow'
$version = (Test-ModuleManifest -Path (Join-Path $source 'Winnow.psd1')).Version.ToString()
if ($Tag -and $Tag -ne "v$version") { throw "Tag $Tag does not match the manifest version $version." }

if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
$module = Join-Path $OutDir 'Winnow'
$null = New-Item -ItemType Directory -Path $module -Force
Copy-Item -Path (Join-Path $source '*') -Destination $module -Recurse

$zipName = "Winnow-$version.zip"
$zip = Join-Path $OutDir $zipName
# Entries are named by hand: on 5.1 both Compress-Archive and ZipFile write
# backslashes, which other unzip tools keep in the file name.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in (Get-ChildItem -LiteralPath $module -Recurse -File | Sort-Object FullName)) {
        $entry = 'Winnow/' + $f.FullName.Substring($module.Length + 1).Replace('\', '/')
        $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
}

# Paths are relative to the module folder, so an installed copy checks the same way.
$sums = @(Get-ChildItem -LiteralPath $module -Recurse -File | Sort-Object FullName | ForEach-Object {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(),
        $_.FullName.Substring($module.Length + 1).Replace('\', '/')
})
Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS.txt') -Value $sums -Encoding ascii
$zipSum = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()

$fence = '```'
$install = 'Install in the README'
$verify = 'Verify a release in the README'
if ($Repository) {
    $install = "[Install](https://github.com/$Repository#install) in the README"
    $verify = "[Verify a release](https://github.com/$Repository#verify-a-release) in the README"
}
$notes = @(
    'Install from the PowerShell Gallery:'
    ''
    "${fence}powershell"
    'Install-Module Winnow -Scope CurrentUser'
    $fence
    ''
    "First time on Windows PowerShell 5.1: see $install."
    ''
    '### Verify'
    ''
)
if ($Repository) {
    $notes += @(
        "The zip carries a build attestation: ``gh attestation verify $zipName --repo $Repository``."
        ''
    )
}
$notes += @(
    "An installed copy checks against ``SHA256SUMS.txt`` with the command in $verify."
    ''
    $fence
    "$zipSum  $zipName"
) + $sums + @($fence)
Set-Content -LiteralPath (Join-Path $OutDir 'notes.md') -Value $notes -Encoding ascii

Write-Host "Winnow $version staged in $OutDir ($($sums.Count) files)."

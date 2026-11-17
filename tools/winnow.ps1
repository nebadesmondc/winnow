# Runs Winnow from this working copy: guided cleanup, or -Report to scan only.

[CmdletBinding()]
param(
    [switch]$Report,
    [switch]$All,
    [switch]$Yes
)

$manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Winnow\Winnow.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host "Winnow: module not found at $manifest" -ForegroundColor Red
    exit 1
}

Import-Module $manifest -Force

if ($Report) {
    Get-WinnowReport -All:$All
} else {
    Start-Winnow -Yes:$Yes
}

exit 0

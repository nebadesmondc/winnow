# Runs Winnow from this working copy: winnow.cmd [explain <id> | clean [<id>]] [-All] [-Yes]

$manifest = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Winnow\Winnow.psd1'
if (-not (Test-Path -LiteralPath $manifest)) {
    Write-Host "Winnow: module not found at $manifest" -ForegroundColor Red
    exit 1
}

Import-Module $manifest -Force
Invoke-Winnow @args
exit 0

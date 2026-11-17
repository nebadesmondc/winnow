# Winnow

[![CI](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml?query=branch%3Amaster)

Winnow frees space on the Windows system drive taken up by developer tools: package caches, application caches and leftover installers. It shows what each item is and what removing it costs, and removes only what you approve.

## Features

- **Tool caches:** npm, pnpm, pip, uv, Gradle, Pub and Playwright, located by asking each tool. Copies left at the default location after a cache was moved to another drive are found too.
- **Application caches:** browser, Electron and editor caches, kept apart from profiles, logins and settings.
- **Leftovers:** installers that were already applied and temp folders older than two days.
- **Read-only by default:** a scan changes nothing, and every cleanup asks first.
- **Guarded removal:** Windows, installed programs, user folders, credentials and source projects are always refused. See [SAFETY.md](SAFETY.md).
- **No dependencies:** Windows PowerShell 5.1, no admin rights, no network access.

## Quickstart

Requires Windows 10 or 11.

```powershell
git clone https://github.com/nebadesmondc/winnow.git
cd winnow
.\tools\winnow.cmd -Report    # scan only
.\tools\winnow.cmd            # guided cleanup
```

## Usage

```powershell
Import-Module .\src\Winnow\Winnow.psd1

Get-WinnowReport              # reclaimable space and why
Get-WinnowRule                # rules and what removing each item costs
Invoke-WinnowClean -WhatIf    # the cleanup plan, without changes
Invoke-WinnowClean            # clean Transient and Rebuildable items
Start-Winnow                  # guided cleanup, one question per group
```

Each cleanup is recorded in `%LOCALAPPDATA%\Winnow\runs`.

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

## Docs

- [Safety model](SAFETY.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

[MIT](LICENSE)

# Winnow

[![CI](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml?query=branch%3Amaster)

Winnow shows where the space on your Windows system drive went and gets it back safely. It measures the whole drive, says what each large item is and what removing it costs, removes only what you approve, and moves what must stay to another drive.

```
  C:   224 GB  [#######################.......]    56 GB free
  D:   135 GB  [###############...............]    65 GB free  same SSD as C:, moving costs no speed

  WHERE THE SPACE IS                             SIZE  VERDICT    NEXT
  Windows pagefile                              20 GB  Hands off  winnow explain pagefile
  Docker Desktop data disk                      20 GB  Move       winnow move docker
  Hibernation file                             6.4 GB  Hands off  winnow explain hiberfil
  Caches and temporary files (16)              2.3 GB  Clean      winnow clean
  element-desktop 1.12.13 (older version)      511 MB  Your call  winnow explain w-32f47d
  Installed programs                            35 GB  -          Microsoft Office 4.9 GB, IntelliJ IDEA 4.0 GB
  Windows                                       20 GB  -          WinSxS 7.9 GB, System32 6.8 GB, Installer 1.9 GB
  Not explained                                 15 GB  -          restore points, reserved storage

  Clean now: 2.3 GB    Movable: 20 GB    Explained: 91% of 169 GB used    Nothing has been changed.    (27 s)
```

## Features

- **Space map:** the whole system drive in about 30 seconds, split into the items below and Windows, programs, your files and app data. Hard-linked files count once.
- **Four verdicts:** Clean (rebuilds itself), Move (needed, but not on this drive), Your call (only you can know), Hands off (Windows manages it).
- **Tool caches:** npm, pnpm, pip, uv, Gradle, NuGet, Go, Pub and Playwright, located by asking each tool, including copies left behind after a cache was moved.
- **Moves:** a tool cache goes to another drive and the tool is pointed at it; a WSL distribution is moved by WSL itself. The tool is asked to confirm the new location before the old copy is deleted, and `winnow undo` reverses any move.
- **App caches and leftovers:** browser, Electron and editor caches, old temp folders, installers already applied.
- **Virtual disks:** WSL distributions, Docker Desktop's data disk and other virtual machine disks.
- **Older versions:** VS Code builds, editor extensions and app versions kept after updates. Anything still running is held back.
- **Pagefile and hibernation file:** current and peak use, and the official steps to shrink them.
- **Guarded removal:** Windows, installed programs, user folders, credentials, virtual disks and source projects are always refused. See [SAFETY.md](SAFETY.md).
- **No dependencies:** Windows PowerShell 5.1 or PowerShell 7, no admin rights, no network access.

## Install

Requires Windows 10 or 11. In PowerShell 7:

```powershell
Install-Module Winnow
winnow                  # the space map; changes nothing
```

In Windows PowerShell 5.1, the one built into Windows, the first time:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned   # Windows blocks all scripts by default
Install-Module Winnow -Scope CurrentUser              # answer Y to the NuGet provider and the PSGallery prompts
winnow
```

To run from a clone instead: `git clone https://github.com/nebadesmondc/winnow.git`, then `.\winnow\tools\winnow.cmd`.

## Usage

```powershell
winnow                  # the space map
winnow explain <id>     # what an item is, what removing it costs, the steps
winnow clean            # remove every Clean item, after one yes
winnow clean <id>       # remove one item; Your call items go to the Recycle Bin
winnow move             # what can move to another drive
winnow move <id>        # move it, after one yes; -To picks the folder
winnow undo [<id>]      # reverse the last move, or the named one
```

For scripts, `Get-WinnowReport` returns the report object, `Invoke-WinnowClean -WhatIf` and `Invoke-WinnowMove -WhatIf` show a plan, `Undo-WinnowMove` reverses a move, and `Get-WinnowRule` lists the rules. Each cleanup is recorded in `%LOCALAPPDATA%\Winnow\runs`, each move in `%LOCALAPPDATA%\Winnow\moves`.

## Verify a release

Each [release](https://github.com/nebadesmondc/winnow/releases) lists the SHA-256 of every file, and its zip carries a GitHub build attestation:

```powershell
gh attestation verify Winnow-0.1.0.zip --repo nebadesmondc/winnow
```

To check an installed copy, download the release's `SHA256SUMS.txt` and run this next to it; no output means every file matches:

```powershell
$base = (Get-Module Winnow -ListAvailable | Sort-Object Version -Descending)[0].ModuleBase
Get-Content .\SHA256SUMS.txt | ForEach-Object { $h, $p = $_ -split '  ', 2; if ((Get-FileHash (Join-Path $base $p)).Hash -ne $h) { "differs: $p" } }
```

## Development

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1
```

A `v*` tag runs `build/Build-Release.ps1` in CI, attests the zip, creates the GitHub release and publishes to the PowerShell Gallery.

## Docs

- [Safety model](SAFETY.md)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

## License

[MIT](LICENSE)

# Winnow

[![CI](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/nebadesmondc/winnow/actions/workflows/ci.yml?query=branch%3Amaster)

Winnow shows where the space on your Windows system drive went and gets it back safely. It measures the whole drive, says what each large item is and what removing it costs, and removes only what you approve.

```
  WHERE THE SPACE IS                             SIZE  VERDICT    NEXT
  Windows pagefile                              22 GB  Hands off  winnow explain pagefile
  Docker Desktop data disk                      20 GB  Move       winnow explain docker
  Hibernation file                             6.4 GB  Hands off  winnow explain hiberfil
  Caches and temporary files (18)              2.3 GB  Clean      winnow clean
  element-desktop 1.12.13 (older version)      511 MB  Your call  winnow explain w-32f47d
  Installed programs                            35 GB  -          Microsoft Office 4.9 GB, IntelliJ IDEA 4.0 GB
  Windows                                       20 GB  -          WinSxS 7.9 GB, System32 6.8 GB, Installer 1.8 GB
  Not explained                                 15 GB  -          restore points, reserved storage

  Clean now: 2.3 GB    Explained: 91% of 170 GB used    Nothing has been changed.    (27 s)
```

## Features

- **Space map:** the whole system drive in about 30 seconds, split into the items below and Windows, programs, your files and app data. Hard-linked files count once.
- **Four verdicts:** Clean (rebuilds itself), Move (needed, but not on this drive), Your call (only you can know), Hands off (Windows manages it).
- **Tool caches:** npm, pnpm, pip, uv, Gradle, Pub and Playwright, located by asking each tool, including copies left behind after a cache was moved.
- **App caches and leftovers:** browser, Electron and editor caches, old temp folders, installers already applied.
- **Virtual disks:** WSL distributions, Docker Desktop's data disk and other virtual machine disks.
- **Older versions:** VS Code builds, editor extensions and app versions kept after updates. Anything still running is held back.
- **Pagefile and hibernation file:** current and peak use, and the official steps to shrink them.
- **Guarded removal:** Windows, installed programs, user folders, credentials, virtual disks and source projects are always refused. See [SAFETY.md](SAFETY.md).
- **No dependencies:** Windows PowerShell 5.1 or PowerShell 7, no admin rights, no network access.

## Quickstart

Requires Windows 10 or 11.

```powershell
git clone https://github.com/nebadesmondc/winnow.git
cd winnow
.\tools\winnow.cmd    # the space map; changes nothing
```

## Usage

```powershell
Import-Module .\src\Winnow\Winnow.psd1

winnow                  # the space map
winnow explain <id>     # what an item is, what removing it costs, the steps
winnow clean            # remove every Clean item, after one yes
winnow clean <id>       # remove one item; Your call items go to the Recycle Bin
```

For scripts, `Get-WinnowReport` returns the report object, `Invoke-WinnowClean -WhatIf` shows a plan, and `Get-WinnowRule` lists the rules. Each cleanup is recorded in `%LOCALAPPDATA%\Winnow\runs`.

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

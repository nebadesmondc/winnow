# Safety model

## Guarantees

- A scan only reads. Nothing changes until a cleanup is confirmed.
- Every rule states a verdict and what removing its item costs; a rule without them does not load.
- Windows, installed programs, user folders, credentials, virtual disks and source projects are refused whatever a rule says.
- Items in use (a running program, an update being installed) are held back.
- All removals go through one function, which checks the guard every time.
- No network access, no telemetry, no admin rights, no services, scheduled tasks or registry writes.
- Freed space is measured, and anything not removed is listed with the reason.

## Verdicts

| Verdict | Means | What Winnow does |
|---|---|---|
| Clean | Rebuilds itself; the cost is a re-download or a slower first start | Removes it on `winnow clean` |
| Move | Needed, but not on the system drive | Explains how to move it; never removes it |
| Your call | Only you can know | Removes it only when you name its id, to the Recycle Bin |
| Hands off | Windows manages it | Explains it and gives the official steps; never acts |

Virtual disks, the pagefile and the hibernation file are reported only, whatever their verdict.

## From scan to removal

```
walk       measure the system drive, read-only   src/Winnow/Private/SpaceWalker.cs
scan       rules find candidates                 src/Winnow/Private/RuleEngine.ps1
           the guard checks each one             src/Winnow/Private/Guard.ps1
           in-use and sentinel checks            src/Winnow/Private/Interlock.ps1
map        items with verdict, cost, evidence    src/Winnow/Private/SpaceMap.ps1
confirm    one confirmation for the whole plan   src/Winnow/Public/Invoke-Winnow.ps1
remove     in-use check, guard, delete, measure  src/Winnow/Public/Invoke-WinnowClean.ps1
                                                 src/Winnow/Private/Remove-Safely.ps1
record     JSON run record                       %LOCALAPPDATA%\Winnow\runs\
```

`Invoke-WinnowClean` takes no path parameter; it only acts on items from a scan.

## The walk

`SpaceWalker.cs` is compiled from source when the module loads. It opens folders for listing and nothing else: no writes, moves or deletes, which a test checks. It counts space on disk, so compressed and sparse files count what they occupy and a hard-linked file counts once. It never follows junctions or symbolic links.

## The guard

`Guard.ps1` refuses first and then requires an allowed root, so unknown locations fail closed. A path is refused when it:

| # | Rule | Examples |
|---|---|---|
| 1 | cannot be resolved, or is a device path | `\\?\GLOBALROOT\...` |
| 2 | is a drive root or less than two folders deep | `C:\`, `C:\Users` |
| 3 | is not on a local fixed disk | network shares, USB drives |
| 4 | is a system file | `pagefile.sys`, `hiberfil.sys`, `swapfile.sys`, `bootmgr` |
| 5 | is inside Windows or installed programs | `%WINDIR%`, `Program Files`, `ProgramData\Package Cache` |
| 6 | is inside a protected volume folder | `System Volume Information`, `$Recycle.Bin`, `Recovery`, `Windows.old` |
| 7 | is inside user content | Documents, Desktop, Downloads, Pictures, Music, Videos, OneDrive, Dropbox |
| 8 | passes through a credentials folder | `.ssh`, `.gnupg`, `.aws`, `.azure`, `.kube`, `.docker`, `Microsoft\Credentials` |
| 9 | is a key, secret or virtual disk file | `*.pem`, `*.pfx`, `*.key`, `*.kdbx`, `id_rsa*`, `.env`, `*.vhdx`, `*.vmdk` |
| 10 | is a link or is reached through one | junctions, symbolic links |
| 11 | is inside a source project, unless the rule names that build folder | `.git`, `package.json`, `pom.xml` within four levels |
| 12 | is not under `%LOCALAPPDATA%`, `%APPDATA%`, `%TEMP%`, the profile folder or `%ProgramData%`, or is one of them | |

An installed editor extension (a folder directly in `~\.vscode\extensions` and similar) carries a `package.json` but is not a source project; with a `.git` folder it is.

## Before an item is offered

- **Size and age:** each rule sets a minimum size, some a minimum age.
- **In use:** a folder a running program executes from is held back, and so is anything whose app a rule needs closed.
- **Updates:** an app folder with an update marker or a running installer is held back for the whole run, as is an editor whose installed update waits for a restart, with the installer it downloaded.
- **Open files:** the item is flagged; cleaning will be partial until the app is closed.
- **Sentinel:** key material (`id_rsa*`, `.env`, `*.pfx`, `*.kdbx`, a `.pem` holding a private key) or a virtual disk in a folder holds it back for good. Three or more documents or media files turn a Clean item into Your call.
- **Older versions:** offered only when the app is shown to use a newer one: the build its manifest names, the extensions its `extensions.json` loads, the newest `app-*` folder.
- **Overlap:** a tool's rule claims its folders; detectors skip anything inside or around them.

## Removal

- `winnow clean` lists the plan and asks once; Enter alone means no. `Invoke-WinnowClean -WhatIf` shows the plan without changes.
- Right before each removal the item is checked again for programs running from it, apps that must be closed and updates in flight.
- The plan stops if it touches more than 250,000 files, takes more than 25 GB from one rule, or more than 60% of a drive's used space. `-Force` lifts these limits, never the guard.
- A cache in use is cleaned with the tool's own command (`npm cache clean --force`, `uv cache clean`, `pnpm store prune`, `pip cache purge`). Copies at old locations are deleted directly.
- Your call items go to the Recycle Bin. Windows asks before deleting anything too large for it.
- `Remove-WinnowPath`: checks the guard, measures, detaches every link inside the folder, deletes (retrying without read-only attributes, then with `robocopy` as a last resort), and measures what is left.
- Each run writes `%LOCALAPPDATA%\Winnow\runs\<run id>.json`: what was planned and removed, bytes per item, drive free-space change, and anything left with the reason.

## Processes and files

- **Started:** `uv`, `npm`, `pnpm` and `pip`, with fixed arguments from the rules, a timeout, the profile folder as working directory and update checks off (`NO_UPDATE_NOTIFIER`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_OFFLINE`, `DO_NOT_TRACK`). `npm` and `pnpm` start through `cmd.exe`. `robocopy.exe` runs only inside `Remove-WinnowPath`.
- **Read:** folder listings; installed programs, WSL distributions and the Fast Startup setting from the registry; pagefile use and memory size through CIM; `.pem` files the sentinel finds, editor manifests, `product.json` and `extensions.json`.
- **Written:** run records under `%LOCALAPPDATA%\Winnow\runs` only.

## Tests

`tests/Run-Tests.ps1` needs nothing installed and runs in CI on every push, on Windows PowerShell 5.1 and PowerShell 7.

| Guarantee | Tests |
|---|---|
| One removal path | no delete API outside Remove-Safely.ps1, including the walker; delete primitive not exported |
| Read-only walk | the walker opens folders for listing only; hard links count once; junctions are not followed |
| Offline | no network API; child processes run with update checks off |
| No admin | no elevation, service or scheduled-task API |
| Guard | 50 paths refused, 6 permitted; projects, extensions, links and key material fixtures |
| Verdicts | only Clean is removed by default; Your call needs its id; Move, Hands off, virtual disks never |
| Links | removing a tree with a junction leaves its target alone; last-resort purge stays inside its target |
| In use | a folder a running program executes from is held back; so is one whose app must be closed |
| Secrets | key material and virtual disks hold a folder back; certificate bundles do not |
| Older versions | only versions older than the one in use; a pending update is not stale |
| Numbers | freed space measured on disk; the map places every byte once; no finding inside another |
| Recycle Bin | Your call items go to the Recycle Bin (CI only) |
| Read-only scan | a scan changes nothing; `-WhatIf` changes nothing |

## Limits

- Only the system drive is mapped.
- Restore points, reserved storage and folders only an administrator can read are not measured; the map shows them as not explained.
- Clean items are deleted for good; only Your call items go to the Recycle Bin.
- A cache an app keeps open is cleaned partly; the rest is listed.
- Tools Winnow starts are third-party programs; only their known update checks are disabled.

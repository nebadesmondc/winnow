# Safety model

## Guarantees

- A scan only reads. Nothing changes until a cleanup or a move is confirmed.
- Every rule states a verdict and what removing its item costs; a rule without them does not load.
- Windows, installed programs, user folders, credentials, virtual disks and source projects are refused whatever a rule says.
- Items in use (a running program, an update being installed) are held back.
- Every change happens in one file, `Change.ps1`; each delete there checks the guard.
- A move deletes the old copy only after the tool names the new folder, and writes a record that `winnow undo` reverses.
- No network access, no telemetry, no admin rights, no services or scheduled tasks. The only registry write is the user environment variable a move sets, from the list the rules name; `PATH` and Windows' own variables are never changed.
- Freed space is measured, and anything not removed is listed with the reason.

## Verdicts

| Verdict | Means | What Winnow does |
|---|---|---|
| Clean | Rebuilds itself; the cost is a re-download or a slower first start | Removes it on `winnow clean` |
| Move | Needed, but not on the system drive | Moves it on `winnow move`; never removes it |
| Your call | Only you can know | Removes it only when you name its id, to the Recycle Bin |
| Hands off | Windows manages it | Explains it and gives the official steps; never acts |

Winnow never deletes a virtual disk, the pagefile or the hibernation file. A WSL distribution is moved by WSL itself; Docker Desktop's disk moves with Docker's own setting, for which Winnow gives the steps.

## From scan to change

```
walk       measure the system drive, read-only   src/Winnow/Private/SpaceWalker.cs
scan       rules find candidates                 src/Winnow/Private/RuleEngine.ps1
           the guard checks each one             src/Winnow/Private/Guard.ps1
           in-use and sentinel checks            src/Winnow/Private/Interlock.ps1
map        items with verdict, cost, evidence    src/Winnow/Private/SpaceMap.ps1
confirm    one confirmation for the whole plan   src/Winnow/Public/Invoke-Winnow.ps1
remove     in-use check, guard, delete, measure  src/Winnow/Public/Invoke-WinnowClean.ps1
move       copy, point the tool, check, delete   src/Winnow/Public/Invoke-WinnowMove.ps1
                                                 src/Winnow/Private/Move.ps1
change     the only file that changes anything   src/Winnow/Private/Change.ps1
record     JSON run and move records             %LOCALAPPDATA%\Winnow\runs\ and \moves\
```

`Invoke-WinnowClean` takes no path parameter and `Invoke-WinnowMove` takes no source path; both act only on items from a scan.

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

Check 12 has one exception: the folder a move record names as its destination, so an undo or a failed move can remove the copy Winnow made. Checks 1 to 11 still apply to it.

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

## Moving

- **What moves:** the tool homes a rule's `Move` names (npm, pip, uv, the Gradle home, NuGet packages, the Go module and build caches, Playwright, Pub) and WSL distributions. Docker Desktop's disk gets steps only.
- **Where:** an empty or new folder on another fixed disk, with the item's size plus 10% and 1 GB free. Never the same drive, a drive root, Windows, Program Files, user folders, cloud sync folders or a path through a link. By default `<drive>:\DevCache\<id>` or `<drive>:\WSL\<name>` on the drive with most room, SSDs first.
- **Permissions:** the new folder is open to you, SYSTEM and Administrators only. They are set on that folder alone and everything copied in inherits them; nothing is changed file by file.
- **A cache:** `winnow move` lists the plan and asks once. The folder is copied with `robocopy` (data, attributes and timestamps; not permissions, not links) and the file counts compared. The tool's variable is then set for your account (`HKCU\Environment`) and this session, and the tool is asked where its cache is (`npm config get cache`, `pip cache dir`). Only when it names the new folder is the old one deleted, through `Remove-WinnowPath`. Any failure before that removes the copy and restores the variable.
- **Not moved:** a folder with links inside or folders that cannot be read; anything a running program uses or whose app must be closed; a Pub cache whose global tools are on `PATH`.
- **A WSL distribution:** stopped with `wsl --terminate`, moved with `wsl --manage <name> --move <folder>`, then started once to check it works. If other distributions keep WSL's disk open, Winnow names them and stops; it never shuts WSL down. Editor windows, terminals and Docker Desktop's integration that keep restarting it are named.
- **Undo:** `winnow undo` copies a cache back, restores the variable to its earlier value or removes it, asks the tool, then deletes the moved copy. A WSL distribution is moved back by WSL.
- Each move writes `%LOCALAPPDATA%\Winnow\moves\<move id>.json` before it starts: where from and to, the variable's earlier value, what the tool answered, and the outcome.

## Processes and files

- **Started:** `uv`, `npm`, `pnpm`, `pip`, `dotnet` and `go`, with fixed arguments from the rules, a timeout, the profile folder as working directory and update checks off (`NO_UPDATE_NOTIFIER`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_OFFLINE`, `DO_NOT_TRACK`, `DOTNET_CLI_TELEMETRY_OPTOUT`). `npm` and `pnpm` start through `cmd.exe`. `wsl` lists, stops, moves and starts a distribution as above. `robocopy.exe` runs only in `Change.ps1`.
- **Read:** folder listings; installed programs, WSL distributions and the Fast Startup setting from the registry; pagefile use, memory size, disk types and process command lines through CIM; `.pem` files the sentinel finds, editor manifests, `product.json`, `extensions.json` and Docker Desktop's `settings-store.json`.
- **Written:** run and move records under `%LOCALAPPDATA%\Winnow`; a move's destination folder; the user environment variable a move sets.

## Tests

`tests/Run-Tests.ps1` needs nothing installed and runs in CI on every pull request, on Windows PowerShell 5.1 and PowerShell 7.

| Guarantee | Tests |
|---|---|
| One change file | no delete, copy, move, permission or environment API outside `Change.ps1`, including the walker; none of it exported |
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
| Whole scan | a fake drive with one item of each kind: each is found with its verdict, the one holding a key is held back |
| Moves | each cache moves to a second drive and back, and the tool names the folder each time; a move the tool does not confirm is put back; Enter alone changes nothing; the new folder is private and its contents inherit; bad destinations are refused |
| Variables | only variables a rule names, never `PATH` or Windows' own; user variables are written only on CI |
| WSL | what keeps a distribution running is named; Winnow never unregisters a distribution |
| Recycle Bin | Your call items go to the Recycle Bin (CI only) |
| Read-only scan | a scan changes nothing; `-WhatIf` changes nothing |

## Limits

- Only the system drive is mapped.
- Restore points, reserved storage and folders only an administrator can read are not measured; the map shows them as not explained.
- Clean items are deleted for good; only Your call items go to the Recycle Bin.
- A cache an app keeps open is cleaned partly; the rest is listed.
- After a move, open terminals and editors use the old location until restarted, and a tool with its own setting (an IDE's Gradle home) keeps using it.
- Moving a WSL distribution needs a WSL with `wsl --manage --move`.
- Tools Winnow starts are third-party programs; only their known update checks are disabled.

# Safety model

## Guarantees

- A scan only reads. Nothing changes until a cleanup is confirmed.
- Every rule states what removing its item costs; a rule without one does not load.
- Windows, installed programs, user folders, credentials and source projects are refused whatever a rule says.
- Items in use (a running program, an update being installed) are held back.
- All removals go through one function, which checks the guard every time.
- No network access, no telemetry, no admin rights, no services, scheduled tasks or registry writes.
- Freed space is measured, and anything not removed is listed with the reason.

## From scan to removal

```
scan       rules find candidates                  src/Winnow/Private/RuleEngine.ps1
           the guard checks each one              src/Winnow/Private/Guard.ps1
           in-use and sentinel checks             src/Winnow/Private/Interlock.ps1
report     items with cost and evidence
confirm    one confirmation for the whole plan    src/Winnow/Public/Invoke-WinnowClean.ps1
remove     guard, measure, delete, measure        src/Winnow/Private/Remove-Safely.ps1
record     JSON run record                        %LOCALAPPDATA%\Winnow\runs\
```

`Invoke-WinnowClean` takes no path parameter; it only acts on items from a scan.

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
| 9 | is a key or secret file | `*.pem`, `*.pfx`, `*.key`, `*.kdbx`, `id_rsa*`, `.env`, `.npmrc`, `.netrc` |
| 10 | is a link or is reached through one | junctions, symbolic links |
| 11 | is inside a source project, unless the rule names that build folder | `.git`, `package.json`, `pom.xml` within four levels |
| 12 | is not under `%LOCALAPPDATA%`, `%APPDATA%`, `%TEMP%`, the profile folder or `%ProgramData%`, or is one of them | |

## Before an item is offered

- **Size and age:** each rule sets a minimum size, some a minimum age.
- **In use:** a folder a running program executes from is held back.
- **Updates:** an app folder with an update marker or a running installer is held back for the whole run.
- **Open files:** the item is flagged; cleaning will be partial until the app is closed.
- **Sentinel:** key material in a folder (`id_rsa*`, `.env`, `*.pfx`, `*.kdbx`, a `.pem` holding a private key) holds it back for good. Three or more documents or media files lower its confidence.
- **Confidence:** below 0.60 an item is shown but never removed.
- **Overlap:** a tool's rule claims its folders; generic detectors skip anything inside or around them.

## Removal

- `Invoke-WinnowClean -WhatIf` shows the plan without changes. In `Start-Winnow`, Enter alone means no.
- The plan stops if it touches more than 250,000 files, takes more than 25 GB from one rule, or more than 60% of a drive's used space. `-Force` lifts these limits, never the guard.
- A cache in use is cleaned with the tool's own command (`npm cache clean --force`, `uv cache clean`, `pnpm store prune`, `pip cache purge`). Copies at old locations are deleted directly.
- `Remove-WinnowPath`: checks the guard, measures, detaches every link inside the folder, deletes (retrying without read-only attributes, then with `robocopy` as a last resort), and measures what is left.
- Each run writes `%LOCALAPPDATA%\Winnow\runs\<run id>.json`: what was planned and removed, bytes per item, drive free-space change, and anything left with the reason.

## Processes and files

- **Started:** `uv`, `npm`, `pnpm` and `pip`, with fixed arguments from the rules, a timeout, the profile folder as working directory and update checks off (`NO_UPDATE_NOTIFIER`, `PIP_DISABLE_PIP_VERSION_CHECK`, `UV_OFFLINE`, `DO_NOT_TRACK`). `npm` and `pnpm` start through `cmd.exe`. `robocopy.exe` runs only inside `Remove-WinnowPath`.
- **Registry:** read-only (installed programs).
- **Written:** run records under `%LOCALAPPDATA%\Winnow\runs` only.

## Tests

`tests/Run-Tests.ps1` needs nothing installed and runs in CI on every push.

| Guarantee | Tests |
|---|---|
| One removal path | no delete API outside Remove-Safely.ps1; delete primitive not exported |
| Offline | no network API; child processes run with update checks off |
| No admin | no elevation, service or scheduled-task API; no rule requires admin |
| Guard | 49 paths refused, 6 permitted; projects, links and key material fixtures |
| Links | removing a tree with a junction leaves its target alone; last-resort purge stays inside its target |
| In use | a folder a running program executes from is held back |
| Secrets | key material holds a folder back; certificate bundles do not |
| Numbers | freed space measured on disk; no finding inside another |
| Read-only scan | a scan changes nothing; `-WhatIf` changes nothing |

## Limits

- Removal is permanent; the Recycle Bin is not used yet.
- A cache an app keeps open is cleaned partly; the rest is listed.
- Only locations covered by rules are found.
- Tools Winnow starts are third-party programs; only their known update checks are disabled.

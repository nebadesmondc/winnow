# Contributing

## Rules

- Every change happens in `src/Winnow/Private/Change.ps1`, and every removal goes through `Remove-WinnowPath` there. No other file deletes, copies, moves, sets permissions or sets environment variables.
- No literal paths in rules. Locations come from the tool, its environment variable or its default under a root such as `LOCALAPPDATA`.
- Every rule has a `Verdict` and a `Consequence`: one sentence on what removing the item costs.
- No network calls, elevation, services or scheduled tasks. The only registry write is the user environment variable a rule's `Move` names.
- Windows PowerShell 5.1 syntax: no `? :`, `??`, `&&` or classes.

The test suite enforces each of these.

## Tests and lint

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1 -Detail
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

The tests need nothing installed. Fixtures go in a temporary `%LOCALAPPDATA%\winnow-selftest-*` folder. A scan of a fake drive runs every rule end to end, and each movable cache in it is moved to a second fixed drive and back when there is one; locally those moves set process variables only. A read-only scan of the machine follows, except on CI, where it runs only when the workflow is started by hand with full scan on. `SpaceWalker.cs` is compiled once per session; start a new one after changing it.

## Adding a rule

Rules live in `src/Winnow/Rules/*.rules.ps1`:

```powershell
@{
    Id       = 'cache.pip'
    Title    = 'pip wheel cache'
    Verdict  = 'Clean'                     # Clean | Move | YourCall | HandsOff
    Resolve  = @(
        @{ Type = 'Cli';  Command = 'pip'; Args = 'cache dir'; TimeoutSec = 20 }
        @{ Type = 'Env';  Name = 'PIP_CACHE_DIR' }
        @{ Type = 'Path'; Base = 'LOCALAPPDATA'; Sub = 'pip\cache' }
    )
    Reclaim  = @(
        @{ Type = 'VendorCli'; Command = 'pip'; Args = 'cache purge' }
        @{ Type = 'Delete' }
    )
    MinBytes    = 25MB
    Consequence = 'The next pip install rebuilds or re-downloads wheels. Installed packages and virtual environments are untouched.'
    Docs        = 'https://pip.pypa.io/en/stable/cli/pip_cache/'
}
```

`Resolve` steps are tried in order and every existing folder is kept. The first is the cache in use. Later ones are reported as old locations and deleted directly, never through the tool's own command. `Cli` and `Env` steps can add `Sub` to target a folder inside the tool's root.

| Field | Use |
|---|---|
| `Target = 'Children'`, `Keep = @(...)` | Offer each child folder separately, except those named |
| `Target = 'Glob'`, `Glob = '*.nupkg'` | Offer matching files in the root |
| `MinAgeDays` | Skip anything modified more recently |
| `RequiresClosed = @('java')` | Hold the item back while this process runs |
| `AllowsInsideProject = @('node_modules')` | Allow this build folder inside a source project |
| `ExpectsDocuments = $true` | Skip the documents check (never the key check) |
| `Reclaim = @(@{ Type = 'ReportOnly' })` | Explain the item, never remove it |
| `Steps = @(...)` | The steps `winnow explain` shows, for items Winnow does not act on |
| `Discover = { ... }` | A detector instead of `Resolve`; runs after the drive walk and tool rules, and skips folders they own |
| `Move = @{ Id; Title; Env; ... }` | Lets `winnow move` take the tool's folder; see below |

`Move` names the environment variable that points the tool at its folder. `Up = 1` moves the parent of the resolved folder (the whole `npm-cache`, not `_cacache`). `Verify = @{ Command; Args }` asks the tool where its folder is after the move; without it, only the variable is checked. `RequiresClosed` holds the move while a process runs, `PathFolder = 'bin'` refuses it while that subfolder holds programs on `PATH`, and `Note` is shown in the plan. `PATH` and Windows' own variables are refused.

A detector returns objects with a `Path` and an optional `Extra` holding `Title`, `Id`, `Evidence`, `Steps` or `RequiresClosed` for that item. Detectors read sizes and file names from the drive walk (`$script:WinnowWalk`) rather than the disk.

A rule must never target a tool's settings, credentials, installed packages or virtual environments.

## Pull requests

Open an issue first for anything larger than a rule or a fix. Report security problems through [SECURITY.md](SECURITY.md).

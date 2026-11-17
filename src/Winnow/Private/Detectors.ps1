# Generic detectors: find candidates by name and structure, not fixed paths.

# Directory names that hold regenerable cache
$script:WinnowCacheDirNames = @(
    'Cache', 'Code Cache', 'CachedData', 'CachedExtensions', 'CachedProfilesData',
    'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache',
    'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache',
    'Crashpad', 'Crash Reports', 'CrashDumps',
    'BrowserMetrics', 'DeferredBrowserMetrics',
    'component_crx_cache', 'extensions_crx_cache',
    'Safe Browsing', 'blob_storage', 'CacheStorage', 'ScriptCache',
    'logs', 'Log', 'Logs'
)

# Directory names that hold state (logins, bookmarks, settings); never offered
$script:WinnowStateDirNames = @(
    'Local Storage', 'Session Storage', 'IndexedDB', 'databases', 'File System',
    'Local Extension Settings', 'Managed Extension Settings', 'Sync Data',
    'Sync App Settings', 'Extensions', 'Extension State', 'Extension Rules',
    'Extension Scripts', 'Bookmarks', 'Login Data', 'Cookies', 'Network',
    'Preferences', 'History', 'Web Data', 'Favicons', 'shared_proto_db',
    'Service Worker', 'WebStorage', 'Storage', 'User Data', 'Profile',
    'Default', 'databases', 'Session Storage'
)

function Get-WinnowConventionalCacheCandidate {
    <#
    .SYNOPSIS
    Finds cache directories by name in each app folder under %LOCALAPPDATA%
    and %APPDATA%, up to MaxDepth levels deep. Never returns a state directory
    or descends into a match.
    #>
    [CmdletBinding()]
    param([int]$MaxDepth = 3)

    $out = New-Object System.Collections.Generic.List[object]
    $bases = @()
    foreach ($b in @('LOCALAPPDATA', 'APPDATA')) {
        $r = Get-WinnowEnvRoot -Base $b
        if ($r) { $bases += $r }
    }

    foreach ($base in $bases) {
        foreach ($app in (Get-WinnowChildDirectory -Path $base)) {

            # Temp has its own rule; Programs holds installations.
            if ($app.Name -in @('Temp', 'Programs', 'Microsoft')) { continue }

            $stack = New-Object System.Collections.Generic.Stack[object]
            $stack.Push(@($app.Path, 1))

            while ($stack.Count -gt 0) {
                $frame = $stack.Pop()
                $dir = $frame[0]
                $depth = [int]$frame[1]

                foreach ($child in (Get-WinnowChildDirectory -Path $dir)) {

                    $isState = $false
                    foreach ($s in $script:WinnowStateDirNames) {
                        if ($child.Name.Equals($s, [System.StringComparison]::OrdinalIgnoreCase)) { $isState = $true; break }
                    }

                    $isCache = $false
                    foreach ($c in $script:WinnowCacheDirNames) {
                        if ($child.Name.Equals($c, [System.StringComparison]::OrdinalIgnoreCase)) { $isCache = $true; break }
                    }

                    # A name on both lists counts as state.
                    if ($isCache -and -not $isState) {
                        $out.Add([pscustomobject]@{
                            Path   = $child.Path
                            Detail = "cache directory '$($child.Name)' belonging to '$($app.Name)'"
                            Extra  = [pscustomobject]@{
                                Title = "$($app.Name) - $($child.Name)"
                            }
                        })
                        continue    # never descend into a directory we will remove
                    }

                    # State folders can hold caches (Service Worker\CacheStorage).
                    if ($depth -lt $MaxDepth) { $stack.Push(@($child.Path, $depth + 1)) }
                }
            }
        }
    }
    return $out
}

function Get-WinnowAppliedInstallerCandidate {
    <#
    .SYNOPSIS
    Finds installers and Squirrel packages that were already applied. Requires
    the owning app to be installed and the file to be MinAgeDays old, so a
    pending update is never offered.
    #>
    [CmdletBinding()]
    param([int]$MinAgeDays = 14)

    $out = New-Object System.Collections.Generic.List[object]
    $base = Get-WinnowEnvRoot -Base 'LOCALAPPDATA'
    if (-not $base) { return $out }

    $cutoff = (Get-Date).AddDays(-$MinAgeDays)
    $appDirs = @(Get-WinnowChildDirectory -Path $base)
    $appNames = @{}
    foreach ($a in $appDirs) { $appNames[($a.Name -replace '[^A-Za-z0-9]', '').ToLower()] = $a.Path }

    foreach ($app in $appDirs) {

        # An updater folder holding an installer
        if ($app.Name -match '(?i)[-_.]?updater$' -or $app.Name -match '(?i)-update$') {
            $stem = ($app.Name -replace '(?i)[-_.]?updat(er|e)$', '')
            $stemKey = ($stem -replace '[^A-Za-z0-9]', '').ToLower()

            $applied = $false
            $why = $null
            if ($stemKey -and $appNames.ContainsKey($stemKey)) {
                $applied = $true
                $why = "the application folder '$stem' exists alongside it"
            } else {
                foreach ($e in (Get-WinnowUninstallEntry)) {
                    $dn = ($e.DisplayName -replace '[^A-Za-z0-9]', '').ToLower()
                    if ($stemKey -and $dn -and ($dn -match [regex]::Escape($stemKey))) {
                        $applied = $true
                        $why = "'$($e.DisplayName)' is installed"
                        break
                    }
                }
            }
            if (-not $applied) { continue }

            foreach ($f in (Get-WinnowChildFile -Path $app.Path -Filter '*.exe')) {
                if ($f.LastWriteTime -gt $cutoff) { continue }
                $out.Add([pscustomobject]@{
                    Path   = $f.Path
                    Detail = "downloaded installer, last written $($f.LastWriteTime.ToString('yyyy-MM-dd'))"
                    Extra  = [pscustomobject]@{
                        Evidence = @("$why, so this installer has already been applied")
                    }
                })
            }
            continue
        }

        # Squirrel .nupkg downloads
        $pkgDir = Join-Path $app.Path 'packages'
        if (Test-WinnowPathExists -Path $pkgDir) {
            # Installed when an app-<version> folder exists
            $hasVersionDir = $false
            foreach ($c in (Get-WinnowChildDirectory -Path $app.Path)) {
                if ($c.Name -match '(?i)^app-[0-9]') { $hasVersionDir = $true; break }
            }
            if ($hasVersionDir) {
                foreach ($f in (Get-WinnowChildFile -Path $pkgDir -Filter '*.nupkg')) {
                    if ($f.LastWriteTime -gt $cutoff) { continue }
                    $out.Add([pscustomobject]@{
                        Path   = $f.Path
                        Detail = "Squirrel package payload for '$($app.Name)', last written $($f.LastWriteTime.ToString('yyyy-MM-dd'))"
                        Extra  = [pscustomobject]@{
                            Evidence = @('the unpacked application directory exists, so this payload has been applied')
                        }
                    })
                }
            }
        }

        # Squirrel scratch space
        foreach ($scratch in @('SquirrelTemp', 'Update.exe.old')) {
            $sp = Join-Path $app.Path $scratch
            if (-not (Test-WinnowPathExists -Path $sp)) { continue }
            $info = $null
            try { $info = Get-Item -LiteralPath $sp -Force -ErrorAction Stop } catch { continue }
            if ($info.LastWriteTime -gt $cutoff) { continue }
            $out.Add([pscustomobject]@{
                Path   = $sp
                Detail = "installer scratch space for '$($app.Name)', last written $($info.LastWriteTime.ToString('yyyy-MM-dd'))"
                Extra  = $null
            })
        }
    }
    return $out
}

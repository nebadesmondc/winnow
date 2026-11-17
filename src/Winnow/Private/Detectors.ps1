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

# Never looked inside: installed packages can have folders with cache names.
$script:WinnowPackageTreeNames = @('node_modules', 'site-packages', 'vendor')

function Get-WinnowConventionalCacheCandidate {
    <#
    .SYNOPSIS
    Finds cache folders by name inside each app folder under %LOCALAPPDATA%
    and %APPDATA%, from the drive walk. Never returns a state folder, a folder
    inside another match, or anything inside an installed package.
    #>
    [CmdletBinding()]
    param(
        [object]$Walk = $script:WinnowWalk,
        [int]$MaxDepth = 6
    )

    $out = New-Object System.Collections.Generic.List[object]
    if (-not $Walk) { return $out }

    $cacheNames = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$script:WinnowCacheDirNames, [System.StringComparer]::OrdinalIgnoreCase)
    $stateNames = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$script:WinnowStateDirNames, [System.StringComparer]::OrdinalIgnoreCase)
    $packageNames = New-Object 'System.Collections.Generic.HashSet[string]' ([string[]]$script:WinnowPackageTreeNames, [System.StringComparer]::OrdinalIgnoreCase)

    foreach ($b in @('LOCALAPPDATA', 'APPDATA')) {
        $base = Get-WinnowEnvRoot -Base $b
        if (-not $base) { continue }
        $prefixLength = $base.TrimEnd('\').Length + 1

        foreach ($d in $Walk.FoldersUnder($base)) {
            $segments = $d.Path.Substring($prefixLength).Split('\')
            if ($segments.Count -lt 2 -or $segments.Count -gt $MaxDepth + 1) { continue }

            # Temp has its own rule; Programs holds installations.
            if ($segments[0] -in @('Temp', 'Programs', 'Microsoft')) { continue }

            # A name on both lists counts as state.
            $leaf = $segments[-1]
            if (-not $cacheNames.Contains($leaf) -or $stateNames.Contains($leaf)) { continue }

            $inside = $false
            for ($i = 0; $i -lt $segments.Count - 1; $i++) {
                $s = $segments[$i]
                if ($packageNames.Contains($s)) { $inside = $true; break }
                if ($i -gt 0 -and $cacheNames.Contains($s) -and -not $stateNames.Contains($s)) { $inside = $true; break }
            }
            if ($inside) { continue }

            $app = $segments[0]
            # Store apps: "5319275A.WhatsAppDesktop_cv1g1gvanyjgm" -> "WhatsAppDesktop"
            if ($app -eq 'Packages' -and $segments[1] -match '^(?:[^.]+\.)?([^_]+)_') { $app = $Matches[1] }

            $out.Add([pscustomobject]@{
                Path   = $d.Path
                Detail = "cache folder '$leaf' of $app"
                Extra  = [pscustomobject]@{ Title = "$app - $leaf" }
            })
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

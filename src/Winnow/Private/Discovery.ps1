# Location discovery and install detection.

function Resolve-WinnowRoot {
    <#
    .SYNOPSIS
    Walks a rule's Resolve chain and returns the first existing path, or with
    -All every distinct one. The first is the location in use (Primary); later
    ones are copies elsewhere, such as the default location after a redirect.
    A hit nested in, or containing, an earlier one is skipped.

    .OUTPUTS
    [pscustomobject] Path, Strategy, Detail, Primary  (or $null when nothing resolved)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Resolve,
        [switch]$All
    )

    $found = New-Object System.Collections.Generic.List[object]

    foreach ($step in $Resolve) {
        $candidate = $null
        $strategy = $step.Type
        $detail = $null

        switch ($step.Type) {

            'Cli' {
                $timeout = 10
                if ($step.ContainsKey('TimeoutSec')) { $timeout = [int]$step.TimeoutSec }
                if (-not (Get-Command -Name $step.Command -ErrorAction SilentlyContinue)) { continue }
                $out = Invoke-WinnowCli -Command $step.Command -Arguments $step.Args -TimeoutSec $timeout
                if ([string]::IsNullOrWhiteSpace($out)) { continue }
                # Take the first line that looks like an absolute path.
                foreach ($line in ($out -split "`r?`n")) {
                    $t = $line.Trim().Trim('"')
                    if ([string]::IsNullOrWhiteSpace($t)) { continue }
                    if ($t -match '^[A-Za-z]:\\' -or $t -match '^[\\/]{2}' -or $t -match '^/') {
                        $candidate = $t
                        break
                    }
                    # Some CLIs print "global-packages: <path>".
                    if ($t -match ':\s+([A-Za-z]:\\.+)$') { $candidate = $Matches[1]; break }
                }
                $detail = "resolved via ``$($step.Command) $($step.Args)``"
            }

            'Env' {
                $names = @($step.Name)
                foreach ($n in $names) {
                    $v = [System.Environment]::GetEnvironmentVariable($n)
                    if (-not [string]::IsNullOrWhiteSpace($v)) {
                        $candidate = $v
                        $detail = "resolved via `$env:$n"
                        break
                    }
                }
            }

            'Path' {
                $bases = @($step.Base)
                foreach ($b in $bases) {
                    $root = Get-WinnowEnvRoot -Base $b
                    if (-not $root) { continue }
                    $try = $root
                    if ($step.ContainsKey('Sub') -and $step.Sub) {
                        $try = Join-Path $root ($step.Sub -replace '/', '\')
                    }
                    if (Test-WinnowPathExists -Path $try) {
                        $candidate = $try
                        $detail = "found by convention under `$env:$b"
                        break
                    }
                }
            }
        }

        # Cli/Env return a tool root; Sub narrows it (GRADLE_USER_HOME\caches).
        # Path steps applied Sub above.
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $step.Type -ne 'Path' -and
            $step.ContainsKey('Sub') -and $step.Sub) {
            $candidate = Join-Path $candidate ($step.Sub -replace '/', '\')
        }

        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $canon = ConvertTo-WinnowFullPath $candidate
        if (-not $canon) { continue }
        if (-not (Test-WinnowPathExists -Path $canon)) { continue }

        $overlaps = $false
        foreach ($f in $found) {
            if ((Test-WinnowPathUnder -Path $canon -Root $f.Path) -or (Test-WinnowPathUnder -Path $f.Path -Root $canon)) {
                $overlaps = $true
                break
            }
        }
        if ($overlaps) { continue }

        $hit = [pscustomobject]@{
            Path     = $canon
            Strategy = $strategy
            Detail   = $detail
            Primary  = ($found.Count -eq 0)
        }
        if (-not $All) { return $hit }
        $found.Add($hit)
    }
    if ($All) { return $found }
    return $null
}

function Get-WinnowUninstallEntry {
    <#
    .SYNOPSIS
    Cached snapshot of installed-program registry entries (all three hives).
    #>
    param([switch]$Refresh)

    if ($script:WinnowUninstallCache -and -not $Refresh) { return $script:WinnowUninstallCache }

    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        $items = $null
        try { $items = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue } catch { }
        if (-not $items) { continue }
        foreach ($i in $items) {
            if ([string]::IsNullOrWhiteSpace($i.DisplayName)) { continue }
            $loc = $null
            if ($i.PSObject.Properties['InstallLocation'] -and $i.InstallLocation) {
                $loc = ConvertTo-WinnowFullPath $i.InstallLocation
            }
            $list.Add([pscustomobject]@{
                DisplayName     = $i.DisplayName
                DisplayVersion  = $i.DisplayVersion
                InstallLocation = $loc
            })
        }
    }
    $script:WinnowUninstallCache = $list
    return $list
}

function Get-WinnowShortcutTarget {
    <#
    .SYNOPSIS
    Cached snapshot of Start Menu shortcut targets (user + machine).
    #>
    param([switch]$Refresh)

    if ($script:WinnowShortcutCache -and -not $Refresh) { return $script:WinnowShortcutCache }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('StartMenu', 'CommonStartMenu')) {
        $p = Get-WinnowKnownFolder -Name $n
        if ($p) { $roots.Add($p) }
    }

    $targets = New-Object System.Collections.Generic.List[string]
    $shell = $null
    try { $shell = New-Object -ComObject WScript.Shell } catch { }

    foreach ($r in $roots) {
        if (-not (Test-WinnowPathExists -Path $r)) { continue }
        $links = $null
        try { $links = Get-ChildItem -LiteralPath $r -Filter *.lnk -Recurse -ErrorAction SilentlyContinue } catch { }
        if (-not $links) { continue }
        foreach ($l in $links) {
            if (-not $shell) { break }
            try {
                $sc = $shell.CreateShortcut($l.FullName)
                if (-not [string]::IsNullOrWhiteSpace($sc.TargetPath)) {
                    $targets.Add((ConvertTo-WinnowFullPath $sc.TargetPath))
                }
            } catch { }
        }
    }
    if ($shell) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { } }

    $script:WinnowShortcutCache = $targets
    return $targets
}

function Test-WinnowAppInstalled {
    <#
    .SYNOPSIS
    Six probes for whether the app owning a directory is still installed. All
    probes run, so one ambiguous signal cannot decide the answer.

    .OUTPUTS
    [pscustomobject] Verdict ('Installed'|'NotInstalled'|'Unknown'),
                     Conclusive (int), Probes (hashtable), Evidence (string[])
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Name
    )

    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $Name) { $Name = [System.IO.Path]::GetFileName($canon) }

    $probes = [ordered]@{
        UninstallRegistry = 'Unknown'
        AppPaths          = 'Unknown'
        AppxPackage       = 'Unknown'
        ExecutablePresent = 'Unknown'
        StartMenuShortcut = 'Unknown'
        RunningProcess    = 'Unknown'
    }
    $evidence = New-Object System.Collections.Generic.List[string]

    $nameToken = ($Name -replace '[^A-Za-z0-9]', '')
    if ($nameToken.Length -lt 3) { $nameToken = $null }

    # 1. Uninstall registry: name match, or an InstallLocation inside/at the path.
    $regHit = $false
    foreach ($e in (Get-WinnowUninstallEntry)) {
        if ($e.InstallLocation -and (Test-WinnowPathUnder -Path $e.InstallLocation -Root $canon)) {
            $regHit = $true
            $evidence.Add("uninstall entry '$($e.DisplayName)' installs into this path")
            break
        }
        if ($nameToken) {
            $dn = ($e.DisplayName -replace '[^A-Za-z0-9]', '')
            if ($dn -and ($dn -match [regex]::Escape($nameToken) -or $nameToken -match [regex]::Escape($dn))) {
                $regHit = $true
                $evidence.Add("uninstall entry '$($e.DisplayName)' matches the name")
                break
            }
        }
    }
    if ($regHit) { $probes.UninstallRegistry = 'Installed' }
    else {
        $probes.UninstallRegistry = 'NotInstalled'
        $evidence.Add('no matching entry in the uninstall registry')
    }

    # 2. App Paths.
    $appPathHit = $false
    foreach ($hive in @('HKCU:', 'HKLM:')) {
        $k = "$hive\Software\Microsoft\Windows\CurrentVersion\App Paths"
        $subs = $null
        try { $subs = Get-ChildItem -Path $k -ErrorAction SilentlyContinue } catch { }
        if (-not $subs) { continue }
        foreach ($s in $subs) {
            $def = $null
            try { $def = (Get-ItemProperty -Path $s.PSPath -ErrorAction SilentlyContinue).'(default)' } catch { }
            if ([string]::IsNullOrWhiteSpace($def)) { continue }
            $t = ConvertTo-WinnowFullPath ($def.Trim('"'))
            if ($t -and (Test-WinnowPathUnder -Path $t -Root $canon)) { $appPathHit = $true; break }
        }
        if ($appPathHit) { break }
    }
    if ($appPathHit) {
        $probes.AppPaths = 'Installed'
        $evidence.Add('registered under App Paths')
    } else {
        $probes.AppPaths = 'NotInstalled'
    }

    # 3. MSIX / Store packages.
    if ($nameToken -and (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        $pkg = $null
        try { $pkg = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { ($_.Name -replace '[^A-Za-z0-9]', '') -match [regex]::Escape($nameToken) } } catch { }
        if ($pkg) {
            $probes.AppxPackage = 'Installed'
            $evidence.Add('a matching MSIX/Store package is installed')
        } else {
            $probes.AppxPackage = 'NotInstalled'
        }
    }

    # 4. An executable inside the tree. Bounded walk: presence, not a census.
    $exeCount = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-WinnowLongPath $canon))
    $visited = 0
    while ($stack.Count -gt 0 -and $visited -lt 400 -and $exeCount -eq 0) {
        $dir = $stack.Pop(); $visited++
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo($dir) } catch { continue }
        try {
            if ($di.GetFiles('*.exe').Count -gt 0) { $exeCount++; break }
        } catch { }
        try {
            foreach ($sub in $di.GetDirectories()) {
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($sub.FullName)
            }
        } catch { }
    }
    if ($exeCount -gt 0) {
        $probes.ExecutablePresent = 'Installed'
        $evidence.Add('an executable is present inside the directory')
    } else {
        $probes.ExecutablePresent = 'NotInstalled'
        $evidence.Add('no executable found anywhere inside the directory')
    }

    # 5. Start Menu shortcut pointing into the tree, or matching by name.
    $scHit = $false
    foreach ($t in (Get-WinnowShortcutTarget)) {
        if ($t -and (Test-WinnowPathUnder -Path $t -Root $canon)) { $scHit = $true; break }
        if ($nameToken -and $t) {
            $leaf = ([System.IO.Path]::GetFileNameWithoutExtension($t) -replace '[^A-Za-z0-9]', '')
            if ($leaf -and $leaf -match [regex]::Escape($nameToken)) { $scHit = $true; break }
        }
    }
    if ($scHit) {
        $probes.StartMenuShortcut = 'Installed'
        $evidence.Add('a Start Menu shortcut references it')
    } else {
        $probes.StartMenuShortcut = 'NotInstalled'
        $evidence.Add('no Start Menu shortcut references it')
    }

    # 6. Running process.
    $locks = @(Get-WinnowPathLock -Path $canon)
    if ($locks.Count -gt 0) {
        $probes.RunningProcess = 'Installed'
        $evidence.Add("a running process executes from here ($(($locks | Select-Object -ExpandProperty Name -Unique) -join ', '))")
    } else {
        $probes.RunningProcess = 'NotInstalled'
    }

    $installed = 0; $notInstalled = 0; $conclusive = 0
    foreach ($k in $probes.Keys) {
        if ($probes[$k] -eq 'Installed') { $installed++; $conclusive++ }
        elseif ($probes[$k] -eq 'NotInstalled') { $notInstalled++; $conclusive++ }
    }

    $verdict = 'Unknown'
    if ($installed -gt 0) { $verdict = 'Installed' }
    elseif ($notInstalled -ge 4) { $verdict = 'NotInstalled' }

    return [pscustomobject]@{
        Verdict    = $verdict
        Conclusive = $conclusive
        Negatives  = $notInstalled
        Probes     = $probes
        Evidence   = $evidence
    }
}

function Reset-WinnowDiscoveryCache {
    $script:WinnowUninstallCache = $null
    $script:WinnowShortcutCache = $null
}

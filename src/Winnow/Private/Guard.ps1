# Path guard: deny first, then require an allow root, so unknown locations
# fail closed. Checks are listed in SAFETY.md.

function Get-WinnowGuardPolicy {
    if ($script:WinnowGuardPolicy) { return $script:WinnowGuardPolicy }

    $win      = ConvertTo-WinnowFullPath $env:WINDIR
    $pf       = ConvertTo-WinnowFullPath $env:ProgramFiles
    $pf86     = $null
    $pf86Raw  = ${env:ProgramFiles(x86)}
    if ($pf86Raw) { $pf86 = ConvertTo-WinnowFullPath $pf86Raw }
    $progData = ConvertTo-WinnowFullPath $env:ProgramData
    $userHome = ConvertTo-WinnowFullPath $env:USERPROFILE
    $local    = ConvertTo-WinnowFullPath $env:LOCALAPPDATA
    $roaming  = ConvertTo-WinnowFullPath $env:APPDATA
    $temp     = ConvertTo-WinnowFullPath $env:TEMP

    # Deny roots
    $denyRoots = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($win, $pf, $pf86)) {
        if ($p) { $denyRoots.Add($p) }
    }
    if ($progData) {
        # MSI repair sources; removing them breaks repair and uninstall.
        $denyRoots.Add((Join-Path $progData 'Package Cache'))
    }

    # Matched on any drive
    $denyVolumeRelative = @(
        'System Volume Information', '$Recycle.Bin', 'Recovery', 'Boot', 'EFI',
        'Config.Msi', '$WinREAgent', 'Windows.old', 'PerfLogs'
    )

    # Denied by file name, anywhere
    $denyFileNames = @(
        'pagefile.sys', 'swapfile.sys', 'hiberfil.sys',
        'DumpStack.log', 'DumpStack.log.tmp', 'bootmgr', 'BOOTNXT', 'ntldr'
    )

    # User content
    $userContent = New-Object System.Collections.Generic.List[string]
    foreach ($n in @('Documents', 'Desktop', 'Pictures', 'Music', 'Videos',
                     'Favorites', 'Contacts', 'Links', 'Saved Games', 'Searches')) {
        $kf = Get-WinnowKnownFolder -Name $n
        if ($kf) { $userContent.Add($kf) }
        if ($userHome) { $userContent.Add((Join-Path $userHome $n)) }
    }
    if ($userHome) {
        $userContent.Add((Join-Path $userHome 'Downloads'))
        # Cloud sync roots
        foreach ($child in @('OneDrive', 'Dropbox', 'Google Drive', 'iCloudDrive', 'Box', 'Sync')) {
            $userContent.Add((Join-Path $userHome $child))
        }
        try {
            foreach ($d in [System.IO.Directory]::GetDirectories((ConvertTo-WinnowLongPath $userHome))) {
                $leaf = [System.IO.Path]::GetFileName($d)
                if ($leaf -like 'OneDrive*' -or $leaf -like 'Dropbox*' -or
                    $leaf -like '*Google Drive*' -or $leaf -like 'Nextcloud*') {
                    $userContent.Add((Join-Path $userHome $leaf))
                }
            }
        } catch { }
    }

    # Credentials and secrets
    $credentialDirNames = @(
        '.ssh', '.gnupg', '.gpg', '.aws', '.azure', '.kube', '.docker',
        'Microsoft\Credentials', 'Microsoft\Protect', 'Microsoft\Vault',
        'Microsoft\SystemCertificates', 'credentials'
    )
    $credentialFilePatterns = @(
        '*.pem', '*.ppk', '*.pfx', '*.p12', '*.key', '*.kdbx', '*.keytab',
        '*.asc', '*.gpg', '*.jks', 'id_rsa*', 'id_ed25519*', 'id_ecdsa*',
        '.env', '.env.*', '.npmrc', '.pypirc', '.git-credentials', '.netrc'
    )

    # Source project markers
    $projectMarkers = @(
        '.git', '.hg', '.svn', '.jj', 'pom.xml', 'build.gradle', 'build.gradle.kts',
        'pyproject.toml', 'Cargo.toml', 'go.mod', 'package.json', 'CMakeLists.txt'
    )

    # Installed editor extensions ship a package.json but are not source.
    $extensionRoots = New-Object System.Collections.Generic.List[string]
    if ($userHome) {
        foreach ($e in @('.vscode', '.vscode-insiders', '.cursor', '.windsurf')) {
            $extensionRoots.Add((Join-Path $userHome "$e\extensions"))
        }
    }

    # A path must be under one of these, and not be one of them
    $allowRoots = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($local, $roaming, $temp, $userHome, $progData)) {
        if ($p) { $allowRoots.Add($p) }
    }

    $script:WinnowGuardPolicy = [pscustomobject]@{
        DenyRoots              = $denyRoots
        DenyVolumeRelative     = $denyVolumeRelative
        DenyFileNames          = $denyFileNames
        UserContentRoots       = $userContent
        CredentialDirNames     = $credentialDirNames
        CredentialFilePatterns = $credentialFilePatterns
        VirtualDiskPatterns    = $script:WinnowVirtualDiskPatterns
        ProjectMarkers         = $projectMarkers
        ExtensionRoots         = $extensionRoots
        AllowRoots             = $allowRoots
        MinSegments            = 3
        ProjectLookupDepth     = 4
    }
    return $script:WinnowGuardPolicy
}

function Reset-WinnowGuardPolicy {
    # Test hook
    $script:WinnowGuardPolicy = $null
    $script:WinnowVolumeCache = $null
}

function Test-WinnowPathUnder {
    <#
    .SYNOPSIS
    True when $Path is $Root or beneath it. Case-insensitive; "C:\Foo" does
    not match "C:\Foobar".
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()][string]$Root
    )
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $p = $Path.TrimEnd('\')
    $r = $Root.TrimEnd('\')
    if ($p.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-WinnowGuard {
    <#
    .SYNOPSIS
    Decides whether a path may be removed. Returns an object, never throws.

    .OUTPUTS
    [pscustomobject] Allowed (bool), Reason (string), Path (canonical)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path,
        [string[]]$AllowsInsideProject = @(),
        # The destination a move record names; only that exact folder passes check 12.
        [string]$MoveTarget
    )

    function _deny($reason, $canon) {
        return [pscustomobject]@{ Allowed = $false; Reason = $reason; Path = $canon }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) { return (_deny 'empty path' $Path) }

    # 1. Canonicalise ('..', mixed separators)
    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return (_deny 'path could not be canonicalised' $Path) }
    if ($canon -match '^[\\/]{2}[?.]') { return (_deny 'device-namespace path' $canon) }

    $policy = Get-WinnowGuardPolicy

    # 2. Drive roots and shallow paths
    $root = [System.IO.Path]::GetPathRoot($canon)
    if ($canon.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (_deny 'drive root' $canon)
    }
    $segments = @($canon.Substring($root.Length).Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($segments.Count -lt ($policy.MinSegments - 1)) {
        return (_deny "path too shallow ($($segments.Count) segment(s) below root)" $canon)
    }

    # 3. Fixed local disks only
    if (-not (Test-WinnowFixedVolume -Path $canon)) {
        return (_deny 'not on a local fixed volume' $canon)
    }

    # 4. System files
    $leaf = [System.IO.Path]::GetFileName($canon)
    foreach ($n in $policy.DenyFileNames) {
        if ($leaf.Equals($n, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (_deny "protected system file '$n'" $canon)
        }
    }

    # 5. Windows, Program Files, Package Cache
    foreach ($d in $policy.DenyRoots) {
        if (Test-WinnowPathUnder -Path $canon -Root $d) {
            return (_deny "inside protected system location '$d'" $canon)
        }
    }

    # 6. Protected volume folders
    foreach ($vr in $policy.DenyVolumeRelative) {
        if (Test-WinnowPathUnder -Path $canon -Root (Join-Path $root $vr)) {
            return (_deny "inside protected location '$vr'" $canon)
        }
    }

    # 7. User content
    foreach ($u in $policy.UserContentRoots) {
        if (Test-WinnowPathUnder -Path $canon -Root $u) {
            return (_deny "inside user content location '$u'" $canon)
        }
    }

    # 8. Credential directories
    foreach ($seg in $segments) {
        foreach ($c in $policy.CredentialDirNames) {
            if (-not $c.Contains('\')) {
                if ($seg.Equals($c, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return (_deny "credential directory '$seg'" $canon)
                }
            }
        }
    }
    foreach ($c in $policy.CredentialDirNames) {
        if ($c.Contains('\')) {
            if ($canon -match ([regex]::Escape('\' + $c))) {
                return (_deny "credential directory '$c'" $canon)
            }
        }
    }

    # 9. Key, secret and virtual disk files
    foreach ($pat in $policy.CredentialFilePatterns) {
        if ($leaf -like $pat) { return (_deny "credential or key file pattern '$pat'" $canon) }
    }
    foreach ($pat in $policy.VirtualDiskPatterns) {
        if ($leaf -like $pat) { return (_deny "virtual disk file '$pat'" $canon) }
    }

    # 10. Links, and paths reached through one (e.g. "All Users" -> ProgramData)
    if (Test-WinnowPathExists -Path $canon) {
        if (Test-WinnowReparsePoint -Path $canon) {
            return (_deny 'path is a reparse point (junction/symlink)' $canon)
        }
    }
    $walk = [System.IO.Path]::GetDirectoryName($canon)
    $hops = 0
    while ($walk -and $hops -lt 40) {
        if (Test-WinnowPathUnder -Path $walk -Root $root) {
            if ($walk.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { break }
        }
        if (Test-WinnowReparsePoint -Path $walk) {
            return (_deny "reached via reparse point '$walk'" $canon)
        }
        $walk = [System.IO.Path]::GetDirectoryName($walk)
        $hops++
    }

    # 11. Source projects: only a build folder the rule names, never the project
    $projectHit = $null
    $probe = $canon
    for ($i = 0; $i -le $policy.ProjectLookupDepth; $i++) {
        if (-not $probe) { break }
        if ($probe.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = [System.IO.Path]::GetDirectoryName($probe)
        $isExtension = $false
        foreach ($x in $policy.ExtensionRoots) {
            if ($parent -and $parent.Equals($x, [System.StringComparison]::OrdinalIgnoreCase)) { $isExtension = $true }
        }
        foreach ($m in $policy.ProjectMarkers) {
            if ($isExtension -and $m -eq 'package.json') { continue }
            if (Test-WinnowPathExists -Path (Join-Path $probe $m)) {
                $projectHit = [pscustomobject]@{ Dir = $probe; Marker = $m }
                break
            }
        }
        if ($projectHit) { break }
        $probe = [System.IO.Path]::GetDirectoryName($probe)
    }
    if ($projectHit) {
        $permitted = $false
        foreach ($allowed in $AllowsInsideProject) {
            if ($leaf.Equals($allowed, [System.StringComparison]::OrdinalIgnoreCase)) { $permitted = $true }
        }
        if ($projectHit.Dir.TrimEnd('\').Equals($canon.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            $permitted = $false   # never the project root itself
        }
        if (-not $permitted) {
            return (_deny "inside a source project (found '$($projectHit.Marker)' in '$($projectHit.Dir)')" $canon)
        }
    }

    # 12. Allow roots
    if ($MoveTarget) {
        $own = ConvertTo-WinnowFullPath $MoveTarget
        if ($own -and $canon.Equals($own, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [pscustomobject]@{ Allowed = $true; Reason = 'a folder Winnow moved here'; Path = $canon }
        }
    }
    $matched = $null
    foreach ($a in $policy.AllowRoots) {
        if (Test-WinnowPathUnder -Path $canon -Root $a) {
            if ($canon.TrimEnd('\').Equals($a.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
                return (_deny "is an allow-root itself ('$a')" $canon)
            }
            if ($null -eq $matched -or $a.Length -gt $matched.Length) { $matched = $a }
        }
    }
    if (-not $matched) {
        return (_deny 'outside every permitted root (fails closed)' $canon)
    }

    return [pscustomobject]@{ Allowed = $true; Reason = "permitted under '$matched'"; Path = $canon }
}

function Assert-WinnowGuard {
    <#
    .SYNOPSIS
    Throws unless the path may be removed; returns the canonical path.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path,
        [string[]]$AllowsInsideProject = @(),
        [string]$MoveTarget
    )
    $verdict = Test-WinnowGuard -Path $Path -AllowsInsideProject $AllowsInsideProject -MoveTarget $MoveTarget
    if (-not $verdict.Allowed) {
        throw "Winnow guard refused '$Path': $($verdict.Reason)"
    }
    return $verdict.Path
}

function Test-WinnowMoveDestination {
    <#
    .SYNOPSIS
    Decides whether a folder may receive a move from $Source. Returns an
    object, never throws.

    .OUTPUTS
    [pscustomobject] Allowed (bool), Reason (string), Path (canonical)
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    function _deny($reason, $canon) {
        return [pscustomobject]@{ Allowed = $false; Reason = $reason; Path = $canon }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) { return (_deny 'empty path' $Path) }
    if ($Path -notmatch '^[A-Za-z]:\\') { return (_deny 'not a full path on a local drive, such as D:\DevCache\npm' $Path) }
    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return (_deny 'path could not be canonicalised' $Path) }
    $root = [System.IO.Path]::GetPathRoot($canon)
    if ($canon.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (_deny 'a drive root; name a folder on it' $canon)
    }
    if (-not (Test-WinnowFixedVolume -Path $canon)) { return (_deny 'not on a local fixed disk' $canon) }

    $src = ConvertTo-WinnowFullPath $Source
    if ($root.Equals([System.IO.Path]::GetPathRoot($src), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (_deny 'on the same drive; moving there frees nothing' $canon)
    }

    $policy = Get-WinnowGuardPolicy
    foreach ($d in $policy.DenyRoots) {
        if (Test-WinnowPathUnder -Path $canon -Root $d) { return (_deny "inside protected system location '$d'" $canon) }
    }
    foreach ($vr in $policy.DenyVolumeRelative) {
        if (Test-WinnowPathUnder -Path $canon -Root (Join-Path $root $vr)) { return (_deny "inside protected location '$vr'" $canon) }
    }
    foreach ($u in $policy.UserContentRoots) {
        if (Test-WinnowPathUnder -Path $canon -Root $u) { return (_deny "inside user content location '$u'" $canon) }
    }
    $leaf = [System.IO.Path]::GetFileName($canon)
    foreach ($seg in @($canon.Substring($root.Length).Split('\'))) {
        foreach ($cloud in @('OneDrive*', 'Dropbox*', '*Google Drive*', 'iCloudDrive', 'Nextcloud*')) {
            if ($seg -like $cloud) { return (_deny "inside a cloud sync folder '$seg'" $canon) }
        }
    }

    $probe = $canon
    while ($probe -and -not $probe.TrimEnd('\').Equals($root.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        if ((Test-WinnowPathExists -Path $probe) -and (Test-WinnowReparsePoint -Path $probe)) {
            return (_deny "reached via reparse point '$probe'" $canon)
        }
        $probe = [System.IO.Path]::GetDirectoryName($probe)
    }

    $lp = ConvertTo-WinnowLongPath $canon
    if ([System.IO.File]::Exists($lp)) { return (_deny "'$leaf' is a file" $canon) }
    if ([System.IO.Directory]::Exists($lp)) {
        $any = $false
        try { foreach ($e in [System.IO.Directory]::EnumerateFileSystemEntries($lp)) { $any = $true; break } }
        catch { return (_deny "cannot be read: $($_.Exception.Message)" $canon) }
        if ($any) { return (_deny 'the folder is not empty' $canon) }
    }

    return [pscustomobject]@{ Allowed = $true; Reason = 'an empty folder on another fixed disk'; Path = $canon }
}

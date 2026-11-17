# Interlocks: running processes, in-flight updates, open files, sentinel scan.

function Get-WinnowProcessMap {
    <#
    .SYNOPSIS
    Snapshot of running processes with resolvable image paths. Cached per scan.
    #>
    param([switch]$Refresh)

    if ($script:WinnowProcessMap -and -not $Refresh) { return $script:WinnowProcessMap }

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }   # access denied on protected processes
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $list.Add([pscustomobject]@{
            Name = $p.ProcessName
            Id   = $p.Id
            Path = (ConvertTo-WinnowFullPath $path)
        })
    }
    $script:WinnowProcessMap = $list
    return $list
}

function Reset-WinnowProcessMap {
    $script:WinnowProcessMap = $null
}

function Get-WinnowPathLock {
    <#
    .SYNOPSIS
    Returns processes whose executable lives inside $Path.

    .NOTES
    Wrap calls in @(): a single match comes back as a bare object, which has
    no .Count in Windows PowerShell 5.1.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $canon = ConvertTo-WinnowFullPath $Path
    $hits = New-Object System.Collections.Generic.List[object]
    if (-not $canon) { return $hits }

    foreach ($p in (Get-WinnowProcessMap)) {
        if (Test-WinnowPathUnder -Path $p.Path -Root $canon) { $hits.Add($p) }
    }
    return $hits
}

function Test-WinnowProcessRunning {
    param([AllowEmptyCollection()][string[]]$Name = @())

    $running = New-Object System.Collections.Generic.List[string]
    if (-not $Name) { return $running }
    foreach ($n in $Name) {
        if ([string]::IsNullOrWhiteSpace($n)) { continue }
        $bare = $n -replace '\.exe$', ''
        $found = Get-Process -Name $bare -ErrorAction SilentlyContinue
        if ($found) { $running.Add($bare) }
    }
    return $running
}

function Get-WinnowUpdateInFlight {
    <#
    .SYNOPSIS
    Finds application folders that are mid-update; findings beneath them are
    held back for the run.

    .OUTPUTS
    A list of { Root, Evidence } describing subtrees that must not be touched.
    #>
    param([string[]]$SearchRoot)

    if (-not $SearchRoot -or $SearchRoot.Count -eq 0) {
        $SearchRoot = @()
        $l = Get-WinnowEnvRoot 'LOCALAPPDATA'
        if ($l) {
            $SearchRoot += $l
            $progs = Join-Path $l 'Programs'
            if (Test-WinnowPathExists $progs) { $SearchRoot += $progs }
        }
    }

    $markers = @('updating_version', '.updating', 'SquirrelSetup.log', 'installing')
    $found = New-Object System.Collections.Generic.List[object]

    # Update marker files
    foreach ($root in $SearchRoot) {
        foreach ($child in (Get-WinnowChildDirectory -Path $root)) {
            foreach ($m in $markers) {
                $mp = Join-Path $child.Path $m
                if (Test-WinnowPathExists -Path $mp) {
                    $found.Add([pscustomobject]@{
                        Root     = $child.Path
                        Evidence = "update marker file '$m' present"
                    })
                    break
                }
            }
        }
    }

    # A running installer: its own folder, and any app folder its name matches
    foreach ($p in (Get-WinnowProcessMap)) {
        if ($p.Name -notmatch '(?i)(setup|install|updater|msiexec)') { continue }
        $dir = [System.IO.Path]::GetDirectoryName($p.Path)
        if ($dir) {
            $found.Add([pscustomobject]@{
                Root     = $dir
                Evidence = "installer process '$($p.Name)' (pid $($p.Id)) is running"
            })
        }
        foreach ($root in $SearchRoot) {
            foreach ($child in (Get-WinnowChildDirectory -Path $root)) {
                $token = $child.Name -replace '[^A-Za-z0-9]', ''
                if ($token.Length -lt 4) { continue }
                if ($p.Name -replace '[^A-Za-z0-9]', '' -match [regex]::Escape($token)) {
                    $found.Add([pscustomobject]@{
                        Root     = $child.Path
                        Evidence = "installer process '$($p.Name)' matches this application"
                    })
                }
            }
        }
    }

    $seen = @{}
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($f in $found) {
        $k = $f.Root.ToLower()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $unique.Add($f)
    }
    return $unique
}

function Test-WinnowTreeLocked {
    <#
    .SYNOPSIS
    Samples a tree for files held open by another process, by trying an
    exclusive open. Catches apps that run from elsewhere, such as Chrome.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$SampleSize = 6
    )

    $lp = ConvertTo-WinnowLongPath (ConvertTo-WinnowFullPath $Path)
    if (-not [System.IO.Directory]::Exists($lp)) { return $false }

    $checked = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($lp)

    while ($stack.Count -gt 0 -and $checked -lt $SampleSize) {
        $dir = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo($dir) } catch { continue }

        $files = $null
        try { $files = $di.GetFiles() } catch { $files = $null }
        if ($files) {
            foreach ($f in $files) {
                if ($checked -ge $SampleSize) { break }
                if (($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $checked++
                $fs = $null
                try {
                    $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                } catch [System.IO.IOException] {
                    return $true
                } catch {
                    # Access denied is not a lock.
                } finally {
                    if ($fs) { $fs.Close(); $fs.Dispose() }
                }
            }
        }

        try {
            foreach ($sub in $di.GetDirectories()) {
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($sub.FullName)
            }
        } catch { }
    }
    return $false
}

function Test-WinnowSentinel {
    <#
    .SYNOPSIS
    Looks for content that does not belong in a cache. Key material blocks;
    documents and media only lower confidence, as some caches hold a few.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$DocumentThreshold = 3,
        [int]$MaxFilesToScan = 4000
    )

    $verdict = [pscustomobject]@{
        Blocked        = $false
        NeedsConfirm   = $false
        Reason         = $null
        Samples        = (New-Object System.Collections.Generic.List[string])
    }

    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return $verdict }
    $lp = ConvertTo-WinnowLongPath $canon
    if (-not [System.IO.Directory]::Exists($lp)) { return $verdict }

    $secretPatterns = @('*.pem', '*.ppk', '*.pfx', '*.p12', '*.kdbx', '*.keytab',
                        'id_rsa*', 'id_ed25519*', '.env', '.git-credentials', '.netrc')
    $docPatterns    = @('*.docx', '*.xlsx', '*.pptx', '*.pdf', '*.psd', '*.ai',
                        '*.sketch', '*.fig', '*.mp4', '*.mov', '*.mkv', '*.sql',
                        '*.bak', '*.pst', '*.dwg')

    $docHits = 0
    $scanned = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($lp)

    while ($stack.Count -gt 0 -and $scanned -lt $MaxFilesToScan) {
        $dir = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo($dir) } catch { continue }
        $entries = $null
        try { $entries = $di.GetFileSystemInfos() } catch { continue }

        foreach ($e in $entries) {
            if (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($e.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($e.FullName); continue
            }
            $scanned++
            if ($scanned -ge $MaxFilesToScan) { break }

            foreach ($sp in $secretPatterns) {
                if ($e.Name -like $sp) {
                    # Certificate bundles (certifi's cacert.pem) are public.
                    if ($sp -eq '*.pem' -and -not (Test-WinnowPemPrivateKey -Path $e.FullName)) { continue }
                    $verdict.Blocked = $true
                    $verdict.Reason = "contains credential or key material matching '$sp'"
                    if ($verdict.Samples.Count -lt 5) { $verdict.Samples.Add($e.Name) }
                    return $verdict
                }
            }
            foreach ($dp in $docPatterns) {
                if ($e.Name -like $dp) {
                    $docHits++
                    if ($verdict.Samples.Count -lt 5) { $verdict.Samples.Add($e.Name) }
                    break
                }
            }
        }
    }

    if ($docHits -ge $DocumentThreshold) {
        $verdict.NeedsConfirm = $true
        $verdict.Reason = "contains $docHits document/media file(s) unusual for a cache"
    }
    return $verdict
}

function Test-WinnowPemPrivateKey {
    <#
    .SYNOPSIS
    True when a .pem file holds a private key or cannot be read.
    #>
    param([Parameter(Mandatory)][string]$Path)

    try {
        $fi = New-Object System.IO.FileInfo($Path)
        if ($fi.Length -gt 4MB) { return $true }
        $text = [System.IO.File]::ReadAllText($Path)
        return ($text -match 'PRIVATE KEY')
    } catch {
        return $true
    }
}

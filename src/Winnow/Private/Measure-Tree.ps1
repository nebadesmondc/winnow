# Measurement, backed by the native walker in SpaceWalker.cs.

function New-WinnowWalkOptions {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$Threads = 4,
        [int]$KeepDepth = 0,
        [double]$KeepMinBytes = 1MB
    )

    $o = New-Object Winnow.WalkOptions
    $o.Root = $Root
    $o.Threads = $Threads
    $o.KeepDepth = $KeepDepth
    $o.KeepMinBytes = [long]$KeepMinBytes
    $o.BlockPatterns = [string[]]@($script:WinnowSecretPatterns + $script:WinnowVirtualDiskPatterns)
    $o.DocumentPatterns = [string[]]$script:WinnowDocumentPatterns
    $o.NotablePatterns = [string[]]$script:WinnowVirtualDiskPatterns

    $o.DedupeHardLinks = $false
    try {
        $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($Root))
        $o.DedupeHardLinks = ($drive.DriveFormat -eq 'NTFS')
    } catch { }
    return $o
}

function Measure-WinnowTree {
    <#
    .SYNOPSIS
    Size of a file or folder tree on disk. Hard-linked files count once; links
    are not followed.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $result = [pscustomobject]@{
        Path         = $Path
        Exists       = $false
        Bytes        = [double]0
        Files        = 0
        NewestWrite  = $null
        DeniedCount  = 0
        SkippedLinks = 0
    }

    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return $result }
    $result.Path = $canon

    $walk = [Winnow.SpaceWalker]::Walk((New-WinnowWalkOptions -Root $canon))
    if (-not $walk.Exists -or $walk.Folders.Count -eq 0) { return $result }

    $top = $walk.Folders[0]
    $result.Exists = $true
    $result.Bytes = [double]$top.Bytes
    $result.Files = $top.Files
    if ($top.NewestWriteUtc -gt [datetime]::MinValue) { $result.NewestWrite = $top.NewestWriteUtc }
    $result.DeniedCount = $walk.Denied.Count
    $result.SkippedLinks = $walk.LinksSkipped
    return $result
}

function Get-WinnowChildDirectory {
    <#
    .SYNOPSIS
    Immediate subdirectories, long-path safe, reparse points excluded.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $out = New-Object System.Collections.Generic.List[object]
    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return $out }
    $lp = ConvertTo-WinnowLongPath $canon
    if (-not [System.IO.Directory]::Exists($lp)) { return $out }

    $di = $null
    try { $di = New-Object System.IO.DirectoryInfo($lp) } catch { return $out }
    $subs = $null
    try { $subs = $di.GetDirectories() } catch { return $out }

    foreach ($d in $subs) {
        if (($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $clean = $d.FullName
        if ($clean.StartsWith($script:WinnowLongPathPrefix)) {
            $clean = $clean.Substring($script:WinnowLongPathPrefix.Length)
            if ($clean.StartsWith('UNC\')) { $clean = '\\' + $clean.Substring(4) }
        }
        $out.Add([pscustomobject]@{
            Name          = $d.Name
            Path          = $clean
            LastWriteTime = $d.LastWriteTime
        })
    }
    return $out
}

function Get-WinnowChildFile {
    <#
    .SYNOPSIS
    Immediate files matching a wildcard, long-path safe.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*'
    )

    $out = New-Object System.Collections.Generic.List[object]
    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return $out }
    $lp = ConvertTo-WinnowLongPath $canon
    if (-not [System.IO.Directory]::Exists($lp)) { return $out }

    $di = $null
    try { $di = New-Object System.IO.DirectoryInfo($lp) } catch { return $out }
    $files = $null
    try { $files = $di.GetFiles($Filter) } catch { return $out }

    foreach ($f in $files) {
        if (($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $clean = $f.FullName
        if ($clean.StartsWith($script:WinnowLongPathPrefix)) {
            $clean = $clean.Substring($script:WinnowLongPathPrefix.Length)
            if ($clean.StartsWith('UNC\')) { $clean = '\\' + $clean.Substring(4) }
        }
        $out.Add([pscustomobject]@{
            Name          = $f.Name
            Path          = $clean
            Length        = [double]$f.Length
            LastWriteTime = $f.LastWriteTime
        })
    }
    return $out
}

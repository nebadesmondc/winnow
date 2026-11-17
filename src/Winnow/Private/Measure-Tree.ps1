# Directory measurement. Not Get-ChildItem -Recurse, which follows junctions,
# fails on long paths and stops at the first access-denied.

function Measure-WinnowTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxDepth = 64,
        [switch]$Histogram,
        [int]$TimeoutSec = 0
    )

    $result = [pscustomobject]@{
        Path         = $Path
        Bytes        = [double]0
        Files        = 0
        Dirs         = 0
        NewestWrite  = $null
        OldestWrite  = $null
        DeniedCount  = 0
        SkippedLinks = 0
        TimedOut     = $false
        Extensions   = @{}
        Exists       = $false
    }

    $canon = ConvertTo-WinnowFullPath $Path
    if (-not $canon) { return $result }
    $result.Path = $canon

    $lp = ConvertTo-WinnowLongPath $canon

    if ([System.IO.File]::Exists($lp)) {
        try {
            $fi = New-Object System.IO.FileInfo($lp)
            $result.Exists = $true
            $result.Bytes = [double]$fi.Length
            $result.Files = 1
            $result.NewestWrite = $fi.LastWriteTimeUtc
            $result.OldestWrite = $fi.LastWriteTimeUtc
            if ($Histogram) { $result.Extensions[$fi.Extension.ToLower()] = 1 }
        } catch { }
        return $result
    }

    if (-not [System.IO.Directory]::Exists($lp)) { return $result }
    $result.Exists = $true

    $deadline = $null
    if ($TimeoutSec -gt 0) { $deadline = (Get-Date).AddSeconds($TimeoutSec) }

    $newest = [datetime]::MinValue
    $oldest = [datetime]::MaxValue
    $ext = @{}

    # Stack of (longPath, depth)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($lp, 0))

    while ($stack.Count -gt 0) {
        if ($deadline -and (Get-Date) -gt $deadline) { $result.TimedOut = $true; break }

        $frame = $stack.Pop()
        $dir = $frame[0]
        $depth = [int]$frame[1]

        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo($dir) } catch { $result.DeniedCount++; continue }

        $entries = $null
        try { $entries = $di.GetFileSystemInfos() } catch { $result.DeniedCount++; continue }

        foreach ($e in $entries) {
            try {
                $isLink = (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
                if ($isLink) { $result.SkippedLinks++; continue }

                if (($e.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $result.Dirs++
                    if ($depth -lt $MaxDepth) { $stack.Push(@($e.FullName, $depth + 1)) }
                    continue
                }

                $result.Files++
                $result.Bytes += [double]$e.Length
                $w = $e.LastWriteTimeUtc
                if ($w -gt $newest) { $newest = $w }
                if ($w -lt $oldest) { $oldest = $w }

                if ($Histogram) {
                    $x = $e.Extension
                    if ([string]::IsNullOrEmpty($x)) { $x = '(none)' } else { $x = $x.ToLower() }
                    if ($ext.ContainsKey($x)) { $ext[$x] = $ext[$x] + 1 } else { $ext[$x] = 1 }
                }
            } catch {
                $result.DeniedCount++
            }
        }
    }

    if ($newest -ne [datetime]::MinValue) { $result.NewestWrite = $newest }
    if ($oldest -ne [datetime]::MaxValue) { $result.OldestWrite = $oldest }
    if ($Histogram) { $result.Extensions = $ext }

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

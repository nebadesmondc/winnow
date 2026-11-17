# The only delete primitive. Every path passes Assert-WinnowGuard first;
# tests fail if any other file deletes, moves or runs robocopy.

function Remove-WinnowPath {
    <#
    .SYNOPSIS
    Removes one file or directory tree. Guarded, long-path safe; reports bytes
    measured before and after, and why anything was left.

    .OUTPUTS
    [pscustomobject] Path, Removed (bool), BytesClaimed, BytesLeft, Reason, Method
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowsInsideProject = @(),
        [switch]$SkipGuard   # test fixtures only
    )

    $outcome = [pscustomobject]@{
        Path         = $Path
        Removed      = $false
        BytesClaimed = [double]0
        BytesLeft    = [double]0
        Reason       = $null
        Method       = 'None'
    }

    if ($SkipGuard) {
        $fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'winnow-tests'
        if (-not (Test-WinnowPathUnder -Path (ConvertTo-WinnowFullPath $Path) -Root (ConvertTo-WinnowFullPath $fixtureRoot))) {
            throw 'Winnow: -SkipGuard is only permitted inside the test fixture root.'
        }
    } else {
        $canon = $null
        try {
            $canon = Assert-WinnowGuard -Path $Path -AllowsInsideProject $AllowsInsideProject
        } catch {
            $outcome.Reason = $_.Exception.Message
            return $outcome
        }
        $outcome.Path = $canon
        $Path = $canon
    }

    if (-not (Test-WinnowPathExists -Path $Path)) {
        $outcome.Reason = 'path no longer exists'
        return $outcome
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        $outcome.Reason = 'skipped (WhatIf)'
        return $outcome
    }

    $lp = ConvertTo-WinnowLongPath $Path
    $isDir = [System.IO.Directory]::Exists($lp)
    $before = [double](Measure-WinnowTree -Path $Path).Bytes
    $method = 'None'
    $reason = $null

    if ($isDir) {
        $stuck = Remove-WinnowLinkInTree -Path $Path
        if ($stuck -gt 0) { $reason = "$stuck link(s) inside could not be detached" }
    }

    try {
        if ($isDir) { [System.IO.Directory]::Delete($lp, $true) }
        else { [System.IO.File]::Delete($lp) }
    } catch {
        $reason = $_.Exception.Message
    }
    if (-not (Test-WinnowPathExists -Path $Path)) { $method = 'Delete' }

    # Package caches often mark files read-only.
    if ($method -eq 'None') {
        if ($isDir) {
            try { Clear-WinnowAttribute -Path $Path } catch { }
            try { [System.IO.Directory]::Delete($lp, $true) } catch { $reason = $_.Exception.Message }
        } else {
            try {
                [System.IO.File]::SetAttributes($lp, [System.IO.FileAttributes]::Normal)
                [System.IO.File]::Delete($lp)
            } catch { $reason = $_.Exception.Message }
        }
        if (-not (Test-WinnowPathExists -Path $Path)) { $method = 'Delete+Attrib' }
    }

    if ($method -eq 'None' -and $isDir) {
        $err = Invoke-WinnowMirrorPurge -Path $Path -AllowsInsideProject $AllowsInsideProject
        if ($err) { $reason = $err }
        if (-not (Test-WinnowPathExists -Path $Path)) { $method = 'RobocopyMirror' }
    }

    $left = [double]0
    if ($method -eq 'None') { $left = [double](Measure-WinnowTree -Path $Path).Bytes }

    $outcome.Method = $method
    $outcome.Removed = ($method -ne 'None')
    $outcome.BytesLeft = $left
    $outcome.BytesClaimed = [math]::Max([double]0, $before - $left)
    if ($outcome.Removed) { return $outcome }

    if (-not $reason) { $reason = 'removal did not complete' }
    if ($outcome.BytesClaimed -gt 0) {
        $reason = 'partly removed, {0} left: {1}' -f (Format-WinnowBytes $left).Trim(), $reason
    }
    $locks = @(Get-WinnowPathLock -Path $Path)
    if ($locks.Count -gt 0) {
        $names = ($locks | Select-Object -ExpandProperty Name -Unique) -join ', '
        $reason = $reason + " (in use by: $names)"
    }
    $outcome.Reason = $reason
    return $outcome
}

function Invoke-WinnowMirrorPurge {
    <#
    .SYNOPSIS
    Last resort for trees .NET cannot delete: mirrors an empty directory over
    the tree with robocopy, then removes it. Returns $null or an error message.

    .NOTES
    Checks the guard and detaches links itself so it is safe to call directly.
    robocopy /MIR follows junctions inside the target even with /XJ, so the
    purge is refused if any link remains. The call operator is required:
    Start-Process -ArgumentList does not quote paths containing spaces.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$AllowsInsideProject = @()
    )

    $target = $null
    try {
        $target = Assert-WinnowGuard -Path $Path -AllowsInsideProject $AllowsInsideProject
    } catch {
        return $_.Exception.Message
    }

    $lp = ConvertTo-WinnowLongPath $target
    if (-not [System.IO.Directory]::Exists($lp)) { return $null }

    $stuck = Remove-WinnowLinkInTree -Path $target
    if ($stuck -gt 0) {
        return "last-resort purge refused: $stuck link(s) inside could not be detached"
    }

    $err = $null
    $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('winnow-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [void][System.IO.Directory]::CreateDirectory($empty)
        $null = & robocopy.exe $empty $target /MIR /XJ /NFL /NDL /NJH /NJS /NC /NS /NP /R:1 /W:1 2>&1
        try { [System.IO.Directory]::Delete($lp, $true) } catch { $err = $_.Exception.Message }
    } catch {
        $err = $_.Exception.Message
    } finally {
        try { [System.IO.Directory]::Delete((ConvertTo-WinnowLongPath $empty), $true) } catch { }
    }
    return $err
}

function Remove-WinnowLinkInTree {
    <#
    .SYNOPSIS
    Removes every junction and symbolic link inside a tree (the link, not its
    target). Returns the number that could not be removed.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $failed = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push((ConvertTo-WinnowLongPath $Path))

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $entries = $null
        try { $entries = (New-Object System.IO.DirectoryInfo($dir)).GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            $isLink = (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            $isDir = (($e.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0)
            if ($isLink) {
                # Non-recursive: removes the junction itself.
                try {
                    if ($isDir) { [System.IO.Directory]::Delete($e.FullName, $false) }
                    else { [System.IO.File]::Delete($e.FullName) }
                } catch { $failed++ }
                continue
            }
            if ($isDir) { $stack.Push($e.FullName) }
        }
    }
    return $failed
}

function Clear-WinnowAttribute {
    <#
    .SYNOPSIS
    Clears ReadOnly, Hidden and System attributes in a tree. Does not follow links.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $lp = ConvertTo-WinnowLongPath $Path
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($lp)
    $mask = -bnot ([int][System.IO.FileAttributes]::ReadOnly -bor
                   [int][System.IO.FileAttributes]::Hidden -bor
                   [int][System.IO.FileAttributes]::System)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $di = $null
        try { $di = New-Object System.IO.DirectoryInfo($dir) } catch { continue }
        try { $di.Attributes = [System.IO.FileAttributes]([int]$di.Attributes -band $mask) } catch { }

        $entries = $null
        try { $entries = $di.GetFileSystemInfos() } catch { continue }
        foreach ($e in $entries) {
            if (($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            if (($e.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                $stack.Push($e.FullName)
            } else {
                try { $e.Attributes = [System.IO.FileAttributes]([int]$e.Attributes -band $mask) } catch { }
            }
        }
    }
}

# Every change Winnow makes happens in this file: deleting, copying, creating
# a move's destination, setting a user environment variable and moving a WSL
# disk. Tests fail if any other file does any of these.

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
        [switch]$Recycle,
        # A move's destination, from its record: removed after an undo or a failed move.
        [string]$MoveTarget,
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
            $canon = Assert-WinnowGuard -Path $Path -AllowsInsideProject $AllowsInsideProject -MoveTarget $MoveTarget
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

    if ($Recycle) {
        $reason = Move-WinnowToRecycleBin -Path $Path -IsDirectory:$isDir
        if (-not (Test-WinnowPathExists -Path $Path)) {
            $outcome.Method = 'RecycleBin'
            $outcome.Removed = $true
            # Still on the drive until the Recycle Bin is emptied.
            $outcome.BytesLeft = $before
            return $outcome
        }
        if (-not $reason) { $reason = 'the Recycle Bin did not take it' }
        $outcome.Reason = $reason
        $outcome.BytesLeft = $before
        return $outcome
    }

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
        $err = Invoke-WinnowMirrorPurge -Path $Path -AllowsInsideProject $AllowsInsideProject -MoveTarget $MoveTarget
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
        [string[]]$AllowsInsideProject = @(),
        [string]$MoveTarget
    )

    $target = $null
    try {
        $target = Assert-WinnowGuard -Path $Path -AllowsInsideProject $AllowsInsideProject -MoveTarget $MoveTarget
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

function Move-WinnowToRecycleBin {
    <#
    .SYNOPSIS
    Sends a guarded path to the Recycle Bin. Returns $null or an error message.

    .NOTES
    AllDialogs, not OnlyErrorDialogs: with the quiet option Windows silently
    deletes for good anything too large for the Recycle Bin. With AllDialogs
    it asks first.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$IsDirectory
    )

    try {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::AllDialogs
        $bin = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        $cancel = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
        if ($IsDirectory) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $ui, $bin, $cancel) }
        else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($Path, $ui, $bin, $cancel) }
        return $null
    } catch [System.OperationCanceledException] {
        return 'cancelled; nothing was moved'
    } catch {
        return $_.Exception.Message
    }
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

function New-WinnowPrivateFolder {
    <#
    .SYNOPSIS
    Creates the empty folder a move goes to, open only to the current user,
    SYSTEM and Administrators. Returns its canonical path.

    .NOTES
    Permissions are set on this folder alone and everything copied in later
    inherits them. Stripping permissions file by file (icacls /inheritance:r
    /T) once left a moved WSL disk with an empty list that WSL could not open.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Source
    )

    $check = Test-WinnowMoveDestination -Path $Path -Source $Source
    if (-not $check.Allowed) { throw "Winnow will not move anything to '$Path': $($check.Reason)" }
    $canon = $check.Path
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-WinnowLongPath $canon))

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(
            [System.Security.Principal.WindowsIdentity]::GetCurrent().User,
            (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')),      # SYSTEM
            (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')))) { # Administrators
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid, 'FullControl', $inherit, 'None', 'Allow')))
    }
    $di = New-Object System.IO.DirectoryInfo($canon)
    # An instance method on .NET Framework, an extension method on .NET.
    if ($di.PSObject.Methods['SetAccessControl']) { $di.SetAccessControl($acl) }
    else { [System.IO.FileSystemAclExtensions]::SetAccessControl($di, $acl) }
    return $canon
}

function Copy-WinnowTree {
    <#
    .SYNOPSIS
    Copies a folder's contents into another folder and removes nothing.
    Returns $null, or why the copy is incomplete.

    .NOTES
    Data, attributes and timestamps are copied, not permissions, so the copy
    takes its new folder's. Junctions are not followed.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $null = & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /MT:8 /NFL /NDL /NJH /NJS /NC /NS /NP 2>&1
    $code = $LASTEXITCODE
    # Exit codes 8 and above mean some files were not copied.
    if ($code -ge 8) { return "robocopy could not copy everything (exit code $code)" }
    $from = Measure-WinnowTree -Path $Source
    $to = Measure-WinnowTree -Path $Destination
    if ($to.Files -lt $from.Files) {
        return ('the copy holds {0:N0} files, the original {1:N0}' -f $to.Files, $from.Files)
    }
    return $null
}

function Remove-WinnowEmptyFolder {
    # Removes a folder only when it is empty; anything inside keeps it.
    param([Parameter(Mandatory)][string]$Path)
    try { [System.IO.Directory]::Delete((ConvertTo-WinnowLongPath $Path), $false) } catch { }
}

# The tests write process variables instead, so a test run never changes the
# user's environment.
$script:WinnowVariableTarget = 'User'

function Get-WinnowUserVariable {
    param([Parameter(Mandatory)][string]$Name)
    return [System.Environment]::GetEnvironmentVariable($Name, $script:WinnowVariableTarget)
}

function Set-WinnowUserVariable {
    <#
    .SYNOPSIS
    Sets, or with $null removes, a user environment variable and this
    session's copy. Only a variable some rule's Move names.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyString()]$Value,
        # This session's value, when it differs (an undo restores both as they were).
        [AllowNull()][AllowEmptyString()]$ProcessValue
    )

    $allowed = @(Import-WinnowRule | Where-Object { $_.Move } | ForEach-Object { $_.Move.Env })
    if ($allowed -notcontains $Name) { throw "Winnow: '$Name' is not a variable any rule moves." }
    if (-not $PSBoundParameters.ContainsKey('ProcessValue')) { $ProcessValue = $Value }
    foreach ($pair in @(@($script:WinnowVariableTarget, $Value), @('Process', $ProcessValue))) {
        # PowerShell passes $null to a .NET string as ''; .NET Framework then
        # deletes the variable, but .NET 5+ stores it empty. NullString is a real null.
        if ([string]::IsNullOrEmpty([string]$pair[1])) {
            [System.Environment]::SetEnvironmentVariable($Name, [System.Management.Automation.Language.NullString]::Value, $pair[0])
        } else {
            [System.Environment]::SetEnvironmentVariable($Name, [string]$pair[1], $pair[0])
        }
    }
}

function Assert-WinnowWslName {
    # wsl -d and --terminate keep quotes as part of the name, so names are
    # passed bare and must be ones WSL itself allows.
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw "Winnow: '$Name' is not a WSL distribution name Winnow can pass to wsl." }
}

function Stop-WinnowWslDistro {
    # Stops one distribution, as wsl --terminate does; its processes end.
    param([Parameter(Mandatory)][string]$Name)
    Assert-WinnowWslName -Name $Name
    $null = Invoke-WinnowProcess -Command 'wsl' -Arguments ('--terminate {0}' -f $Name) -TimeoutSec 60
}

function Move-WinnowWslDisk {
    <#
    .SYNOPSIS
    Has WSL move a stopped distribution's disk into a folder. Returns $null,
    or WSL's message when it failed.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Destination
    )

    Assert-WinnowWslName -Name $Name
    $r = Invoke-WinnowProcess -Command 'wsl' -Arguments ('--manage {0} --move "{1}"' -f $Name, $Destination) -TimeoutSec 7200
    if ($r.ExitCode -eq 0) { return $null }
    if ($r.TimedOut) { return 'WSL did not finish within two hours' }
    $msg = (@($r.Output, $r.Error) | Where-Object { $_ }) -join ' '
    if (-not $msg) { $msg = "wsl exited with code $($r.ExitCode)" }
    return $msg
}

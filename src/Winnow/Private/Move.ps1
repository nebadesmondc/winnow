# Moving what must stay off the system drive: tool caches (by pointing the
# tool's environment variable at a new folder), WSL distributions (through
# WSL itself) and Docker Desktop's disk (steps only). Every change goes
# through Change.ps1; every move writes a record that undo reverses.

$script:WinnowDiskInfo = $null

function Get-WinnowDiskInfo {
    <#
    .SYNOPSIS
    Physical disk number and media type for each drive letter, cached per
    session. Empty when Windows does not say.
    #>
    if ($null -ne $script:WinnowDiskInfo) { return $script:WinnowDiskInfo }
    $info = @{}
    try {
        $media = @{}
        foreach ($d in @(Get-CimInstance -Namespace root/Microsoft/Windows/Storage -ClassName MSFT_PhysicalDisk -ErrorAction Stop)) {
            $kind = 'unknown'
            switch ([int]$d.MediaType) { 3 { $kind = 'HDD' } 4 { $kind = 'SSD' } 5 { $kind = 'SSD' } }
            $media[[string]$d.DeviceId] = $kind
        }
        foreach ($a in @(Get-CimInstance -ClassName Win32_LogicalDiskToPartition -ErrorAction Stop)) {
            if ($a.Antecedent.DeviceID -notmatch 'Disk #(\d+)') { continue }
            $disk = $Matches[1]
            $letter = $a.Dependent.DeviceID.Substring(0, 1).ToUpper()
            $kind = 'unknown'
            if ($media.ContainsKey($disk)) { $kind = $media[$disk] }
            $info[$letter] = [pscustomobject]@{ Disk = $disk; Media = $kind }
        }
    } catch { }
    $script:WinnowDiskInfo = $info
    return $info
}

function Get-WinnowDriveNote {
    <#
    .SYNOPSIS
    How a drive relates to the system drive: "same SSD as C:", "hard disk".
    #>
    param([Parameter(Mandatory)][string]$Letter)

    $sys = (Get-WinnowSystemDriveRoot).Substring(0, 1).ToUpper()
    $Letter = $Letter.ToUpper()
    if ($Letter -eq $sys) { return $null }
    $info = Get-WinnowDiskInfo
    if (-not $info.ContainsKey($Letter)) { return $null }
    $d = $info[$Letter]
    if ($info.ContainsKey($sys) -and $info[$sys].Disk -eq $d.Disk) {
        if ($d.Media -eq 'SSD') { return "same SSD as ${sys}:, moving costs no speed" }
        return "same disk as ${sys}:"
    }
    if ($d.Media -eq 'HDD') { return 'hard disk, slower than an SSD' }
    if ($d.Media -eq 'SSD') { return 'SSD' }
    return $null
}

function Get-WinnowMoveDrive {
    <#
    .SYNOPSIS
    Fixed drives other than the source's that have room for $Bytes, best
    first: SSDs before hard disks, then the most free space.
    #>
    param(
        [Parameter(Mandatory)][double]$Bytes,
        [Parameter(Mandatory)][string]$Source
    )

    $srcLetter = $Source.Substring(0, 1).ToUpper()
    $info = Get-WinnowDiskInfo
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($v in (Get-WinnowVolumeInfo)) {
        if ($v.Letter -eq $srcLetter) { continue }
        if ($v.FreeBytes -lt (Get-WinnowMoveRoom -Bytes $Bytes)) { continue }
        $rank = 1
        if ($info.ContainsKey($v.Letter) -and $info[$v.Letter].Media -eq 'HDD') { $rank = 2 }
        $out.Add([pscustomobject]@{ Letter = $v.Letter; FreeBytes = $v.FreeBytes; Rank = $rank; Note = (Get-WinnowDriveNote -Letter $v.Letter) })
    }
    return @($out | Sort-Object Rank, @{ Expression = 'FreeBytes'; Descending = $true })
}

function Get-WinnowMoveRoom {
    # Free space a move needs on the receiving drive.
    param([double]$Bytes)
    return ($Bytes * 1.1 + 1GB)
}

function Get-WinnowMovable {
    <#
    .SYNOPSIS
    Everything on the system drive that can move: the home of each tool a
    rule's Move names, and the virtual disks found as Move items.
    #>
    param(
        [object[]]$Rules = @(),
        [hashtable]$Resolved = @{},
        [object[]]$Findings = @(),
        [object]$Walk,
        [Parameter(Mandatory)][string]$DriveRoot
    )

    $out = New-Object System.Collections.Generic.List[object]

    foreach ($rule in $Rules) {
        if (-not $rule.Move -or -not $Resolved.ContainsKey($rule.Id)) { continue }
        $primary = @($Resolved[$rule.Id] | Where-Object { $_.PSObject.Properties['Primary'] -and $_.Primary })[0]
        if (-not $primary) { continue }
        $mv = $rule.Move
        $home_ = ConvertTo-WinnowFullPath $primary.Path
        $up = 0
        if ($mv.ContainsKey('Up')) { $up = [int]$mv.Up }
        for ($i = 0; $i -lt $up -and $home_; $i++) { $home_ = [System.IO.Path]::GetDirectoryName($home_) }
        if (-not $home_ -or -not (Test-WinnowPathUnder -Path $home_ -Root $DriveRoot)) { continue }

        $entry = $null
        if ($Walk) { $entry = $Walk.Find($home_) }
        if (-not $entry) { continue }
        $min = 100MB
        if ($mv.ContainsKey('MinBytes')) { $min = $mv.MinBytes }
        if ($entry.Bytes -lt $min) { continue }

        $blocker = $null
        if ($mv.ContainsKey('PathFolder') -and $mv.PathFolder) {
            $bin = Join-Path $home_ $mv.PathFolder
            if (@(Get-WinnowChildFile -Path $bin).Count -gt 0) {
                $blocker = "programs in its $($mv.PathFolder) folder run from PATH, and Winnow does not change PATH"
            }
        }

        $out.Add([pscustomobject]@{
            Id             = $mv.Id
            Title          = $mv.Title
            Kind           = 'Variable'
            Path           = $home_
            Bytes          = [double]$entry.Bytes
            RuleId         = $rule.Id
            Env            = $mv.Env
            Verify         = $mv.Verify
            RequiresClosed = @($mv.RequiresClosed | Where-Object { $_ })
            Note           = $mv.Note
            Blocker        = $blocker
            Folder         = "DevCache\$($mv.Id)"
            Distro         = $null
            Steps          = @()
        })
    }

    $distros = $null
    foreach ($f in $Findings) {
        if ($f.Verdict -ne 'Move' -or -not (Test-WinnowPathUnder -Path $f.Path -Root $DriveRoot)) { continue }
        $kind = $null; $distro = $null; $folder = $null
        if ($f.RuleId -eq 'vdisk.wsl') {
            if ($null -eq $distros) { $distros = @(Get-WinnowWslDistro) }
            $d = @($distros | Where-Object { $_.Disk -eq $f.Path })[0]
            if (-not $d) { continue }
            $kind = 'Wsl'; $distro = $d.Name; $folder = "WSL\$($d.Name)"
        } elseif ($f.RuleId -eq 'vdisk.docker') {
            $kind = 'Guided'; $folder = 'DockerDesktop'
        } else { continue }

        $out.Add([pscustomobject]@{
            Id             = $f.Id
            Title          = $f.Title
            Kind           = $kind
            Path           = $f.Path
            Bytes          = [double]$f.Bytes
            RuleId         = $f.RuleId
            Env            = $null
            Verify         = $null
            RequiresClosed = @()
            Note           = $null
            Blocker        = $null
            Folder         = $folder
            Distro         = $distro
            Steps          = @($f.Steps)
        })
    }
    return @($out | Sort-Object Bytes -Descending)
}

function Get-WinnowMovePlan {
    <#
    .SYNOPSIS
    Where a movable item would go and whether it can go now. Changes nothing.

    .OUTPUTS
    [pscustomobject] Movable, Destination, Problem, DriveNote
    #>
    param(
        [Parameter(Mandatory)][object]$Movable,
        [string]$To
    )

    $m = $Movable
    $plan = [pscustomobject]@{ Movable = $m; Destination = $null; Problem = $null; DriveNote = $null }
    $fail = { param($why) $plan.Problem = $why; return $plan }

    if ($m.Blocker) { return (& $fail $m.Blocker) }

    if ($To) {
        $plan.Destination = ConvertTo-WinnowFullPath $To
    } else {
        $drive = @(Get-WinnowMoveDrive -Bytes $m.Bytes -Source $m.Path)[0]
        if (-not $drive) { return (& $fail ('no other fixed drive has {0} free' -f (Format-WinnowSize (Get-WinnowMoveRoom -Bytes $m.Bytes)))) }
        $plan.Destination = "$($drive.Letter):\$($m.Folder)"
    }
    if (-not $plan.Destination) { return (& $fail "'$To' is not a valid path") }
    $plan.DriveNote = Get-WinnowDriveNote -Letter $plan.Destination.Substring(0, 1)

    if ($m.Kind -eq 'Guided') { return $plan }

    $dest = Test-WinnowMoveDestination -Path $plan.Destination -Source $m.Path
    if (-not $dest.Allowed) { return (& $fail "$($plan.Destination) cannot take it: $($dest.Reason)") }
    $vol = @(Get-WinnowVolumeInfo -DriveLetter $plan.Destination.Substring(0, 1))[0]
    if (-not $vol -or $vol.FreeBytes -lt (Get-WinnowMoveRoom -Bytes $m.Bytes)) {
        return (& $fail ('{0}: needs {1} free' -f $plan.Destination.Substring(0, 1), (Format-WinnowSize (Get-WinnowMoveRoom -Bytes $m.Bytes))))
    }

    if ($m.Kind -eq 'Wsl') {
        if (-not (Test-WinnowWslMoveSupported)) { return (& $fail 'this WSL cannot move distributions; wsl --update brings a version that can') }
        return $plan
    }

    # The old folder is deleted once the copy is in use, so it must pass the guard.
    $g = Test-WinnowGuard -Path $m.Path
    if (-not $g.Allowed) { return (& $fail "the guard refuses its folder: $($g.Reason)") }
    Reset-WinnowProcessMap
    $hold = Get-WinnowHoldReason -Path $m.Path -RequiresClosed @($m.RequiresClosed) -InFlight @(Get-WinnowUpdateInFlight)
    if ($hold) { return (& $fail $hold) }
    $size = Measure-WinnowTree -Path $m.Path
    if ($size.SkippedLinks -gt 0) { return (& $fail "it holds $($size.SkippedLinks) link(s), which a copy would not keep") }
    if ($size.DeniedCount -gt 0) { return (& $fail "$($size.DeniedCount) folder(s) inside cannot be read") }
    return $plan
}

function Test-WinnowMoveVerified {
    <#
    .SYNOPSIS
    Asks the tool where its cache is now. Ok is false only when the tool
    answers with another folder.
    #>
    param(
        [Parameter(Mandatory)][object]$Movable,
        [Parameter(Mandatory)][string]$Expect
    )

    $v = $Movable.Verify
    if (-not $v) {
        return [pscustomobject]@{ Ok = $true; Detail = "$($Movable.Env) points to $Expect" }
    }
    $ask = "$($v.Command) $($v.Args)"
    if (-not (Get-Command -Name $v.Command -CommandType Application -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $true; Detail = "$($Movable.Env) points to $Expect; $($v.Command) is not installed to ask" }
    }
    $answer = Get-WinnowPathFromOutput -Text (Invoke-WinnowCli -Command $v.Command -Arguments $v.Args -TimeoutSec 30)
    $got = $null
    if ($answer) { $got = ConvertTo-WinnowFullPath $answer }
    if ($got -and $got.Equals((ConvertTo-WinnowFullPath $Expect), [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Ok = $true; Detail = "``$ask`` reports $Expect" }
    }
    if (-not $answer) { $answer = 'nothing' }
    return [pscustomobject]@{ Ok = $false; Detail = "``$ask`` reports $answer, not $Expect" }
}

# --------------------------------------------------------------------------
# Move records

function Get-WinnowMoveFolder {
    $base = Get-WinnowEnvRoot -Base 'LOCALAPPDATA'
    if (-not $base) { return $null }
    return (Join-Path (Join-Path $base 'Winnow') 'moves')
}

function Save-WinnowMoveRecord {
    param([Parameter(Mandatory)][object]$Record)
    $dir = Get-WinnowMoveFolder
    if (-not $dir) { throw 'Winnow: LOCALAPPDATA is not set; a move needs somewhere to write its record.' }
    [void][System.IO.Directory]::CreateDirectory((ConvertTo-WinnowLongPath $dir))
    $Record | ConvertTo-Json -Depth 5 | Out-File -LiteralPath (Join-Path $dir ($Record.MoveId + '.json')) -Encoding utf8
}

function Get-WinnowMoveRecord {
    <#
    .SYNOPSIS
    Move records, newest first. -Id matches an item id (npm) or a move id.
    #>
    param([string]$Id, [string]$State)

    $dir = Get-WinnowMoveFolder
    $out = New-Object System.Collections.Generic.List[object]
    if (-not $dir -or -not (Test-WinnowPathExists -Path $dir)) { return $out }
    foreach ($f in (Get-WinnowChildFile -Path $dir -Filter '*.json')) {
        $r = $null
        try {
            # Assigned first: Windows PowerShell 5.1 passes a JSON array as one object.
            $r = Get-Content -LiteralPath $f.Path -Raw -Encoding utf8 | ConvertFrom-Json
        } catch { continue }
        if (-not $r -or $r.Schema -ne 'winnow/move/1') { continue }
        if ($Id -and $r.Id -ne $Id -and $r.MoveId -ne $Id) { continue }
        if ($State -and $r.State -ne $State) { continue }
        $out.Add($r)
    }
    return @($out | Sort-Object MoveId -Descending)
}

function New-WinnowMoveRecord {
    param(
        [Parameter(Mandatory)][object]$Movable,
        [Parameter(Mandatory)][string]$Destination
    )
    $m = $Movable
    $variable = $null
    if ($m.Kind -eq 'Variable') {
        $variable = [pscustomobject]@{
            Name       = $m.Env
            OldUser    = Get-WinnowUserVariable -Name $m.Env
            OldProcess = [System.Environment]::GetEnvironmentVariable($m.Env)
        }
    }
    return [pscustomobject]@{
        Schema         = 'winnow/move/1'
        MoveId         = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + $m.Id
        Id             = $m.Id
        Kind           = $m.Kind
        Title          = $m.Title
        From           = $m.Path
        To             = $Destination
        Bytes          = $m.Bytes
        Variable       = $variable
        Verify         = $m.Verify
        Distro         = $m.Distro
        RequiresClosed = @($m.RequiresClosed)
        State          = 'started'
        CreatedParent  = $null
        Reason         = $null
        Checked        = $null
        FreedBytes     = $null
        LeftBehind     = $null
        WhenUtc        = (Get-Date).ToUniversalTime().ToString('o')
        UndoneUtc      = $null
    }
}

function Get-WinnowUndoProblem {
    # Why a move cannot be undone now, or $null.
    param([Parameter(Mandatory)][object]$Record)

    $rec = $Record
    if ($rec.Kind -eq 'Wsl') {
        $d = @(Get-WinnowWslDistro | Where-Object { $_.Name -eq $rec.Distro })[0]
        if (-not $d) { return "$($rec.Distro) is no longer registered" }
        if (-not (Test-WinnowPathUnder -Path $d.Disk -Root $rec.To)) { return "$($rec.Distro) is no longer in $($rec.To)" }
    } else {
        if (-not (Test-WinnowPathExists -Path $rec.To)) { return "$($rec.To) no longer exists" }
        $now = Get-WinnowUserVariable -Name $rec.Variable.Name
        if (-not $now -or -not (ConvertTo-WinnowFullPath $now).Equals($rec.To, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "$($rec.Variable.Name) no longer points to $($rec.To)"
        }
        Reset-WinnowProcessMap
        $hold = Get-WinnowHoldReason -Path $rec.To -RequiresClosed @($rec.RequiresClosed | Where-Object { $_ })
        if ($hold) { return $hold }
    }
    if ((Get-WinnowFreeSpace -Path $rec.From) -lt (Get-WinnowMoveRoom -Bytes $rec.Bytes)) {
        return ('{0}: needs {1} free' -f $rec.From.Substring(0, 1), (Format-WinnowSize (Get-WinnowMoveRoom -Bytes $rec.Bytes)))
    }
    return $null
}

function New-WinnowMoveFolder {
    <#
    .SYNOPSIS
    Creates a move's destination and notes a parent folder created for it.
    Returns the canonical path, or $null with the record marked failed.
    #>
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Source)

    $parent = [System.IO.Path]::GetDirectoryName((ConvertTo-WinnowFullPath $Path))
    if ($parent -and -not (Test-WinnowPathExists -Path $parent)) { $Record.CreatedParent = $parent }
    try {
        $dest = New-WinnowPrivateFolder -Path $Path -Source $Source
        $Record.To = $dest
        return $dest
    } catch {
        $Record.State = 'failed'; $Record.Reason = $_.Exception.Message
        Save-WinnowMoveRecord -Record $Record
        return $null
    }
}

function Remove-WinnowMoveFolder {
    # Removes a move's destination and the parent created for it, if empty.
    param([Parameter(Mandatory)][object]$Record)
    $rm = Remove-WinnowPath -Path $Record.To -MoveTarget $Record.To -Confirm:$false
    if ($Record.CreatedParent) { Remove-WinnowEmptyFolder -Path $Record.CreatedParent }
    return $rm
}

function Get-WinnowFreeSpace {
    param([Parameter(Mandatory)][string]$Path)
    $v = @(Get-WinnowVolumeInfo -DriveLetter $Path.Substring(0, 1))[0]
    if ($v) { return $v.FreeBytes }
    return [double]0
}

# --------------------------------------------------------------------------
# Tool caches

function Move-WinnowVariableHome {
    <#
    .SYNOPSIS
    Copies a tool's folder to its new place, points the tool there, checks
    the tool finds it, then deletes the old folder. Any failure before the
    delete puts everything back.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $m = $Plan.Movable
    $rec = New-WinnowMoveRecord -Movable $m -Destination $Plan.Destination
    Save-WinnowMoveRecord -Record $rec
    $freeBefore = Get-WinnowFreeSpace -Path $m.Path

    $dest = New-WinnowMoveFolder -Record $rec -Path $Plan.Destination -Source $m.Path
    if (-not $dest) { return $rec }

    $err = Copy-WinnowTree -Source $m.Path -Destination $dest
    if (-not $err) {
        Set-WinnowUserVariable -Name $m.Env -Value $dest
        $check = Test-WinnowMoveVerified -Movable $m -Expect $dest
        $rec.Checked = $check.Detail
        if (-not $check.Ok) {
            $err = $check.Detail
            Set-WinnowUserVariable -Name $m.Env -Value $rec.Variable.OldUser -ProcessValue $rec.Variable.OldProcess
        }
    }
    if ($err) {
        $null = Remove-WinnowMoveFolder -Record $rec
        $rec.State = 'failed'; $rec.Reason = $err
        Save-WinnowMoveRecord -Record $rec
        return $rec
    }

    $rm = Remove-WinnowPath -Path $m.Path -Confirm:$false
    if (-not $rm.Removed) { $rec.LeftBehind = "$($m.Path): $($rm.Reason)" }
    $rec.State = 'done'
    $rec.FreedBytes = (Get-WinnowFreeSpace -Path $m.Path) - $freeBefore
    Save-WinnowMoveRecord -Record $rec
    Reset-WinnowDiscoveryCache
    return $rec
}

function Undo-WinnowVariableHome {
    <#
    .SYNOPSIS
    Copies a moved folder back, restores the variable as it was, checks the
    tool, then deletes the moved copy.
    #>
    param([Parameter(Mandatory)][object]$Record)

    $rec = $Record
    $existed = Test-WinnowPathExists -Path $rec.From
    $err = Copy-WinnowTree -Source $rec.To -Destination $rec.From
    if ($err) {
        if (-not $existed) { $null = Remove-WinnowPath -Path $rec.From -Confirm:$false }
        return "nothing was changed: $err"
    }

    Set-WinnowUserVariable -Name $rec.Variable.Name -Value $rec.Variable.OldUser -ProcessValue $rec.Variable.OldProcess
    $rec.Checked = $null
    if ($rec.Verify) {
        $m = [pscustomobject]@{ Env = $rec.Variable.Name; Verify = $rec.Verify }
        $check = Test-WinnowMoveVerified -Movable $m -Expect $rec.From
        $rec.Checked = $check.Detail
        if (-not $check.Ok) {
            # The tool looks elsewhere; keep both copies rather than guess.
            $rec.State = 'undone'; $rec.LeftBehind = "$($rec.To) was kept: $($check.Detail)"
            $rec.UndoneUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-WinnowMoveRecord -Record $rec
            return $null
        }
    }

    $rm = Remove-WinnowMoveFolder -Record $rec
    $rec.LeftBehind = $null
    if (-not $rm.Removed) { $rec.LeftBehind = "$($rec.To): $($rm.Reason)" }
    $rec.State = 'undone'
    $rec.UndoneUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-WinnowMoveRecord -Record $rec
    Reset-WinnowDiscoveryCache
    return $null
}

# --------------------------------------------------------------------------
# WSL distributions

function Test-WinnowWslMoveSupported {
    $r = Invoke-WinnowProcess -Command 'wsl' -Arguments '--help' -TimeoutSec 20
    return (($r.Output + ' ' + $r.Error) -match '--move')
}

function Get-WinnowWslRunning {
    # Names of the running distributions.
    $r = Invoke-WinnowProcess -Command 'wsl' -Arguments '--list --running --quiet' -TimeoutSec 20
    if ($r.ExitCode -ne 0) { return @() }
    return @(($r.Output -split "`r?`n") | ForEach-Object { $_.Trim([char]0, ' ', "`t") } | Where-Object { $_ })
}

function Get-WinnowWslHolder {
    <#
    .SYNOPSIS
    What keeps a distribution running: editor windows connected to it,
    Docker Desktop's WSL integration, terminals running it.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$IsDefault,
        [object[]]$Process,
        [string]$DockerSettings
    )

    if (-not $PSBoundParameters.ContainsKey('Process')) {
        $Process = @()
        try { $Process = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | Select-Object Name, ProcessId, ParentProcessId, CommandLine) } catch { }
    }
    if (-not $PSBoundParameters.ContainsKey('DockerSettings')) {
        $DockerSettings = $null
        $appData = Get-WinnowEnvRoot -Base 'APPDATA'
        if ($appData) { $DockerSettings = Join-Path $appData 'Docker\settings-store.json' }
    }

    $holders = New-Object System.Collections.Generic.List[string]
    $n = [regex]::Escape($Name)
    $editors = @{ 'Code.exe' = 'VS Code'; 'Code - Insiders.exe' = 'VS Code Insiders'; 'Cursor.exe' = 'Cursor'; 'Windsurf.exe' = 'Windsurf' }
    $byId = @{}
    foreach ($p in $Process) { $byId[[string]$p.ProcessId] = $p }
    foreach ($p in $Process) {
        $cmd = [string]$p.CommandLine
        if (-not $cmd) { continue }
        # VS Code writes the remote as wsl+name, or URL-encoded as wsl%2Bname.
        $connected = ($cmd -match "(?i)wsl(\+|%2B)$n\b" -or $cmd -match "(?i)\\\\wsl(\.localhost|\$)\\$n\\")
        if ($connected -and $editors.ContainsKey($p.Name)) {
            $holders.Add("$($editors[$p.Name]) has a window open on $Name"); continue
        }
        if ($p.Name -eq 'wsl.exe') {
            $named = ($cmd -match "(?i)(-d|--distribution)\s+`"?$n`"?(\s|$)")
            $other = ($cmd -match '(?i)(-d|--distribution)\s')
            if (-not ($named -or ($IsDefault -and -not $other -and $cmd -notmatch '(?i)--(list|status|help|version|shutdown|terminate)'))) { continue }
            $parent = $null
            if ($p.PSObject.Properties['ParentProcessId']) { $parent = $byId[[string]$p.ParentProcessId] }
            if ($parent -and $editors.ContainsKey($parent.Name)) { $holders.Add("$($editors[$parent.Name]) has a window open on $Name") }
            else { $holders.Add("a terminal runs wsl (pid $($p.ProcessId))") }
        }
    }

    $dockerRunning = @($Process | Where-Object { $_.Name -eq 'Docker Desktop.exe' }).Count -gt 0
    if ($dockerRunning -and $DockerSettings -and (Test-WinnowPathExists -Path $DockerSettings)) {
        try {
            $s = Get-Content -LiteralPath $DockerSettings -Raw | ConvertFrom-Json
            $integrated = @($s.IntegratedWslDistros) -contains $Name
            $viaDefault = ($IsDefault -and $s.PSObject.Properties['EnableIntegrationWithDefaultWslDistro'] -and $s.EnableIntegrationWithDefaultWslDistro)
            if ($integrated -or $viaDefault) { $holders.Add("Docker Desktop's WSL integration uses $Name") }
        } catch { }
    }
    return @($holders | Select-Object -Unique)
}

function Stop-WinnowWslForMove {
    <#
    .SYNOPSIS
    Stops a distribution and waits until WSL lets go of its disk. Returns
    $null, or what keeps it running or its disk open.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Disk,
        [switch]$IsDefault
    )

    if (@(Get-WinnowWslRunning) -contains $Name) {
        Stop-WinnowWslDistro -Name $Name
        for ($i = 0; $i -lt 6; $i++) {
            [System.Threading.Thread]::Sleep(1000)
            if (@(Get-WinnowWslRunning) -contains $Name) {
                $holders = @(Get-WinnowWslHolder -Name $Name -IsDefault:$IsDefault)
                if ($holders.Count -eq 0) { return "$Name starts again as soon as it stops; close what uses it and try again" }
                return "$Name starts again as soon as it stops: $($holders -join '; '). Close them and try again"
            }
        }
    }

    # WSL keeps a stopped distribution's disk attached while its VM runs, for
    # other distributions or until the VM idles out.
    for ($i = 0; $i -lt 90; $i++) {
        if ($i -eq 15 -and @(Get-WinnowWslRunning | Where-Object { $_ -ne $Name }).Count -gt 0) { break }
        if (Test-WinnowFileFree -Path $Disk) { return $null }
        [System.Threading.Thread]::Sleep(1000)
    }
    $others = @(Get-WinnowWslRunning | Where-Object { $_ -ne $Name })
    if ($others.Count -gt 0) {
        return "WSL keeps the disk of $Name open while $($others -join ', ') runs. When nothing needs it, run wsl --shutdown and try again"
    }
    return "WSL still has the disk of $Name open; try again in a minute"
}

function Test-WinnowFileFree {
    # True when no other process has the file open.
    param([Parameter(Mandatory)][string]$Path)
    $fs = $null
    try {
        $fs = [System.IO.File]::Open((ConvertTo-WinnowLongPath $Path), [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return $true
    } catch {
        return $false
    } finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Test-WinnowWslBoots {
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-WinnowProcess -Command 'wsl' -Arguments ('-d "{0}" --exec /bin/sh -c "exit 0"' -f $Name) -TimeoutSec 120
    return ($r.ExitCode -eq 0)
}

function Move-WinnowWslHome {
    <#
    .SYNOPSIS
    Stops a distribution, has WSL move its disk, and checks it starts from
    the new folder.
    #>
    param([Parameter(Mandatory)][object]$Plan)

    $m = $Plan.Movable
    $distro = @(Get-WinnowWslDistro | Where-Object { $_.Name -eq $m.Distro })[0]
    $rec = New-WinnowMoveRecord -Movable $m -Destination $Plan.Destination
    if (-not $distro) {
        $rec.State = 'failed'; $rec.Reason = "$($m.Distro) is no longer registered"
        return $rec
    }
    $rec.From = [System.IO.Path]::GetDirectoryName($distro.Disk)

    $why = Stop-WinnowWslForMove -Name $m.Distro -Disk $distro.Disk -IsDefault:$distro.Default
    if ($why) { $rec.State = 'failed'; $rec.Reason = $why; return $rec }

    Save-WinnowMoveRecord -Record $rec
    $freeBefore = Get-WinnowFreeSpace -Path $rec.From
    $dest = New-WinnowMoveFolder -Record $rec -Path $Plan.Destination -Source $rec.From
    if (-not $dest) { return $rec }

    $err = Move-WinnowWslDisk -Name $m.Distro -Destination $dest
    $now = @(Get-WinnowWslDistro | Where-Object { $_.Name -eq $m.Distro })[0]
    $moved = ($now -and (Test-WinnowPathUnder -Path $now.Disk -Root $dest) -and (Test-WinnowPathExists -Path $now.Disk))
    if (-not $moved) {
        if (-not $err) { $err = 'WSL reported success, but the distribution still points to its old folder' }
        $null = Remove-WinnowMoveFolder -Record $rec
        $rec.State = 'failed'; $rec.Reason = $err
        Save-WinnowMoveRecord -Record $rec
        return $rec
    }

    $boots = Test-WinnowWslBoots -Name $m.Distro
    Stop-WinnowWslDistro -Name $m.Distro
    $rec.Checked = "$($m.Distro) starts from $dest"
    if (-not $boots) { $rec.Checked = "WSL moved $($m.Distro) to $dest, but it did not start; try wsl -d $($m.Distro)" }
    $rec.State = 'done'
    $rec.FreedBytes = (Get-WinnowFreeSpace -Path $rec.From) - $freeBefore
    Save-WinnowMoveRecord -Record $rec
    return $rec
}

function Undo-WinnowWslHome {
    param([Parameter(Mandatory)][object]$Record)

    $rec = $Record
    $distro = @(Get-WinnowWslDistro | Where-Object { $_.Name -eq $rec.Distro })[0]
    if (-not $distro) { return "$($rec.Distro) is no longer registered" }
    $why = Stop-WinnowWslForMove -Name $rec.Distro -Disk $distro.Disk -IsDefault:$distro.Default
    if ($why) { return $why }

    $err = Move-WinnowWslDisk -Name $rec.Distro -Destination $rec.From
    $now = @(Get-WinnowWslDistro | Where-Object { $_.Name -eq $rec.Distro })[0]
    if (-not ($now -and (Test-WinnowPathUnder -Path $now.Disk -Root $rec.From))) {
        if (-not $err) { $err = 'the distribution still points to the moved folder' }
        return "nothing was changed: $err"
    }

    $boots = Test-WinnowWslBoots -Name $rec.Distro
    Stop-WinnowWslDistro -Name $rec.Distro
    $rec.Checked = "$($rec.Distro) starts from $($rec.From)"
    if (-not $boots) { $rec.Checked = "WSL moved $($rec.Distro) back, but it did not start; try wsl -d $($rec.Distro)" }
    $rm = Remove-WinnowMoveFolder -Record $rec
    $rec.LeftBehind = $null
    if (-not $rm.Removed -and $rm.Reason -ne 'path no longer exists') { $rec.LeftBehind = "$($rec.To): $($rm.Reason)" }
    $rec.State = 'undone'
    $rec.UndoneUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-WinnowMoveRecord -Record $rec
    return $null
}

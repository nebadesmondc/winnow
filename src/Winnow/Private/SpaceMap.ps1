# The space map: every byte the walk measured is placed in exactly one area,
# items first; what the walk could not see is shown as not explained.

function Get-WinnowSystemDriveRoot {
    $d = $env:SystemDrive
    if ([string]::IsNullOrWhiteSpace($d)) { $d = [System.IO.Path]::GetPathRoot($env:WINDIR) }
    return (ConvertTo-WinnowFullPath ($d.TrimEnd('\') + '\'))
}

function Start-WinnowDriveWalk {
    <#
    .SYNOPSIS
    Starts the drive walk in the background. Returns the task and a progress
    object whose Folders count grows as the walk runs.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $o = New-WinnowWalkOptions -Root $Root -Threads 16 -KeepDepth 3
    $o.Progress = New-Object Winnow.WalkProgress
    return [pscustomobject]@{ Task = [Winnow.SpaceWalker]::Start($o); Progress = $o.Progress }
}

function Get-WinnowMapArea {
    <#
    .SYNOPSIS
    The areas of the map and the folders that make them up.
    #>
    param([Parameter(Mandatory)][string]$DriveRoot)

    $userContent = @((Get-WinnowGuardPolicy).UserContentRoots)
    $programs = @($env:ProgramFiles, ${env:ProgramFiles(x86)})
    $local = Get-WinnowEnvRoot 'LOCALAPPDATA'
    if ($local) { $programs += (Join-Path $local 'Programs') }

    $usersRoot = $null
    $userHome = Get-WinnowEnvRoot 'USERPROFILE'
    if ($userHome) { $usersRoot = [System.IO.Path]::GetDirectoryName($userHome) }

    return @(
        [pscustomobject]@{ Name = 'Windows';                   Roots = @($env:WINDIR) }
        [pscustomobject]@{ Name = 'Installed programs';        Roots = $programs }
        [pscustomobject]@{ Name = 'Your files';                Roots = $userContent }
        [pscustomobject]@{ Name = 'App data';                  Roots = @($local, (Get-WinnowEnvRoot 'APPDATA'), (Get-WinnowEnvRoot 'PROGRAMDATA')) }
        [pscustomobject]@{ Name = 'Other folders in your profile'; Roots = @($userHome) }
        [pscustomobject]@{ Name = 'Other user accounts';       Roots = @($usersRoot) }
        [pscustomobject]@{ Name = "Other folders on $($DriveRoot.TrimEnd('\'))"; Roots = @($DriveRoot) }
    )
}

function Get-WinnowSpaceMap {
    <#
    .SYNOPSIS
    Splits the drive's used space into areas, net of the findings inside them.

    .OUTPUTS
    [pscustomobject] UsedBytes, ExplainedBytes, Areas (Name, Bytes, Top), NotExplained
    #>
    param(
        [Parameter(Mandatory)][object]$Walk,
        [object[]]$Findings = @(),
        [Parameter(Mandatory)][string]$DriveRoot
    )

    $drive = New-Object System.IO.DriveInfo($DriveRoot)
    $used = [double]($drive.TotalSize - $drive.TotalFreeSpace)

    # Each root once, on this drive, as walked.
    $roots = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($area in (Get-WinnowMapArea -DriveRoot $DriveRoot)) {
        foreach ($r in $area.Roots) {
            if ([string]::IsNullOrWhiteSpace($r)) { continue }
            $p = ConvertTo-WinnowFullPath $r
            if (-not $p -or -not (Test-WinnowPathUnder -Path $p -Root $DriveRoot)) { continue }
            if ($seen.ContainsKey($p.ToLowerInvariant())) { continue }
            $entry = $Walk.Find($p)
            if (-not $entry) { continue }
            $seen[$p.ToLowerInvariant()] = $true
            $roots.Add([pscustomobject]@{ Path = $p; Area = $area.Name; Bytes = [double]$entry.Bytes; Net = [double]$entry.Bytes })
        }
    }

    # A root's own share excludes the roots nested in it.
    foreach ($r in $roots) {
        $parent = Get-WinnowNearestRoot -Path $r.Path -Roots $roots -Exclude $r
        if ($parent) { $parent.Net -= $r.Bytes }
    }
    foreach ($f in $Findings) {
        $owner = Get-WinnowNearestRoot -Path $f.Path -Roots $roots
        if ($owner) { $owner.Net -= $f.Bytes }
    }

    $areas = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($roots | Group-Object Area)) {
        $bytes = 0
        foreach ($r in $group.Group) { $bytes += $r.Net }
        $areas.Add([pscustomobject]@{
            Name  = $group.Name
            Bytes = [math]::Max([double]0, $bytes)
            Top   = @(Get-WinnowAreaTop -Walk $Walk -AreaRoots $group.Group -Roots $roots -Findings $Findings)
        })
    }

    $mft = [double]0
    try { $mft = [double](New-Object System.IO.FileInfo(($DriveRoot + '$MFT'))).Length } catch { }
    if ($mft -gt 0) {
        $areas.Add([pscustomobject]@{ Name = 'File system index (MFT)'; Bytes = $mft; Top = @() })
    }

    $explained = [math]::Min($used, [double]$Walk.Bytes + $mft)
    return [pscustomobject]@{
        UsedBytes      = $used
        ExplainedBytes = $explained
        Areas          = @($areas | Sort-Object Bytes -Descending)
        NotExplained   = [pscustomobject]@{
            Bytes          = [math]::Max([double]0, $used - $explained)
            UnreadableDirs = $Walk.Denied.Count
        }
    }
}

function Get-WinnowNearestRoot {
    # The deepest root that contains Path.
    param([string]$Path, $Roots, $Exclude)
    $best = $null
    foreach ($r in $Roots) {
        if ($Exclude -and [object]::ReferenceEquals($r, $Exclude)) { continue }
        if (-not (Test-WinnowPathUnder -Path $Path -Root $r.Path)) { continue }
        if ($Exclude -and $r.Path.Length -ge $Exclude.Path.Length) { continue }
        if (-not $best -or $r.Path.Length -gt $best.Path.Length) { $best = $r }
    }
    return $best
}

function Get-WinnowAreaTop {
    <#
    .SYNOPSIS
    The largest folders directly inside an area's roots, net of nested roots
    and findings, so a person can see what the area holds.
    #>
    param($Walk, $AreaRoots, $Roots, $Findings, [int]$Count = 3)

    $ic = [System.StringComparison]::OrdinalIgnoreCase
    $parts = New-Object System.Collections.Generic.List[object]
    foreach ($ar in $AreaRoots) {
        $owned = @($Findings | Where-Object { [object]::ReferenceEquals((Get-WinnowNearestRoot -Path $_.Path -Roots $Roots), $ar) })
        foreach ($c in $Walk.Children($ar.Path)) {
            if ($c.Bytes -lt 100MB) { continue }
            $net = [double]$c.Bytes
            $prefix = $c.Path + '\'
            foreach ($r in $Roots) {
                if ($r.Path.Equals($c.Path, $ic) -or $r.Path.StartsWith($prefix, $ic)) { $net -= $r.Bytes }
            }
            foreach ($f in $owned) {
                if ($f.Path.Equals($c.Path, $ic) -or $f.Path.StartsWith($prefix, $ic)) { $net -= $f.Bytes }
            }
            if ($net -ge 100MB) {
                $name = [System.IO.Path]::GetFileName($c.Path)
                if ($name.Length -gt 24) { $name = $name.Substring(0, 21) + '...' }
                $parts.Add([pscustomobject]@{ Name = $name; Bytes = $net })
            }
        }
    }
    return @($parts | Sort-Object Bytes -Descending | Select-Object -First $Count)
}

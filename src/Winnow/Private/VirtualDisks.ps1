# Virtual disks: WSL distributions, Docker Desktop's data disk and any other
# virtual machine disk on the drive. Reported and explained, never removed.

function Get-WinnowWslDistro {
    <#
    .SYNOPSIS
    WSL 2 distributions registered for this user, with the path of each disk.
    #>
    $out = New-Object System.Collections.Generic.List[object]
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    $default = $null
    try { $default = (Get-ItemProperty -Path $key -ErrorAction Stop).DefaultDistribution } catch { return $out }

    foreach ($k in @(Get-ChildItem -Path $key -ErrorAction SilentlyContinue)) {
        $p = $null
        try { $p = Get-ItemProperty -Path $k.PSPath -ErrorAction Stop } catch { continue }
        if (-not $p.PSObject.Properties['BasePath'] -or -not $p.BasePath) { continue }
        $vhd = 'ext4.vhdx'
        if ($p.PSObject.Properties['VhdFileName'] -and $p.VhdFileName) { $vhd = $p.VhdFileName }
        $base = ConvertTo-WinnowFullPath $p.BasePath
        if (-not $base) { continue }
        $out.Add([pscustomobject]@{
            Name    = $p.DistributionName
            Disk    = Join-Path $base $vhd
            Default = ($k.PSChildName -eq $default)
        })
    }
    return $out
}

function Test-WinnowDockerDistro {
    param([string]$Name)
    return ($Name -like 'docker-desktop*')
}

function Get-WinnowWslDiskCandidate {
    param([object[]]$Distros = @(Get-WinnowWslDistro))

    foreach ($d in $Distros) {
        if (Test-WinnowDockerDistro $d.Name) { continue }
        $evidence = @("WSL distribution '$($d.Name)'")
        if ($d.Default) { $evidence += 'the default distribution' }
        [pscustomobject]@{
            Path   = $d.Disk
            Detail = $null
            Extra  = [pscustomobject]@{
                Title    = "WSL $($d.Name)"
                Id       = 'wsl-' + ($d.Name.ToLowerInvariant() -replace '[^a-z0-9.]+', '-')
                Evidence = $evidence
                Steps    = @(
                    'wsl --shutdown'
                    "wsl --manage $($d.Name) --move <folder on another drive>   (WSL 2.3 or later; wsl --version shows yours)"
                )
            }
        }
    }
}

function Get-WinnowDockerDiskCandidate {
    param(
        [object]$Walk = $script:WinnowWalk,
        [object[]]$Distros = @(Get-WinnowWslDistro)
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($d in $Distros) {
        if ((Test-WinnowDockerDistro $d.Name) -and $d.Name -ne 'docker-desktop') { $paths.Add($d.Disk) }
    }
    if ($Walk) {
        foreach ($n in $Walk.Notable) {
            if ([System.IO.Path]::GetFileName($n.Path) -eq 'docker_data.vhdx' -and -not $paths.Contains($n.Path)) { $paths.Add($n.Path) }
        }
    }

    foreach ($p in $paths) {
        $extra = [pscustomobject]@{ Title = 'Docker Desktop data disk' }
        if ($paths.Count -eq 1) { $extra | Add-Member -NotePropertyName Id -NotePropertyValue 'docker' }
        [pscustomobject]@{ Path = $p; Detail = $null; Extra = $extra }
    }
}

function Get-WinnowOtherDiskCandidate {
    param([object]$Walk = $script:WinnowWalk)

    if (-not $Walk) { return }
    # Disks under Windows or Program Files belong to installed components.
    $installed = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }

    foreach ($n in $Walk.Notable) {
        $owned = $false
        foreach ($i in $installed) { if (Test-WinnowPathUnder -Path $n.Path -Root $i) { $owned = $true } }
        if ($owned) { continue }
        [pscustomobject]@{
            Path   = $n.Path
            Detail = $null
            Extra  = [pscustomobject]@{ Title = 'Virtual disk ' + [System.IO.Path]::GetFileName($n.Path) }
        }
    }
}

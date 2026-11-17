# The pagefile and the hibernation file: explained, never changed.

function Get-WinnowPagefileCandidate {
    param([string]$DriveRoot = (Get-WinnowSystemDriveRoot))

    $path = Join-Path $DriveRoot 'pagefile.sys'
    $evidence = New-Object System.Collections.Generic.List[string]

    $usage = $null
    try {
        $usage = @(Get-CimInstance -ClassName Win32_PageFileUsage -ErrorAction Stop) |
            Where-Object { $_.Name -and $_.Name.Equals($path, [System.StringComparison]::OrdinalIgnoreCase) } |
            Select-Object -First 1
    } catch { }
    if ($usage) {
        $evidence.Add(('{0} in use now, at most {1} since Windows started' -f `
            (Format-WinnowSize ([double]$usage.CurrentUsage * 1MB)), (Format-WinnowSize ([double]$usage.PeakUsage * 1MB))))
    }

    $system = $null
    try { $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    if ($system) {
        $evidence.Add(('{0} of memory' -f (Format-WinnowSize ([double]$system.TotalPhysicalMemory))))
        if ($system.AutomaticManagedPagefile) {
            $evidence.Add('Windows sizes it: it grows after heavy memory use and can stay large')
        } else {
            $setting = $null
            try {
                $setting = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction Stop) |
                    Where-Object { $_.Name -and $_.Name.Equals($path, [System.StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1
            } catch { }
            if ($setting -and $setting.MaximumSize -gt 0) {
                $evidence.Add(('custom size, {0} to {1} MB' -f $setting.InitialSize, $setting.MaximumSize))
            }
        }
    }

    return [pscustomobject]@{
        Path   = $path
        Detail = $null
        Extra  = [pscustomobject]@{ Id = 'pagefile'; Evidence = $evidence }
    }
}

function Get-WinnowHiberfilCandidate {
    param([string]$DriveRoot = (Get-WinnowSystemDriveRoot))

    $path = Join-Path $DriveRoot 'hiberfil.sys'
    $evidence = New-Object System.Collections.Generic.List[string]

    $file = Measure-WinnowTree -Path $path
    $memory = $null
    try { $memory = [double](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { }
    if ($file.Exists -and $memory) {
        $evidence.Add(('{0:0}% of the {1} of memory' -f (100 * $file.Bytes / $memory), (Format-WinnowSize $memory)))
    }

    $fastStartup = $null
    try {
        $fastStartup = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction Stop).HiberbootEnabled
    } catch { }
    if ($fastStartup -eq 1) { $evidence.Add('Fast Startup is on and uses this file') }
    elseif ($fastStartup -eq 0) { $evidence.Add('Fast Startup is off; only hibernation uses this file') }

    return [pscustomobject]@{
        Path   = $path
        Detail = $null
        Extra  = [pscustomobject]@{ Id = 'hiberfil'; Evidence = $evidence }
    }
}

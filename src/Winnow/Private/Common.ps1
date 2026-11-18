# Shared helpers. Targets Windows PowerShell 5.1: no ternary, ??, && or classes.

$script:WinnowLongPathPrefix = '\\?\'

# Disables update checks and telemetry in the tools Winnow runs.
$script:WinnowChildEnvironment = @{
    'NO_UPDATE_NOTIFIER'            = '1'       # npm, pnpm and most Node CLIs
    'npm_config_update_notifier'    = 'false'   # npm, pnpm
    'npm_config_fund'               = 'false'
    'npm_config_audit'              = 'false'
    'PIP_DISABLE_PIP_VERSION_CHECK' = '1'       # pip
    'PIP_NO_INPUT'                  = '1'
    'UV_OFFLINE'                    = '1'       # uv
    'DO_NOT_TRACK'                  = '1'       # generic telemetry opt-out
    'DOTNET_CLI_TELEMETRY_OPTOUT'   = '1'
    'DOTNET_NOLOGO'                 = '1'
    'WSL_UTF8'                      = '1'       # wsl.exe prints UTF-16 otherwise
}

function ConvertTo-WinnowFullPath {
    <#
    .SYNOPSIS
    Returns the canonical full path without a trailing separator, resolving '..'.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $p = $Path
    if ($p.StartsWith($script:WinnowLongPathPrefix)) {
        $p = $p.Substring($script:WinnowLongPathPrefix.Length)
    }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return $null }

    # Keep the trailing separator only for a bare drive root ("C:\").
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\', '/') }
    return $p
}

function ConvertTo-WinnowLongPath {
    <#
    .SYNOPSIS
    Prefixes a canonical local path with \\?\ so .NET IO can exceed MAX_PATH.
    UNC paths become \\?\UNC\server\share.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if ($Path.StartsWith($script:WinnowLongPathPrefix)) { return $Path }
    if ($Path.StartsWith('\\')) {
        return $script:WinnowLongPathPrefix + 'UNC\' + $Path.Substring(2)
    }
    return $script:WinnowLongPathPrefix + $Path
}

function Format-WinnowBytes {
    <#
    .SYNOPSIS
    Formats a byte count at a fixed width so columns line up.
    #>
    param([Parameter(Mandatory)][AllowNull()][System.Nullable[double]]$Bytes)

    if ($null -eq $Bytes) { return '     -' }
    $b = [double]$Bytes
    if ($b -lt 0) { $b = 0 }

    if ($b -ge 1TB) { return ('{0,6:0.00} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0,6:0.00} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0,6:0.0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0,6:0} KB' -f ($b / 1KB)) }
    return ('{0,6:0} B ' -f $b)
}

function Get-WinnowKnownFolder {
    <#
    .SYNOPSIS
    Resolves a shell known folder, falling back to the profile subfolder.
    #>
    param([Parameter(Mandatory)][string]$Name)

    $map = @{
        Desktop    = 'Desktop';    Documents = 'MyDocuments'; Pictures = 'MyPictures'
        Music      = 'MyMusic';    Videos    = 'MyVideos';    Favorites = 'Favorites'
        StartMenu  = 'StartMenu';  AppData   = 'ApplicationData'
        LocalAppData = 'LocalApplicationData'
        UserProfile  = 'UserProfile'
        CommonStartMenu = 'CommonStartMenu'
    }
    if ($map.ContainsKey($Name)) {
        try {
            $v = [System.Environment]::GetFolderPath($map[$Name])
            if (-not [string]::IsNullOrWhiteSpace($v)) { return (ConvertTo-WinnowFullPath $v) }
        } catch { }
    }
    $profileRoot = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profileRoot)) { return $null }
    return (ConvertTo-WinnowFullPath (Join-Path $profileRoot $Name))
}

function Get-WinnowEnvRoot {
    <#
    .SYNOPSIS
    Resolves a base name such as LOCALAPPDATA from the environment.
    #>
    param([Parameter(Mandatory)][string]$Base)

    $value = $null
    switch ($Base) {
        'LOCALAPPDATA'  { $value = $env:LOCALAPPDATA }
        'APPDATA'       { $value = $env:APPDATA }
        'USERPROFILE'   { $value = $env:USERPROFILE }
        'TEMP'          { $value = $env:TEMP }
        'PROGRAMDATA'   { $value = $env:ProgramData }
        'HOME'          { if ($env:HOME) { $value = $env:HOME } else { $value = $env:USERPROFILE } }
        default         { $value = [System.Environment]::GetEnvironmentVariable($Base) }
    }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return (ConvertTo-WinnowFullPath $value)
}

function Test-WinnowFixedVolume {
    <#
    .SYNOPSIS
    True only for a path on a local fixed disk.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not $script:WinnowVolumeCache) { $script:WinnowVolumeCache = @{} }
    try { $root = [System.IO.Path]::GetPathRoot($Path) } catch { return $false }
    if ([string]::IsNullOrWhiteSpace($root)) { return $false }
    if ($script:WinnowVolumeCache.ContainsKey($root)) { return $script:WinnowVolumeCache[$root] }

    $ok = $false
    try {
        $di = New-Object System.IO.DriveInfo($root)
        $ok = ($di.DriveType -eq [System.IO.DriveType]::Fixed)
    } catch { $ok = $false }

    $script:WinnowVolumeCache[$root] = $ok
    return $ok
}

function Test-WinnowReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $attr = [System.IO.File]::GetAttributes((ConvertTo-WinnowLongPath $Path))
        return (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch { return $false }
}

function Test-WinnowPathExists {
    param([Parameter(Mandatory)][string]$Path)
    $lp = ConvertTo-WinnowLongPath $Path
    if ([System.IO.Directory]::Exists($lp)) { return $true }
    return [System.IO.File]::Exists($lp)
}

function Get-WinnowVolumeInfo {
    <#
    .SYNOPSIS
    Free and total space per fixed volume.
    #>
    param([string]$DriveLetter)

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        try {
            if ($d.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            if (-not $d.IsReady) { continue }
            $letter = $d.Name.Substring(0, 1)
            if ($DriveLetter -and ($letter -ne $DriveLetter.ToUpper())) { continue }
            $out.Add([pscustomobject]@{
                Letter    = $letter
                Label     = $d.VolumeLabel
                TotalBytes = [double]$d.TotalSize
                FreeBytes  = [double]$d.AvailableFreeSpace
                FreePct    = [math]::Round(100.0 * $d.AvailableFreeSpace / $d.TotalSize, 1)
            })
        } catch { }
    }
    return $out
}

function Invoke-WinnowCli {
    <#
    .SYNOPSIS
    Runs a command with a timeout and returns trimmed stdout, or $null on
    failure or timeout. Arguments come from rule data only.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Arguments = '',
        [int]$TimeoutSec = 10
    )

    $r = Invoke-WinnowProcess -Command $Command -Arguments $Arguments -TimeoutSec $TimeoutSec
    if ($r.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($r.Output)) { return $null }
    return $r.Output
}

function Invoke-WinnowProcess {
    <#
    .SYNOPSIS
    Runs a command with a timeout, offline and from the profile folder.

    .OUTPUTS
    [pscustomobject] ExitCode (-1 when it could not start or timed out),
    Output, Error (both trimmed), TimedOut
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [string]$Arguments = '',
        [int]$TimeoutSec = 10
    )

    $result = [pscustomobject]@{ ExitCode = -1; Output = ''; Error = ''; TimedOut = $false }
    $exe = $null
    try { $exe = Get-Command -Name $Command -CommandType Application -ErrorAction Stop | Select-Object -First 1 } catch { return $result }
    if (-not $exe) { return $result }

    # npm and pnpm are .cmd shims and need cmd.exe.
    $file = 'cmd.exe'
    $argLine = '/d /c "' + $Command + ' ' + $Arguments + '"'
    if ($exe.CommandType -eq 'Application' -and $exe.Source -and
        ([System.IO.Path]::GetExtension($exe.Source)).ToLower() -eq '.exe') {
        $file = $exe.Source
        $argLine = $Arguments
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($kv in $script:WinnowChildEnvironment.GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = $kv.Value
    }
    # A project's config (.npmrc, uv.toml) or drive (pnpm keeps a store per
    # drive) in the current folder would change the answer.
    $wd = Get-WinnowEnvRoot -Base 'USERPROFILE'
    if ($wd) { $psi.WorkingDirectory = $wd }

    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        # Both streams are drained, or a chatty tool blocks on a full pipe.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            Write-Verbose "Winnow: '$Command $Arguments' timed out after ${TimeoutSec}s."
            $result.TimedOut = $true
            return $result
        }
        $proc.WaitForExit()
        $result.ExitCode = $proc.ExitCode
        if ($stdout.Result) { $result.Output = $stdout.Result.Trim() }
        if ($stderr.Result) { $result.Error = $stderr.Result.Trim() }
        return $result
    } catch {
        return $result
    } finally {
        if ($proc) { try { $proc.Dispose() } catch { } }
    }
}

function Write-WinnowLine {
    <#
    .SYNOPSIS
    Writes a console line in one of the Winnow styles.
    #>
    param(
        [string]$Text = '',
        [ValidateSet('Normal', 'Dim', 'Head', 'Good', 'Warn', 'Bad', 'Accent')]
        [string]$Style = 'Normal',
        [switch]$NoNewline
    )
    $colour = 'Gray'
    switch ($Style) {
        'Dim'    { $colour = 'DarkGray' }
        'Head'   { $colour = 'White' }
        'Good'   { $colour = 'Green' }
        'Warn'   { $colour = 'Yellow' }
        'Bad'    { $colour = 'Red' }
        'Accent' { $colour = 'Cyan' }
    }
    if ($NoNewline) { Write-Host $Text -ForegroundColor $colour -NoNewline }
    else { Write-Host $Text -ForegroundColor $colour }
}

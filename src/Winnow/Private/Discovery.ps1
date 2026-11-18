# Location discovery and installed-program lookup.

function Resolve-WinnowRoot {
    <#
    .SYNOPSIS
    Walks a rule's Resolve chain and returns the first existing path, or with
    -All every distinct one. The first is the location in use (Primary); later
    ones are copies elsewhere, such as the default location after a redirect.
    A hit nested in, or containing, an earlier one is skipped.

    .OUTPUTS
    [pscustomobject] Path, Strategy, Detail, Primary  (or $null when nothing resolved)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Resolve,
        [switch]$All
    )

    $found = New-Object System.Collections.Generic.List[object]

    foreach ($step in $Resolve) {
        $candidate = $null
        $strategy = $step.Type
        $detail = $null

        switch ($step.Type) {

            'Cli' {
                $timeout = 10
                if ($step.ContainsKey('TimeoutSec')) { $timeout = [int]$step.TimeoutSec }
                if (-not (Get-Command -Name $step.Command -ErrorAction SilentlyContinue)) { continue }
                # npm and npx rules ask the same question; ask once per scan.
                $key = "$($step.Command) $($step.Args)"
                if ($script:WinnowCliAnswers.ContainsKey($key)) { $out = $script:WinnowCliAnswers[$key] }
                else {
                    $out = Invoke-WinnowCli -Command $step.Command -Arguments $step.Args -TimeoutSec $timeout
                    $script:WinnowCliAnswers[$key] = $out
                }
                $candidate = Get-WinnowPathFromOutput -Text $out
                $detail = "resolved via ``$($step.Command) $($step.Args)``"
            }

            'Env' {
                $names = @($step.Name)
                foreach ($n in $names) {
                    $v = [System.Environment]::GetEnvironmentVariable($n)
                    if (-not [string]::IsNullOrWhiteSpace($v)) {
                        $candidate = $v
                        $detail = "resolved via `$env:$n"
                        break
                    }
                }
            }

            'Path' {
                $bases = @($step.Base)
                foreach ($b in $bases) {
                    $root = Get-WinnowEnvRoot -Base $b
                    if (-not $root) { continue }
                    $try = $root
                    if ($step.ContainsKey('Sub') -and $step.Sub) {
                        $try = Join-Path $root ($step.Sub -replace '/', '\')
                    }
                    if (Test-WinnowPathExists -Path $try) {
                        $candidate = $try
                        $detail = "found by convention under `$env:$b"
                        break
                    }
                }
            }
        }

        # Cli/Env return a tool root; Sub narrows it (GRADLE_USER_HOME\caches).
        # Path steps applied Sub above.
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and $step.Type -ne 'Path' -and
            $step.ContainsKey('Sub') -and $step.Sub) {
            $candidate = Join-Path $candidate ($step.Sub -replace '/', '\')
        }

        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $canon = ConvertTo-WinnowFullPath $candidate
        if (-not $canon) { continue }
        if (-not (Test-WinnowPathExists -Path $canon)) { continue }

        $overlaps = $false
        foreach ($f in $found) {
            if ((Test-WinnowPathUnder -Path $canon -Root $f.Path) -or (Test-WinnowPathUnder -Path $f.Path -Root $canon)) {
                $overlaps = $true
                break
            }
        }
        if ($overlaps) { continue }

        $hit = [pscustomobject]@{
            Path     = $canon
            Strategy = $strategy
            Detail   = $detail
            Primary  = ($found.Count -eq 0)
        }
        if (-not $All) { return $hit }
        $found.Add($hit)
    }
    if ($All) { return $found }
    return $null
}

function Get-WinnowPathFromOutput {
    # The first line of a tool's answer that looks like an absolute path.
    param([AllowNull()][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        if ($t -match '^[A-Za-z]:\\' -or $t -match '^[\\/]{2}' -or $t -match '^/') { return $t }
        # Some CLIs print "global-packages: <path>".
        if ($t -match ':\s+([A-Za-z]:\\.+)$') { return $Matches[1] }
    }
    return $null
}

function Get-WinnowUninstallEntry {
    <#
    .SYNOPSIS
    Cached snapshot of installed-program registry entries (all three hives).
    #>
    param([switch]$Refresh)

    if ($script:WinnowUninstallCache -and -not $Refresh) { return $script:WinnowUninstallCache }

    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($k in $keys) {
        $items = $null
        try { $items = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue } catch { }
        if (-not $items) { continue }
        foreach ($i in $items) {
            if ([string]::IsNullOrWhiteSpace($i.DisplayName)) { continue }
            $loc = $null
            if ($i.PSObject.Properties['InstallLocation'] -and $i.InstallLocation) {
                $loc = ConvertTo-WinnowFullPath $i.InstallLocation
            }
            $list.Add([pscustomobject]@{
                DisplayName     = $i.DisplayName
                DisplayVersion  = $i.DisplayVersion
                InstallLocation = $loc
            })
        }
    }
    $script:WinnowUninstallCache = $list
    return $list
}

$script:WinnowCliAnswers = @{}

function Reset-WinnowDiscoveryCache {
    $script:WinnowUninstallCache = $null
    $script:WinnowCliAnswers = @{}
}

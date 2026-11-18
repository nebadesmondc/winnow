# Older versions apps keep after updating themselves. Only versions shown to
# be superseded are offered, and only as Your call.

function Get-WinnowProductVersion {
    # The version in an Electron app build's resources\app\product.json.
    param([Parameter(Mandatory)][string]$BuildPath)
    $json = Join-Path $BuildPath 'resources\app\product.json'
    try {
        $v = (Get-Content -LiteralPath $json -Raw -ErrorAction Stop | ConvertFrom-Json).version
        return [version]($v -replace '[^0-9.].*$', '')
    } catch { return $null }
}

function Get-WinnowVSCodeInstall {
    <#
    .SYNOPSIS
    User installs laid out like VS Code: a launcher whose VisualElementsManifest
    names the build folder in use, beside other build folders.
    #>
    param([string]$ProgramsRoot)

    if (-not $ProgramsRoot) {
        $local = Get-WinnowEnvRoot 'LOCALAPPDATA'
        if (-not $local) { return }
        $ProgramsRoot = Join-Path $local 'Programs'
    }

    foreach ($app in (Get-WinnowChildDirectory -Path $ProgramsRoot)) {
        $manifest = @(Get-WinnowChildFile -Path $app.Path -Filter '*.VisualElementsManifest.xml') | Select-Object -First 1
        if (-not $manifest) { continue }
        $text = $null
        try { $text = [System.IO.File]::ReadAllText($manifest.Path) } catch { continue }
        if ($text -notmatch '"([0-9a-f]{10})\\resources\\') { continue }
        $current = $Matches[1]

        $builds = @(Get-WinnowChildDirectory -Path $app.Path | Where-Object { $_.Name -match '^[0-9a-f]{10}$' } | ForEach-Object {
            [pscustomobject]@{ Name = $_.Name; Path = $_.Path; Version = (Get-WinnowProductVersion -BuildPath $_.Path) }
        })
        $inUse = @($builds | Where-Object { $_.Name -eq $current }) | Select-Object -First 1
        if (-not $inUse -or -not $inUse.Version) { continue }

        $pending = @($builds | Where-Object { $_.Version -and $_.Version -gt $inUse.Version } | Sort-Object Version -Descending) | Select-Object -First 1
        [pscustomobject]@{
            Name    = $app.Name
            Path    = $app.Path
            InUse   = $inUse
            Older   = @($builds | Where-Object { $_.Version -and $_.Version -lt $inUse.Version })
            Pending = $pending
        }
    }
}

function Get-WinnowVSCodeBuildCandidate {
    param([string]$ProgramsRoot)

    foreach ($install in @(Get-WinnowVSCodeInstall -ProgramsRoot $ProgramsRoot)) {
        foreach ($b in $install.Older) {
            [pscustomobject]@{
                Path   = $b.Path
                Detail = $null
                Extra  = [pscustomobject]@{
                    Title    = "$($install.Name) $($b.Version) (older build)"
                    Evidence = @("$($install.Name) runs from build $($install.InUse.Name), version $($install.InUse.Version)")
                }
            }
        }
    }
}

$script:WinnowEditors = @(
    @{ Dir = '.vscode';          Name = 'VS Code';          Process = 'Code' }
    @{ Dir = '.vscode-insiders'; Name = 'VS Code Insiders'; Process = 'Code - Insiders' }
    @{ Dir = '.cursor';          Name = 'Cursor';           Process = 'Cursor' }
    @{ Dir = '.windsurf';        Name = 'Windsurf';         Process = 'Windsurf' }
)

function Get-WinnowStaleExtensionCandidate {
    <#
    .SYNOPSIS
    Extension folders the editor no longer loads: not in its extensions.json,
    and either marked obsolete by the editor or replaced by a newer version.
    #>
    param([string]$UserHome = (Get-WinnowEnvRoot 'USERPROFILE'))

    if (-not $UserHome) { return }
    foreach ($e in $script:WinnowEditors) {
        $dir = Join-Path $UserHome "$($e.Dir)\extensions"
        $list = Join-Path $dir 'extensions.json'
        if (-not (Test-WinnowPathExists -Path $list)) { continue }

        # Assigned, not wrapped in @(): Windows PowerShell 5.1 passes a JSON
        # array down the pipeline as one object, which @() would nest.
        $entries = $null
        try { $entries = Get-Content -LiteralPath $list -Raw -ErrorAction Stop | ConvertFrom-Json } catch { continue }
        $loaded = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($x in @($entries)) {
            if ($x.PSObject.Properties['relativeLocation'] -and $x.relativeLocation) { [void]$loaded.Add($x.relativeLocation) }
            elseif ($x.location -and $x.location.path) { [void]$loaded.Add([System.IO.Path]::GetFileName($x.location.path)) }
        }
        if ($loaded.Count -eq 0) { continue }

        $obsolete = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $o = Get-Content -LiteralPath (Join-Path $dir '.obsolete') -Raw -ErrorAction Stop | ConvertFrom-Json
            foreach ($p in $o.PSObject.Properties) { if ($p.Value) { [void]$obsolete.Add($p.Name) } }
        } catch { }

        $loadedIds = @{}
        foreach ($l in $loaded) { if ($l -match '^(.+?)-\d+\.\d+\.\d+') { $loadedIds[$Matches[1].ToLowerInvariant()] = $l } }

        foreach ($d in (Get-WinnowChildDirectory -Path $dir)) {
            if ($d.Name.StartsWith('.') -or $loaded.Contains($d.Name)) { continue }
            if ($d.Name -notmatch '^(.+?)-\d+\.\d+\.\d+') { continue }
            $id = $Matches[1].ToLowerInvariant()

            $why = $null
            if ($obsolete.Contains($d.Name)) { $why = "$($e.Name) marked it obsolete" }
            elseif ($loadedIds.ContainsKey($id)) { $why = "$($e.Name) loads $($loadedIds[$id]) instead" }
            if (-not $why) { continue }

            [pscustomobject]@{
                Path   = $d.Path
                Detail = $null
                Extra  = [pscustomobject]@{
                    Title          = "$($e.Name) extension $($d.Name)"
                    Evidence       = @($why)
                    RequiresClosed = @($e.Process)
                }
            }
        }
    }
}

function Get-WinnowSquirrelVersionCandidate {
    <#
    .SYNOPSIS
    Older app-<version> folders of apps that update themselves with Squirrel
    (Discord, Slack, Postman and others). The app runs from the newest.
    #>
    param([string]$Root = (Get-WinnowEnvRoot 'LOCALAPPDATA'))

    if (-not $Root) { return }
    foreach ($app in (Get-WinnowChildDirectory -Path $Root)) {
        if (-not (Test-WinnowPathExists -Path (Join-Path $app.Path 'Update.exe'))) { continue }
        $versions = @(Get-WinnowChildDirectory -Path $app.Path | ForEach-Object {
            $v = $null
            if ($_.Name -match '^app-(\d+(\.\d+){1,3})$') { try { $v = [version]$Matches[1] } catch { } }
            if ($v) { [pscustomobject]@{ Path = $_.Path; Version = $v } }
        })
        if ($versions.Count -lt 2) { continue }
        $newest = @($versions | Sort-Object Version -Descending)[0]
        foreach ($v in $versions) {
            if ($v.Version -ge $newest.Version) { continue }
            [pscustomobject]@{
                Path   = $v.Path
                Detail = $null
                Extra  = [pscustomobject]@{
                    Title    = "$($app.Name) $($v.Version) (older version)"
                    Evidence = @("$($app.Name) runs from app-$($newest.Version)")
                }
            }
        }
    }
}

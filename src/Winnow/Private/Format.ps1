# Console rendering.

function Format-WinnowPath {
    <#
    .SYNOPSIS
    Replaces known roots with tokens such as %LOCALAPPDATA%, which also keeps
    the user name out of output.
    #>
    param([Parameter(Mandatory)][AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path

    # Longest root first so %LOCALAPPDATA% wins over %USERPROFILE%.
    $tokens = @(
        @{ Token = '%TEMP%';         Root = (Get-WinnowEnvRoot 'TEMP') }
        @{ Token = '%LOCALAPPDATA%'; Root = (Get-WinnowEnvRoot 'LOCALAPPDATA') }
        @{ Token = '%APPDATA%';      Root = (Get-WinnowEnvRoot 'APPDATA') }
        @{ Token = '%PROGRAMDATA%';  Root = (Get-WinnowEnvRoot 'PROGRAMDATA') }
        @{ Token = '~';              Root = (Get-WinnowEnvRoot 'USERPROFILE') }
    ) | Sort-Object { if ($_.Root) { -$_.Root.Length } else { 0 } }

    foreach ($t in $tokens) {
        if (-not $t.Root) { continue }
        if ($p.StartsWith($t.Root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $t.Token + $p.Substring($t.Root.Length)
        }
    }
    return $p
}

function Format-WinnowSize {
    # Compact size for tables: "21.5 GB", "430 MB".
    param([double]$Bytes)
    if ($Bytes -ge 10GB) { return ('{0:0} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1GB) { return ('{0:0.0} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:0} MB' -f ($Bytes / 1MB)) }
    return ('{0:0} KB' -f ($Bytes / 1KB))
}

function Format-WinnowCell {
    param([string]$Text, [int]$Width)
    if ($Text.Length -gt $Width) { return $Text.Substring(0, $Width - 3) + '...' }
    return $Text.PadRight($Width)
}

function Get-WinnowItemRow {
    <#
    .SYNOPSIS
    One table row per finding, with every Clean finding folded into one row.
    #>
    param([Parameter(Mandatory)][object]$Report)

    $rows = New-Object System.Collections.Generic.List[object]
    $clean = @($Report.Findings | Where-Object { -not $_.Suppressed -and $_.Verdict -eq 'Clean' })
    if ($clean.Count -gt 0) {
        $sum = 0; foreach ($f in $clean) { $sum += $f.Bytes }
        $rows.Add([pscustomobject]@{
            Title = "Caches and temporary files ($($clean.Count))"; Bytes = $sum
            Verdict = 'Clean'; Next = 'winnow clean'; Style = 'Good'
        })
    }
    foreach ($f in $Report.Findings) {
        if (-not $f.Suppressed -and $f.Verdict -eq 'Clean') { continue }
        $label = $script:WinnowVerdictNames[$f.Verdict]
        $style = 'Normal'
        if ($f.Suppressed) { $label = 'Held back'; $style = 'Warn' }
        $rows.Add([pscustomobject]@{
            Title = $f.Title; Bytes = $f.Bytes; Verdict = $label
            Next = "winnow explain $($f.Id)"; Style = $style
        })
    }
    return @($rows | Sort-Object Bytes -Descending)
}

function Show-WinnowVolume {
    param([Parameter(Mandatory)][object[]]$Volumes)

    foreach ($v in $Volumes) {
        $usedPct = 0
        if ($v.TotalBytes -gt 0) { $usedPct = ($v.TotalBytes - $v.FreeBytes) / $v.TotalBytes }
        $filled = [int][math]::Round(30 * $usedPct)
        $bar = '[' + ('#' * $filled) + ('.' * (30 - $filled)) + ']'
        $style = 'Normal'
        $state = ''
        if ($v.FreePct -lt 10) { $style = 'Bad'; $state = '  low' }
        Write-WinnowLine ('  {0}:  {1,7}  {2}  {3,7} free{4}' -f `
            $v.Letter, (Format-WinnowSize $v.TotalBytes), $bar, (Format-WinnowSize $v.FreeBytes), $state) -Style $style
    }
}

function Show-WinnowReport {
    <#
    .SYNOPSIS
    Renders a scan report to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [int]$Top = 12,
        [switch]$All
    )

    Write-Host ''
    Show-WinnowVolume -Volumes @($Report.Volumes)
    Write-Host ''

    $line = { param($r) '  {0} {1,8}  {2} {3}' -f (Format-WinnowCell $r.Title 42), (Format-WinnowSize $r.Bytes), (Format-WinnowCell $r.Verdict 10), $r.Next }

    Write-WinnowLine ('  {0} {1,8}  {2} {3}' -f (Format-WinnowCell 'WHERE THE SPACE IS' 42), 'SIZE', (Format-WinnowCell 'VERDICT' 10), 'NEXT') -Style Head
    $rows = @(Get-WinnowItemRow -Report $Report)
    $show = $rows
    if (-not $All -and $rows.Count -gt $Top) { $show = @($rows[0..($Top - 1)]) }
    foreach ($r in $show) { Write-WinnowLine (& $line $r) -Style $r.Style }
    if ($show.Count -lt $rows.Count) {
        $rest = 0; foreach ($r in $rows[$show.Count..($rows.Count - 1)]) { $rest += $r.Bytes }
        Write-WinnowLine (& $line ([pscustomobject]@{ Title = "$($rows.Count - $show.Count) more items"; Bytes = $rest; Verdict = ''; Next = 'winnow -All' })) -Style Dim
    }

    $map = $null
    if ($Report.PSObject.Properties['Map']) { $map = $Report.Map }
    if ($map) {
        foreach ($a in $map.Areas) {
            if ($a.Bytes -lt 100MB) { continue }
            $largest = ($a.Top | ForEach-Object { '{0} {1}' -f $_.Name, (Format-WinnowSize $_.Bytes) }) -join ', '
            Write-WinnowLine (& $line ([pscustomobject]@{ Title = $a.Name; Bytes = $a.Bytes; Verdict = '-'; Next = $largest })) -Style Dim
        }
        $ne = $map.NotExplained
        $why = 'restore points, reserved storage'
        if ($ne.UnreadableDirs -gt 0) { $why += ", $($ne.UnreadableDirs) folders only an administrator can read" }
        Write-WinnowLine (& $line ([pscustomobject]@{ Title = 'Not explained'; Bytes = $ne.Bytes; Verdict = '-'; Next = $why })) -Style Dim
    }

    if ($Report.RuleErrors -and $Report.RuleErrors.Count -gt 0) {
        Write-Host ''
        foreach ($e in $Report.RuleErrors) {
            Write-WinnowLine ('  rule {0} failed: {1}' -f $e.RuleId, $e.Message) -Style Bad
        }
    }

    $cleanNow = 0
    foreach ($f in $Report.Findings) { if (Test-WinnowFindingActionable -Finding $f) { $cleanNow += $f.Bytes } }
    $explained = ''
    if ($map -and $map.UsedBytes -gt 0) {
        $explained = '    Explained: {0:0}% of {1} used' -f (100 * $map.ExplainedBytes / $map.UsedBytes), (Format-WinnowSize $map.UsedBytes)
    }
    Write-Host ''
    Write-WinnowLine ('  Clean now: {0}{1}    Nothing has been changed.    ({2:0} s)' -f (Format-WinnowSize $cleanNow), $explained, $Report.DurationSec) -Style Good
    Write-Host ''
}

function Show-WinnowExplain {
    <#
    .SYNOPSIS
    Everything known about one finding: what removing it costs, the evidence,
    why it is held back and the steps to take.
    #>
    param([Parameter(Mandatory)][object]$Finding)

    $f = $Finding
    $label = $script:WinnowVerdictNames[$f.Verdict]
    Write-Host ''
    Write-WinnowLine ('  {0} {1,8}  {2}' -f (Format-WinnowCell $f.Title 52), (Format-WinnowSize $f.Bytes), $label) -Style Head
    Write-WinnowLine ('  ' + (Format-WinnowPath $f.Path)) -Style Dim
    Write-Host ''

    $section = {
        param([string]$Name, [object[]]$Lines, [string]$Style = 'Normal')
        $first = $true
        foreach ($l in $Lines) {
            if (-not $l) { continue }
            $head = ''
            if ($first) { $head = $Name }
            Write-WinnowLine ('  {0}{1}' -f $head.PadRight(13), $l) -Style $Style
            $first = $false
        }
    }

    if ($f.Suppressed) { & $section 'Held back' @($f.SuppressReason) 'Warn' }
    & $section 'If removed' @($f.Consequence)
    $changed = $null
    if ($f.NewestWrite) { $changed = '{0:yyyy-MM-dd}' -f ([datetime]$f.NewestWrite).ToLocalTime() }
    & $section 'Last change' @($changed) 'Dim'
    & $section 'Evidence' @($f.Evidence) 'Dim'
    & $section 'Warnings' @($f.Warnings | ForEach-Object { "! $_" }) 'Warn'
    $i = 0
    & $section 'Steps' @($f.Steps | ForEach-Object { $i++; "$i. $_" })
    & $section 'Docs' @($f.Docs) 'Dim'
    Write-Host ''

    if (Test-WinnowFindingActionable -Finding $f -ById) {
        $how = "winnow clean $($f.Id)"
        if ($f.Verdict -eq 'YourCall') { $how += '    (to the Recycle Bin)' }
        elseif ($f.Verdict -eq 'Clean') { $how += '    (or winnow clean for every Clean item)' }
        Write-WinnowLine "  To remove it: $how" -Style Accent
        Write-Host ''
    }
}

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
    $movable = @{}
    if ($Report.PSObject.Properties['Movable']) { foreach ($m in $Report.Movable) { $movable[$m.Id] = $m } }
    foreach ($f in $Report.Findings) {
        if (-not $f.Suppressed -and $f.Verdict -eq 'Clean') { continue }
        $label = $script:WinnowVerdictNames[$f.Verdict]
        $style = 'Normal'
        $next = "winnow explain $($f.Id)"
        if ($f.Suppressed) { $label = 'Held back'; $style = 'Warn' }
        elseif ($movable.ContainsKey($f.Id)) { $next = "winnow move $($f.Id)" }
        $rows.Add([pscustomobject]@{
            Title = $f.Title; Bytes = $f.Bytes; Verdict = $label
            Next = $next; Style = $style
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
        $note = Get-WinnowDriveNote -Letter $v.Letter
        if ($note) { $state += "  $note" }
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
    $movableNow = ''
    if ($Report.PSObject.Properties['Movable']) {
        $sum = 0; foreach ($m in $Report.Movable) { if (-not $m.Blocker) { $sum += $m.Bytes } }
        if ($sum -gt 0) { $movableNow = '    Movable: {0}' -f (Format-WinnowSize $sum) }
    }
    $explained = ''
    if ($map -and $map.UsedBytes -gt 0) {
        $explained = '    Explained: {0:0}% of {1} used' -f (100 * $map.ExplainedBytes / $map.UsedBytes), (Format-WinnowSize $map.UsedBytes)
    }
    Write-Host ''
    Write-WinnowLine ('  Clean now: {0}{1}{2}    Nothing has been changed.    ({3:0} s)' -f (Format-WinnowSize $cleanNow), $movableNow, $explained, $Report.DurationSec) -Style Good
    if ($movableNow) { Write-WinnowLine '  winnow move lists what can go to another drive.' -Style Dim }
    Write-Host ''
}

function Show-WinnowMoveList {
    param([Parameter(Mandatory)][object]$Report)

    $items = @($Report.Movable)
    Write-Host ''
    if ($items.Count -eq 0) {
        Write-WinnowLine "  Nothing on $($Report.Drive) needs to move." -Style Dim
        Write-Host ''
        return
    }
    Write-WinnowLine ('  {0} {1,8}  {2}' -f (Format-WinnowCell 'WHAT CAN MOVE' 42), 'SIZE', 'NEXT') -Style Head
    $largest = 0
    foreach ($m in $items) {
        if ($m.Blocker) {
            Write-WinnowLine ('  {0} {1,8}  {2}' -f (Format-WinnowCell $m.Title 42), (Format-WinnowSize $m.Bytes), "- $($m.Blocker)") -Style Dim
            continue
        }
        if ($m.Bytes -gt $largest) { $largest = $m.Bytes }
        Write-WinnowLine ('  {0} {1,8}  {2}' -f (Format-WinnowCell $m.Title 42), (Format-WinnowSize $m.Bytes), "winnow move $($m.Id)") -Style Normal
    }
    Write-Host ''
    if ($largest -gt 0) {
        $drive = @(Get-WinnowMoveDrive -Bytes $largest -Source $Report.Drive)[0]
        if ($drive) {
            $note = ''
            if ($drive.Note) { $note = "; $($drive.Note)" }
            Write-WinnowLine ('  Moves go to {0}: ({1} free{2}). -To picks another folder.' -f $drive.Letter, (Format-WinnowSize $drive.FreeBytes), $note) -Style Dim
        } else {
            Write-WinnowLine '  No other fixed drive has room. -To picks a folder on another drive.' -Style Warn
        }
        Write-WinnowLine '  Each move is checked before the old copy is deleted, and winnow undo reverses it.' -Style Dim
    }
    Write-Host ''
}

function Show-WinnowMovePlan {
    param([Parameter(Mandatory)][object]$Plan)

    $m = $Plan.Movable
    $row = { param($label, $text, $style = 'Normal') Write-WinnowLine ('    {0} {1}' -f $label.PadRight(6), $text) -Style $style }
    Write-Host ''
    Write-WinnowLine ('  {0} {1,8}' -f (Format-WinnowCell $m.Title 42), (Format-WinnowSize $m.Bytes)) -Style Head

    if ($Plan.Problem) {
        Write-WinnowLine "    Cannot move now: $($Plan.Problem)." -Style Warn
        Write-Host ''
        return
    }

    $note = ''
    if ($Plan.DriveNote) { $note = "; $($Plan.DriveNote)" }
    if ($m.Kind -eq 'Guided') {
        & $row 'from' (Format-WinnowPath $m.Path) 'Dim'
        Write-WinnowLine '    It moves with its own setting; Winnow does not touch it.' -Style Normal
        $i = 0
        foreach ($s in $m.Steps) { $i++; Write-WinnowLine "    $i. $s" -Style Normal }
        & $row 'folder' "$($Plan.Destination), for example$note" 'Dim'
        Write-Host ''
        return
    }

    & $row 'from' (Format-WinnowPath $m.Path) 'Dim'
    & $row 'to' "$($Plan.Destination)   (a new folder only you can open$note)"
    if ($m.Kind -eq 'Wsl') {
        & $row 'how' "stops $($m.Distro), then wsl --manage $($m.Distro) --move $($Plan.Destination)"
        & $row 'check' "starts $($m.Distro) once from the new folder"
    } else {
        & $row 'how' "copies it, then sets $($m.Env) for your account"
        $check = "$($m.Env) points to the new folder"
        if ($m.Verify) { $check = "$($m.Verify.Command) $($m.Verify.Args) names the new folder" }
        & $row 'check' "$check; only then is the old folder deleted"
    }
    if ($m.Note) { & $row 'note' $m.Note 'Dim' }
    Write-Host ''
}

function Show-WinnowMoveResult {
    param([Parameter(Mandatory)][object]$Record)

    $r = $Record
    Write-Host ''
    if ($r.State -ne 'done') {
        Write-WinnowLine "  $($r.Title) was not moved: $($r.Reason). Nothing was changed." -Style Bad
        Write-Host ''
        return
    }
    Write-WinnowLine "  Moved $($r.Title) to $($r.To)." -Style Good
    if ($r.Checked) { Write-WinnowLine "  Checked: $($r.Checked)." -Style Normal }
    if ($r.FreedBytes -gt 1MB) {
        Write-WinnowLine ('  {0}: {1} freed' -f $r.From.Substring(0, 1), (Format-WinnowBytes $r.FreedBytes).Trim()) -Style Good
    }
    if ($r.LeftBehind) { Write-WinnowLine "  Left behind: $($r.LeftBehind)" -Style Warn }
    if ($r.Kind -eq 'Variable') {
        Write-WinnowLine "  Open a new terminal, and restart editors, so they pick up $($r.Variable.Name)." -Style Accent
    }
    Write-WinnowLine "  To undo: winnow undo $($r.Id)" -Style Dim
    Write-Host ''
}

function Show-WinnowUndoPlan {
    param([Parameter(Mandatory)][object]$Record)

    $r = $Record
    $row = { param($label, $text, $style = 'Normal') Write-WinnowLine ('    {0} {1}' -f $label.PadRight(6), $text) -Style $style }
    Write-Host ''
    Write-WinnowLine ('  {0} {1,8}' -f (Format-WinnowCell "Undo: $($r.Title)" 42), (Format-WinnowSize $r.Bytes)) -Style Head
    & $row 'moved' ('{0:yyyy-MM-dd HH:mm}' -f ([datetime]$r.WhenUtc).ToLocalTime()) 'Dim'
    & $row 'from' $r.To 'Dim'
    & $row 'to' (Format-WinnowPath $r.From)
    if ($r.Kind -eq 'Wsl') {
        & $row 'how' "stops $($r.Distro), then wsl --manage $($r.Distro) --move back"
    } else {
        $old = 'removed'
        if ($r.Variable.OldUser) { $old = "set back to $($r.Variable.OldUser)" }
        & $row 'how' "copies it back, $($r.Variable.Name) is $old, then the moved copy is deleted"
    }
    Write-Host ''
}

function Show-WinnowUndoResult {
    param([Parameter(Mandatory)][object]$Record, [string]$Problem)

    $r = $Record
    Write-Host ''
    if ($Problem) {
        Write-WinnowLine "  $($r.Title) was not moved back: $Problem." -Style Bad
        Write-Host ''
        return
    }
    Write-WinnowLine "  Moved $($r.Title) back to $(Format-WinnowPath $r.From)." -Style Good
    if ($r.Checked) { Write-WinnowLine "  Checked: $($r.Checked)." -Style Normal }
    if ($r.LeftBehind) { Write-WinnowLine "  Left behind: $($r.LeftBehind)" -Style Warn }
    if ($r.Kind -eq 'Variable') {
        Write-WinnowLine "  Open a new terminal, and restart editors, so they pick up $($r.Variable.Name)." -Style Accent
    }
    Write-Host ''
}

function Show-WinnowExplain {
    <#
    .SYNOPSIS
    Everything known about one finding: what removing it costs, the evidence,
    why it is held back and the steps to take.
    #>
    param([Parameter(Mandatory)][object]$Finding, [object]$Movable)

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

    $actions = $false
    if (Test-WinnowFindingActionable -Finding $f -ById) {
        $how = "winnow clean $($f.Id)"
        if ($f.Verdict -eq 'YourCall') { $how += '    (to the Recycle Bin)' }
        elseif ($f.Verdict -eq 'Clean') { $how += '    (or winnow clean for every Clean item)' }
        Write-WinnowLine "  To remove it: $how" -Style Accent
        $actions = $true
    }
    foreach ($m in @($Movable)) {
        if (-not $m -or $m.Blocker) { continue }
        $label = 'To move it:'
        if ($actions) { $label = 'Or move it:' }
        Write-WinnowLine "  $label   winnow move $($m.Id)    ($($m.Title), $(Format-WinnowSize $m.Bytes))" -Style Accent
        $actions = $true
    }
    if ($actions) { Write-Host '' }
}

function Get-WinnowMovableFor {
    # What moves with a finding: the finding itself, or the tool home it sits in.
    param([Parameter(Mandatory)][object]$Finding, [object[]]$Movable = @())
    foreach ($m in $Movable) {
        if (-not $m -or -not $m.Path) { continue }
        if ($m.Id -eq $Finding.Id -or (Test-WinnowPathUnder -Path $Finding.Path -Root $m.Path)) { return $m }
    }
    return $null
}

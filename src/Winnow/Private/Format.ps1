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

function Get-WinnowTierSummary {
    <#
    .SYNOPSIS
    Groups findings by tier with totals, in tier order.
    #>
    # Do not wrap the argument in @(): PowerShell 5.1 throws "Argument types do
    # not match" when a wrapped List[object] binds to an untyped parameter.
    param($Findings)

    $groups = New-Object System.Collections.Generic.List[object]
    if (-not $Findings) { return $groups }
    $active = @($Findings | Where-Object { -not $_.Suppressed })

    foreach ($tier in ($script:WinnowTierOrder.Keys | Sort-Object { $script:WinnowTierOrder[$_] })) {
        $items = @($active | Where-Object { $_.Tier -eq $tier } | Sort-Object Bytes -Descending)
        if ($items.Count -eq 0) { continue }
        $bytes = 0
        foreach ($i in $items) { $bytes += $i.Bytes }
        $groups.Add([pscustomobject]@{
            Tier       = $tier
            Items      = $items
            Bytes      = $bytes
            Count      = $items.Count
            Actionable = @($items | Where-Object { Test-WinnowFindingActionable -Finding $_ })
        })
    }
    return $groups
}

function Show-WinnowReport {
    <#
    .SYNOPSIS
    Renders a scan report to the console.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [int]$Top = 8,
        [switch]$All
    )

    $bar = '  ' + ('-' * 74)

    Write-Host ''
    Write-WinnowLine '  Winnow' -Style Accent
    Write-WinnowLine ("  disk reclamation  |  run $($Report.RunId)  |  $($Report.RuleCount) rules  |  $($Report.DurationSec)s") -Style Dim
    Write-Host ''

    # --- Volumes ---------------------------------------------------------
    Write-WinnowLine '  VOLUMES' -Style Head
    foreach ($v in $Report.Volumes) {
        $state = 'ok'
        $style = 'Good'
        if ($v.FreePct -lt 10) { $state = 'critical'; $style = 'Bad' }
        elseif ($v.FreePct -lt 20) { $state = 'low'; $style = 'Warn' }
        $line = '    {0}:  {1} total   {2} free   {3,5:0.0}%   ' -f `
            $v.Letter, (Format-WinnowBytes $v.TotalBytes), (Format-WinnowBytes $v.FreeBytes), $v.FreePct
        Write-WinnowLine $line -Style Normal -NoNewline
        Write-WinnowLine $state -Style $style
    }
    Write-Host ''

    $groups = Get-WinnowTierSummary -Findings $Report.Findings

    $reclaimable = 0
    foreach ($g in $groups) {
        if ($script:WinnowActionableTiers -contains $g.Tier) { $reclaimable += $g.Bytes }
    }

    Write-WinnowLine $bar -Style Dim
    Write-WinnowLine ('  RECLAIMABLE{0}{1}' -f (' ' * 48), (Format-WinnowBytes $reclaimable)) -Style Head
    Write-WinnowLine $bar -Style Dim

    if ($groups.Count -eq 0) {
        Write-WinnowLine '    Nothing found. Either the machine is already tidy, or no rule covers what is using the space.' -Style Dim
        Write-Host ''
    }

    foreach ($g in $groups) {
        $isActionable = ($script:WinnowActionableTiers -contains $g.Tier)
        $label = $g.Tier
        if (-not $isActionable) { $label = $g.Tier + '  (report only)' }

        Write-Host ''
        Write-WinnowLine ('    {0}{1}{2}   {3} item(s)' -f `
            $label, (' ' * [math]::Max(1, 34 - $label.Length)), (Format-WinnowBytes $g.Bytes), $g.Count) `
            -Style $(if ($isActionable) { 'Accent' } else { 'Dim' })

        $show = $g.Items
        if (-not $All -and $g.Items.Count -gt $Top) { $show = @($g.Items[0..($Top - 1)]) }

        foreach ($f in $show) {
            Write-WinnowLine ('      {0}  {1}' -f (Format-WinnowBytes $f.Bytes), $f.Title) -Style Normal
            Write-WinnowLine ('                 {0}' -f (Format-WinnowPath $f.Path)) -Style Dim
            if ($f.Confidence -lt 0.9) {
                Write-WinnowLine ('                 confidence {0:0.00}' -f $f.Confidence) -Style Dim
            }
            foreach ($w in $f.Warnings) {
                Write-WinnowLine ('                 ! {0}' -f $w) -Style Warn
            }
        }
        if (-not $All -and $g.Items.Count -gt $Top) {
            $restBytes = 0
            foreach ($f in $g.Items[$Top..($g.Items.Count - 1)]) { $restBytes += $f.Bytes }
            Write-WinnowLine ('      {0}  ... and {1} more (use -All to list)' -f (Format-WinnowBytes $restBytes), ($g.Items.Count - $Top)) -Style Dim
        }
    }

    # --- Suppressed ------------------------------------------------------
    $supp = @($Report.Findings | Where-Object { $_.Suppressed })
    if ($supp.Count -gt 0) {
        $sb = 0
        foreach ($s in $supp) { $sb += $s.Bytes }
        Write-Host ''
        Write-WinnowLine ('    HELD BACK{0}{1}   {2} item(s)' -f (' ' * 26), (Format-WinnowBytes $sb), $supp.Count) -Style Warn
        foreach ($s in ($supp | Sort-Object Bytes -Descending | Select-Object -First 5)) {
            Write-WinnowLine ('      {0}  {1}' -f (Format-WinnowBytes $s.Bytes), (Format-WinnowPath $s.Path)) -Style Dim
            Write-WinnowLine ('                 {0}' -f $s.SuppressReason) -Style Dim
        }
    }

    if ($Report.RuleErrors -and $Report.RuleErrors.Count -gt 0) {
        Write-Host ''
        Write-WinnowLine '    RULE ERRORS' -Style Bad
        foreach ($e in $Report.RuleErrors) {
            Write-WinnowLine ('      {0}: {1}' -f $e.RuleId, $e.Message) -Style Dim
        }
    }

    Write-Host ''
    Write-WinnowLine $bar -Style Dim
    Write-WinnowLine ('  Reclaimable now: {0}     Nothing has been changed.' -f (Format-WinnowBytes $reclaimable)) -Style Good
    Write-WinnowLine $bar -Style Dim
    Write-Host ''
}

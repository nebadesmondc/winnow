# Rule loading and the scan pipeline.

$script:WinnowRuleDefaults = @{
    Category            = 'AppCache'
    Tier                = 'Rebuildable'
    Contexts            = @('LocalFs')
    Resolve             = @()
    Discover            = $null
    Target              = 'Root'
    Glob                = $null
    Keep                = @()
    Reclaim             = @(@{ Type = 'Delete' })
    MinBytes            = 25MB
    MinAgeDays          = 0
    RequiresClosed      = @()
    RequiresAdmin       = $false
    ExpectsDocuments    = $false
    AllowsInsideProject = @()
    Docs                = $null
    Enabled             = $true
}

function Import-WinnowRule {
    <#
    .SYNOPSIS
    Loads Rules\*.rules.ps1, applies defaults and skips invalid rules,
    including any without a Consequence.
    #>
    [CmdletBinding()]
    param([string]$RulePath, [switch]$Refresh)

    if ($script:WinnowRules -and -not $Refresh -and -not $RulePath) { return $script:WinnowRules }

    if (-not $RulePath) { $RulePath = Join-Path $script:WinnowModuleRoot 'Rules' }
    $rules = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    $packs = @()
    if (Test-WinnowPathExists -Path $RulePath) {
        $packs = @(Get-ChildItem -LiteralPath $RulePath -Filter '*.rules.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    }

    foreach ($pack in $packs) {
        $loaded = $null
        try {
            $loaded = & $pack.FullName
        } catch {
            Write-Warning "Winnow: rule pack '$($pack.Name)' failed to load: $($_.Exception.Message)"
            continue
        }
        foreach ($r in @($loaded)) {
            if ($null -eq $r) { continue }
            if (-not $r.ContainsKey('Id')) {
                Write-Warning "Winnow: a rule in '$($pack.Name)' has no Id and was skipped."
                continue
            }
            if (-not $r.ContainsKey('Consequence') -or [string]::IsNullOrWhiteSpace($r.Consequence)) {
                Write-Warning "Winnow: rule '$($r.Id)' has no Consequence and was skipped (see CONTRIBUTING.md)."
                continue
            }
            if ($seen.ContainsKey($r.Id)) {
                Write-Warning "Winnow: duplicate rule id '$($r.Id)' in '$($pack.Name)' was skipped."
                continue
            }
            if (-not $r.ContainsKey('Title')) { $r.Title = $r.Id }

            foreach ($k in $script:WinnowRuleDefaults.Keys) {
                if (-not $r.ContainsKey($k)) { $r[$k] = $script:WinnowRuleDefaults[$k] }
            }
            if (-not $script:WinnowTierOrder.ContainsKey($r.Tier)) {
                Write-Warning "Winnow: rule '$($r.Id)' has unknown Tier '$($r.Tier)' and was skipped."
                continue
            }

            $seen[$r.Id] = $true
            $rules.Add([pscustomobject]$r)
        }
    }

    $script:WinnowRules = $rules
    return $rules
}

function Invoke-WinnowScan {
    <#
    .SYNOPSIS
    Runs every enabled rule and returns a report object. Changes nothing.
    #>
    [CmdletBinding()]
    param(
        [string[]]$RuleId,
        [switch]$NoProgress
    )

    Reset-WinnowProcessMap
    Reset-WinnowDiscoveryCache

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $started = Get-Date

    $rules = @(Import-WinnowRule)
    if ($RuleId) { $rules = @($rules | Where-Object { $RuleId -contains $_.Id }) }
    $rules = @($rules | Where-Object { $_.Enabled })

    # Tool rules run before detectors and claim their paths, so a cache is
    # never counted by both.
    $rules = @(@($rules | Where-Object { -not $_.Discover }) + @($rules | Where-Object { $_.Discover }))
    $claimed = New-Object System.Collections.Generic.List[string]

    # Apps mid-update are held back for the whole run.
    $inFlight = @(Get-WinnowUpdateInFlight)

    $findings = New-Object System.Collections.Generic.List[object]
    $ruleErrors = New-Object System.Collections.Generic.List[object]
    $i = 0

    foreach ($rule in $rules) {
        $i++
        if (-not $NoProgress) {
            Write-Progress -Activity 'Winnow scan' -Status "$($rule.Title)" `
                -PercentComplete ([int](100 * $i / [math]::Max($rules.Count, 1)))
        }

        $candidates = @()
        try {
            $candidates = @(Select-WinnowUnclaimedCandidate -Candidate @(Get-WinnowRuleCandidate -Rule $rule) -Claimed $claimed)
        } catch {
            $ruleErrors.Add([pscustomobject]@{ RuleId = $rule.Id; Message = $_.Exception.Message })
            continue
        }
        foreach ($c in $candidates) { $claimed.Add($c.Path) }

        foreach ($c in $candidates) {
            try {
                $f = ConvertTo-WinnowFinding -Rule $rule -Candidate $c -RunId $runId -InFlight $inFlight
                if ($f) { $findings.Add($f) }
            } catch {
                $ruleErrors.Add([pscustomobject]@{ RuleId = $rule.Id; Message = $_.Exception.Message })
            }
        }
    }
    if (-not $NoProgress) { Write-Progress -Activity 'Winnow scan' -Completed }

    $volumes = @(Get-WinnowVolumeInfo)

    return [pscustomobject]@{
        Schema      = 'winnow/report/1'
        RunId       = $runId
        StartedUtc  = $started.ToUniversalTime()
        DurationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Machine     = [pscustomobject]@{
            OS        = [System.Environment]::OSVersion.VersionString
            PSVersion = $PSVersionTable.PSVersion.ToString()
            Elevated  = Test-WinnowElevated
        }
        Volumes     = $volumes
        Findings    = $findings
        InFlight    = $inFlight
        RuleErrors  = $ruleErrors
        RuleCount   = $rules.Count
    }
}

function Select-WinnowUnclaimedCandidate {
    <#
    .SYNOPSIS
    Drops candidates that equal, sit inside or contain a claimed path.
    #>
    param(
        [object[]]$Candidate = @(),
        $Claimed
    )

    $out = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Candidate) {
        if ($null -eq $c -or [string]::IsNullOrWhiteSpace($c.Path)) { continue }
        $p = ConvertTo-WinnowFullPath $c.Path
        if (-not $p) { continue }

        $owner = $null
        foreach ($k in @($Claimed)) {
            if ((Test-WinnowPathUnder -Path $p -Root $k) -or (Test-WinnowPathUnder -Path $k -Root $p)) { $owner = $k; break }
        }
        if ($owner) {
            Write-Verbose "Winnow: '$p' overlaps '$owner', which another rule already covers; not counted twice."
            continue
        }
        $c.Path = $p
        $out.Add($c)
    }
    return $out
}

function Get-WinnowRuleCandidate {
    <#
    .SYNOPSIS
    Turns a rule into concrete candidate paths, via Discover or the Resolve chain.
    #>
    param([Parameter(Mandatory)][object]$Rule)

    $out = New-Object System.Collections.Generic.List[object]

    if ($Rule.Discover) {
        foreach ($d in @(& $Rule.Discover)) {
            if ($null -eq $d) { continue }
            if ($d -is [string]) {
                $out.Add([pscustomobject]@{ Path = $d; Strategy = 'Discover'; Detail = 'located by detector'; Extra = $null })
            } else {
                $detail = 'located by detector'
                if ($d.PSObject.Properties['Detail'] -and $d.Detail) { $detail = $d.Detail }
                $extra = $null
                if ($d.PSObject.Properties['Extra']) { $extra = $d.Extra }
                $out.Add([pscustomobject]@{ Path = $d.Path; Strategy = 'Discover'; Detail = $detail; Extra = $extra })
            }
        }
        return $out
    }

    $roots = @(Resolve-WinnowRoot -Resolve $Rule.Resolve -All)
    if ($roots.Count -eq 0) { return $out }
    $activePath = $roots[0].Path

    foreach ($root in $roots) {
        $extra = $null
        if (-not $root.Primary) {
            $extra = [pscustomobject]@{
                Title    = "$($Rule.Title) (old location)"
                Evidence = @("left behind: the cache in use is at $(Format-WinnowPath $activePath)")
            }
        }

        switch ($Rule.Target) {

            'Root' {
                $out.Add([pscustomobject]@{ Path = $root.Path; Strategy = $root.Strategy; Detail = $root.Detail; Extra = $extra; Primary = $root.Primary })
            }

            'Children' {
                foreach ($child in (Get-WinnowChildDirectory -Path $root.Path)) {
                    $keep = $false
                    foreach ($k in @($Rule.Keep)) {
                        if ($k -and $child.Name.Equals($k, [System.StringComparison]::OrdinalIgnoreCase)) { $keep = $true }
                    }
                    if ($keep) { continue }
                    $out.Add([pscustomobject]@{ Path = $child.Path; Strategy = $root.Strategy; Detail = $root.Detail; Extra = $extra; Primary = $root.Primary })
                }
            }

            'Glob' {
                foreach ($f in (Get-WinnowChildFile -Path $root.Path -Filter $Rule.Glob)) {
                    $out.Add([pscustomobject]@{ Path = $f.Path; Strategy = $root.Strategy; Detail = $root.Detail; Extra = $extra; Primary = $root.Primary })
                }
            }
        }
    }
    return $out
}

function ConvertTo-WinnowFinding {
    <#
    .SYNOPSIS
    Measures, guards, interlocks and scores one candidate. Returns $null when
    the candidate does not qualify.
    #>
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Candidate,
        [Parameter(Mandatory)][string]$RunId,
        [object[]]$InFlight = @()
    )

    $path = ConvertTo-WinnowFullPath $Candidate.Path
    if (-not $path) { return $null }
    if (-not (Test-WinnowPathExists -Path $path)) { return $null }

    $evidence = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($Candidate.Detail) { $evidence.Add($Candidate.Detail) }

    # A rule producing a refused path is a bug; logged with -Verbose.
    $verdict = Test-WinnowGuard -Path $path -AllowsInsideProject @($Rule.AllowsInsideProject)
    if (-not $verdict.Allowed) {
        Write-Verbose "Winnow: rule '$($Rule.Id)' produced a guard-refused path: $($verdict.Reason)"
        return $null
    }

    $m = Measure-WinnowTree -Path $path
    if (-not $m.Exists) { return $null }
    if ($m.Bytes -lt $Rule.MinBytes) { return $null }

    if ($Rule.MinAgeDays -gt 0 -and $m.NewestWrite) {
        $ageDays = ((Get-Date).ToUniversalTime() - $m.NewestWrite).TotalDays
        if ($ageDays -lt $Rule.MinAgeDays) { return $null }
        $evidence.Add(('newest file is {0:N0} days old' -f $ageDays))
    }
    $evidence.Add(('{0:N0} file(s)' -f $m.Files))
    if ($m.SkippedLinks -gt 0) { $evidence.Add("$($m.SkippedLinks) junction/symlink(s) not followed") }
    if ($m.DeniedCount -gt 0) { $warnings.Add("$($m.DeniedCount) unreadable subdirector(y/ies) - size is a lower bound") }

    # A program running from the path holds it back.
    $liveNames = $null
    $locks = @(Get-WinnowPathLock -Path $path)
    if ($locks.Count -gt 0) {
        $liveNames = ($locks | Select-Object -ExpandProperty Name -Unique) -join ', '
    }

    $blockedBy = @(Test-WinnowProcessRunning -Name @($Rule.RequiresClosed))
    if ($blockedBy.Count -gt 0) {
        $warnings.Add("requires these to be closed first: $($blockedBy -join ', ')")
    }

    # Open files only make the clean partial; warn, do not hold back.
    if (Test-WinnowTreeLocked -Path $path) {
        $warnings.Add('the owning application is running; close it for a complete reclaim')
    }

    $suppressed = $false
    $suppressReason = $null
    foreach ($f in $InFlight) {
        if (Test-WinnowPathUnder -Path $path -Root $f.Root) {
            $suppressed = $true
            $suppressReason = "an update is in flight for this application ($($f.Evidence))"
            break
        }
    }
    if (-not $suppressed -and $liveNames) {
        $suppressed = $true
        $suppressReason = "in use: $liveNames runs from inside it; close it and scan again"
    }

    # Key material holds the path back for good. ExpectsDocuments relaxes only
    # the documents check.
    $sentinelDocs = $false
    $s = Test-WinnowSentinel -Path $path
    if ($s.Blocked) {
        $suppressed = $true
        $suppressReason = 'never removed: it ' + $s.Reason + ' (' + (($s.Samples | Select-Object -First 3) -join ', ') + ')'
    }
    if ($s.NeedsConfirm -and -not $Rule.ExpectsDocuments) {
        $sentinelDocs = $true
        $warnings.Add($s.Reason)
    }

    $toolMissing = $false
    if ($Rule.Reclaim) {
        foreach ($step in @($Rule.Reclaim)) {
            if ($step.Type -eq 'VendorCli' -and -not (Get-Command -Name $step.Command -ErrorAction SilentlyContinue)) {
                $toolMissing = $true
            }
        }
    }

    $confArgs = @{
        ResolveStrategy = $Candidate.Strategy
        ToolMissing     = $toolMissing
    }
    if ($m.NewestWrite) { $confArgs['NewestWrite'] = $m.NewestWrite }
    if ($sentinelDocs) { $confArgs['SentinelDocuments'] = $true }
    if ($Candidate.Extra -and $Candidate.Extra.PSObject.Properties['InstallNegatives']) {
        $confArgs['InstallNegatives'] = [int]$Candidate.Extra.InstallNegatives
    }
    $conf = Get-WinnowConfidence @confArgs
    foreach ($n in $conf.Notes) { $evidence.Add($n) }

    if ($Candidate.Extra -and $Candidate.Extra.PSObject.Properties['Evidence']) {
        foreach ($e in @($Candidate.Extra.Evidence)) { if ($e) { $evidence.Add($e) } }
    }

    # The vendor command cleans the active cache, so old-location copies are
    # always deleted directly.
    $isLeftBehind = ($Candidate.PSObject.Properties['Primary'] -and -not $Candidate.Primary)

    $action = 'Delete'
    foreach ($step in @($Rule.Reclaim)) {
        if ($step.Type -eq 'VendorCli' -and -not $toolMissing -and -not $isLeftBehind) { $action = 'VendorCli'; break }
        if ($step.Type -eq 'Delete') { $action = 'Delete'; break }
        if ($step.Type -eq 'ReportOnly') { $action = 'ReportOnly'; break }
    }

    $newest = $null
    if ($m.NewestWrite) { $newest = $m.NewestWrite }

    $findingArgs = @{
        Rule       = $Rule
        Path       = $path
        RunId      = $RunId
        Bytes      = $m.Bytes
        Files      = $m.Files
        Evidence   = $evidence
        Warnings   = $warnings
        Confidence = $conf.Score
        Action     = $action
    }
    if ($newest) { $findingArgs['NewestWrite'] = $newest }
    if ($Candidate.Extra -and $Candidate.Extra.PSObject.Properties['Title'] -and $Candidate.Extra.Title) {
        $findingArgs['Title'] = $Candidate.Extra.Title
    }

    $finding = New-WinnowFinding @findingArgs
    $finding.Suppressed = $suppressed
    $finding.SuppressReason = $suppressReason
    return $finding
}

function Test-WinnowElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

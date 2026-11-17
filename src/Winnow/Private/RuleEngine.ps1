# Rule loading and the scan pipeline.

$script:WinnowRuleDefaults = @{
    Resolve             = @()
    Discover            = $null
    Target              = 'Root'
    Glob                = $null
    Keep                = @()
    Reclaim             = @(@{ Type = 'Delete' })
    MinBytes            = 25MB
    MinAgeDays          = 0
    RequiresClosed      = @()
    ExpectsDocuments    = $false
    AllowsInsideProject = @()
    Steps               = @()
    Docs                = $null
    Enabled             = $true
}

function Import-WinnowRule {
    <#
    .SYNOPSIS
    Loads Rules\*.rules.ps1, applies defaults and skips invalid rules,
    including any without a Verdict or a Consequence.
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
            if (-not $r.ContainsKey('Verdict') -or -not $script:WinnowVerdictNames.Contains([string]$r.Verdict)) {
                Write-Warning "Winnow: rule '$($r.Id)' has no valid Verdict and was skipped (see CONTRIBUTING.md)."
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
    Walks the system drive, runs every enabled rule and returns a report
    object with the findings and the space map. Changes nothing.
    #>
    [CmdletBinding()]
    param(
        [string[]]$RuleId,
        [switch]$NoProgress,
        # A folder in place of the system drive; the tests scan a fake one.
        [string]$Root
    )

    Reset-WinnowProcessMap
    Reset-WinnowDiscoveryCache

    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $started = Get-Date
    $driveRoot = Get-WinnowSystemDriveRoot
    if ($Root) { $driveRoot = ConvertTo-WinnowFullPath $Root }
    $walking = Start-WinnowDriveWalk -Root $driveRoot

    $rules = @(Import-WinnowRule)
    if ($RuleId) { $rules = @($rules | Where-Object { $RuleId -contains $_.Id }) }
    $rules = @($rules | Where-Object { $_.Enabled })

    # Tool rules run before detectors and claim their paths, so a cache is
    # never counted by both.
    $rules = @(@($rules | Where-Object { -not $_.Discover }) + @($rules | Where-Object { $_.Discover }))
    $claimed = New-Object System.Collections.Generic.List[string]

    $findings = New-Object System.Collections.Generic.List[object]
    $ruleErrors = New-Object System.Collections.Generic.List[object]

    # Tools are asked for their paths while the drive is walked.
    $resolved = @{}
    foreach ($rule in $rules) {
        if ($rule.Discover) { continue }
        if (-not $NoProgress) { Write-Progress -Activity 'Winnow' -Status "Asking tools: $($rule.Title)" }
        try { $resolved[$rule.Id] = @(Get-WinnowRuleCandidate -Rule $rule) }
        catch { $ruleErrors.Add([pscustomobject]@{ RuleId = $rule.Id; Message = $_.Exception.Message }) }
    }

    # Apps mid-update are held back for the whole run.
    $inFlight = @(Get-WinnowUpdateInFlight)

    while (-not $walking.Task.Wait(250)) {
        if (-not $NoProgress) {
            Write-Progress -Activity 'Winnow' -Status ('Measuring {0}: {1:N0} folders ({2:0} s)' -f `
                $driveRoot, $walking.Progress.Folders, ((Get-Date) - $started).TotalSeconds)
        }
    }
    $walk = $walking.Task.Result
    $script:WinnowWalk = $walk

    foreach ($rule in $rules) {
        if (-not $NoProgress) { Write-Progress -Activity 'Winnow' -Status $rule.Title }
        $candidates = @()
        try {
            if ($rule.Discover) { $raw = @(Get-WinnowRuleCandidate -Rule $rule) }
            elseif ($resolved.ContainsKey($rule.Id)) { $raw = $resolved[$rule.Id] }
            else { continue }
            # Only the system drive is mapped; a cache moved elsewhere is not an item.
            # Folders the walk measured below the rule's minimum are dropped early.
            $raw = @($raw | Where-Object {
                $p = $null
                if ($_.Path) { $p = ConvertTo-WinnowFullPath $_.Path }
                if (-not $p -or -not (Test-WinnowPathUnder -Path $p -Root $driveRoot)) { return $false }
                $e = $walk.Find($p)
                (-not $e) -or ($e.Bytes -ge $rule.MinBytes)
            })
            $candidates = @(Select-WinnowUnclaimedCandidate -Candidate $raw -Claimed $claimed)
        } catch {
            $ruleErrors.Add([pscustomobject]@{ RuleId = $rule.Id; Message = $_.Exception.Message })
            continue
        }
        foreach ($c in $candidates) { $claimed.Add($c.Path) }

        foreach ($c in $candidates) {
            try {
                $f = ConvertTo-WinnowFinding -Rule $rule -Candidate $c -InFlight $inFlight -Walk $walk
                if ($f) { $findings.Add($f) }
            } catch {
                $ruleErrors.Add([pscustomobject]@{ RuleId = $rule.Id; Message = $_.Exception.Message })
            }
        }
    }
    if (-not $NoProgress) { Write-Progress -Activity 'Winnow' -Completed }

    $report = [pscustomobject]@{
        Schema      = 'winnow/report/2'
        RunId       = $runId
        StartedUtc  = $started.ToUniversalTime()
        DurationSec = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        Machine     = [pscustomobject]@{
            OS        = [System.Environment]::OSVersion.VersionString
            PSVersion = $PSVersionTable.PSVersion.ToString()
            Elevated  = Test-WinnowElevated
        }
        Drive       = $driveRoot
        Volumes     = @(Get-WinnowVolumeInfo)
        Findings    = $findings
        Map         = (Get-WinnowSpaceMap -Walk $walk -Findings $findings -DriveRoot $driveRoot)
        Walk        = [pscustomobject]@{
            Seconds      = [math]::Round($walk.Seconds, 1)
            Files        = $walk.Files
            Folders      = $walk.FolderCount
            Unreadable   = $walk.Denied.Count
            LinksSkipped = $walk.LinksSkipped
        }
        InFlight    = $inFlight
        RuleErrors  = $ruleErrors
        RuleCount   = $rules.Count
    }
    $script:WinnowLastReport = $report
    return $report
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
                $out.Add([pscustomobject]@{ Path = $d; Strategy = 'Discover'; Detail = $null; Extra = $null })
            } else {
                $detail = $null
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

function Get-WinnowExtra {
    # A detector's optional per-candidate value, or $null.
    param($Candidate, [string]$Name)
    if ($Candidate.Extra -and $Candidate.Extra.PSObject.Properties[$Name]) { return $Candidate.Extra.$Name }
    return $null
}

function ConvertTo-WinnowFinding {
    <#
    .SYNOPSIS
    Measures one candidate and, when it could be removed, guards it, checks
    for live use and scans it for keys. Returns $null when the candidate does
    not qualify.
    #>
    param(
        [Parameter(Mandatory)][object]$Rule,
        [Parameter(Mandatory)][object]$Candidate,
        [object[]]$InFlight = @(),
        [object]$Walk
    )

    $path = ConvertTo-WinnowFullPath $Candidate.Path
    if (-not $path) { return $null }

    $toolMissing = $null
    foreach ($step in @($Rule.Reclaim)) {
        if ($step.Type -eq 'VendorCli' -and -not (Get-Command -Name $step.Command -ErrorAction SilentlyContinue)) {
            $toolMissing = $step.Command
        }
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

    $verdict = $Rule.Verdict
    $removable = Test-WinnowFindingRemovable -Verdict $verdict -Action $action

    $entry = $null
    if ($Walk) { $entry = $Walk.Find($path) }
    if (-not $entry) {
        $m = Measure-WinnowTree -Path $path
        if (-not $m.Exists) { return $null }
        $entry = [pscustomobject]@{
            Bytes = $m.Bytes; FreeableBytes = $m.Bytes; Files = $m.Files
            NewestWriteUtc = $m.NewestWrite; Denied = $m.DeniedCount
        }
    }
    if ($entry.Bytes -lt $Rule.MinBytes) { return $null }

    # A rule producing a refused path is a bug; logged with -Verbose.
    if ($removable) {
        $g = Test-WinnowGuard -Path $path -AllowsInsideProject @($Rule.AllowsInsideProject)
        if (-not $g.Allowed) {
            Write-Verbose "Winnow: rule '$($Rule.Id)' produced a guard-refused path: $($g.Reason)"
            return $null
        }
    }

    $evidence = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    if ($Candidate.Detail) { $evidence.Add($Candidate.Detail) }

    $newest = $null
    if ($entry.NewestWriteUtc -and $entry.NewestWriteUtc -gt [datetime]::MinValue) { $newest = $entry.NewestWriteUtc }
    if ($Rule.MinAgeDays -gt 0 -and $newest) {
        $ageDays = ((Get-Date).ToUniversalTime() - $newest).TotalDays
        if ($ageDays -lt $Rule.MinAgeDays) { return $null }
        $evidence.Add(('newest file is {0:N0} days old' -f $ageDays))
    }
    if ($entry.Files -gt 1) { $evidence.Add(('{0:N0} files' -f $entry.Files)) }
    if ($entry.FreeableBytes -lt $entry.Bytes * 0.9) {
        $evidence.Add(('some files here are hard-linked from elsewhere; removing it frees about {0}' -f (Format-WinnowBytes $entry.FreeableBytes).Trim()))
    }
    if ($entry.PSObject.Properties['Denied'] -and $entry.Denied -gt 0) {
        $warnings.Add("$($entry.Denied) folder(s) inside could not be read; the size is a lower bound")
    }
    if ($toolMissing) { $evidence.Add("$toolMissing is not on PATH; removal deletes the folder directly") }
    foreach ($e in @(Get-WinnowExtra $Candidate 'Evidence')) { if ($e) { $evidence.Add($e) } }

    $requiresClosed = @(@($Rule.RequiresClosed) + @(Get-WinnowExtra $Candidate 'RequiresClosed') | Where-Object { $_ })
    $suppressReason = $null
    if ($removable) {
        $s = Test-WinnowSentinel -Path $path -Walk $Walk
        if ($s.Blocked) {
            $suppressReason = 'never removed: it ' + $s.Reason
            if ($s.Samples) { $suppressReason += ' (' + ($s.Samples -join ', ') + ')' }
        } else {
            $suppressReason = Get-WinnowHoldReason -Path $path -RequiresClosed $requiresClosed -InFlight $InFlight
        }
        if ($s.NeedsConfirm -and -not $Rule.ExpectsDocuments -and $verdict -eq 'Clean') {
            $verdict = 'YourCall'
            $warnings.Add($s.Reason)
        }
        if (-not $suppressReason -and (Test-WinnowTreeLocked -Path $path)) {
            $warnings.Add('some files are open; close the app that owns them for a complete removal')
        }
    }

    $findingArgs = @{
        Rule           = $Rule
        Path           = $path
        Bytes          = $entry.Bytes
        FreeableBytes  = $entry.FreeableBytes
        Files          = $entry.Files
        Evidence       = $evidence
        Warnings       = $warnings
        Verdict        = $verdict
        Action         = $action
        RequiresClosed = $requiresClosed
    }
    if ($newest) { $findingArgs['NewestWrite'] = $newest }
    foreach ($k in @('Title', 'Id', 'Steps')) {
        $v = Get-WinnowExtra $Candidate $k
        if ($v) { $findingArgs[$k] = $v }
    }

    $finding = New-WinnowFinding @findingArgs
    if ($suppressReason) {
        $finding.Suppressed = $true
        $finding.SuppressReason = $suppressReason
    }
    return $finding
}

function Test-WinnowElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

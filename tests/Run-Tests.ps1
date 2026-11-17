# Winnow test suite. No Pester: Windows ships Pester 3.4, incompatible with 5.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Run-Tests.ps1

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Detail',
    Justification = 'Read by Test-Case through script scope.')]
param([switch]$Detail)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Failures = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Pass++
        if ($Detail) { Write-Host "  ok   $Name" -ForegroundColor DarkGray }
    } catch {
        $script:Fail++
        $script:Failures.Add("$Name  ==>  $($_.Exception.Message)")
        Write-Host "  FAIL $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

function Assert-True { param($Value, $Message = 'expected true')  if (-not $Value) { throw $Message } }
function Assert-False { param($Value, $Message = 'expected false') if ($Value) { throw $Message } }
function Assert-Equal {
    param($Expected, $Actual, $Message)
    if ($Expected -ne $Actual) {
        if (-not $Message) { $Message = "expected '$Expected', got '$Actual'" }
        throw $Message
    }
}

# --------------------------------------------------------------------------
$moduleDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Winnow'
$toolsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'tools'
$manifest = Join-Path $moduleDir 'Winnow.psd1'

# Module and launcher sources
function Get-ShippedSource {
    $files = @(Get-ChildItem -LiteralPath $moduleDir -Include '*.ps1', '*.psm1', '*.psd1', '*.cs' -Recurse -File)
    if (Test-Path -LiteralPath $toolsDir) {
        $files += @(Get-ChildItem -LiteralPath $toolsDir -Include '*.ps1', '*.cmd' -Recurse -File)
    }
    return $files
}

# Fails listing every file:pattern hit
function Assert-NoPattern {
    param([string[]]$Pattern, [string]$What, [string[]]$ExceptFile = @())
    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ShippedSource)) {
        if ($ExceptFile -contains $f.Name) { continue }
        $text = Get-Content -LiteralPath $f.FullName -Raw
        foreach ($p in $Pattern) {
            if ($text -match $p) { $offenders.Add("$($f.Name): $p") }
        }
    }
    if ($offenders.Count -gt 0) { throw ("$What -> " + ($offenders -join '; ')) }
}

Write-Host ''
Write-Host 'Winnow test suite' -ForegroundColor Cyan
Write-Host ''

# ==========================================================================
Write-Host 'STRUCTURE' -ForegroundColor White
# ==========================================================================

Test-Case 'module manifest exists' { Assert-True (Test-Path $manifest) 'Winnow.psd1 not found' }

Test-Case 'module imports cleanly' {
    Import-Module $manifest -Force -ErrorAction Stop
    Assert-True ([bool](Get-Command Start-Winnow -ErrorAction SilentlyContinue)) 'Start-Winnow not exported'
}

Test-Case 'only the four intended commands are exported' {
    $exported = (Get-Module Winnow).ExportedFunctions.Keys | Sort-Object
    $expected = @('Get-WinnowReport', 'Get-WinnowRule', 'Invoke-WinnowClean', 'Start-Winnow')
    Assert-Equal ($expected -join ',') (($exported) -join ',')
}

Test-Case 'the delete primitive is not exported' {
    Assert-False ([bool](Get-Command Remove-WinnowPath -ErrorAction SilentlyContinue)) 'Remove-WinnowPath is reachable from a session'
}

Test-Case 'no delete API exists outside Remove-Safely.ps1' {
    Assert-NoPattern -What 'deletion APIs found outside the chokepoint' -ExceptFile @('Remove-Safely.ps1') -Pattern @(
        'Remove-Item',
        '\[System\.IO\.File\]::Delete',
        '\[System\.IO\.Directory\]::Delete',
        '\brd /s',
        '\bdel /',
        'rm -rf',
        '\.Delete\(\)',
        '(?i)\brobocopy\b',
        '(?i)\bMove-Item\b',
        '(?i)\bClear-Content\b',
        '\bFile\.Delete\(', '\bDirectory\.Delete\(', '(?i)DeleteFile', '(?i)DeleteDirectory',
        '(?i)RemoveDirectory', '(?i)MoveFile', '(?i)SendToRecycleBin'
    )
}

Test-Case 'the native walker only lists folders' {
    $cs = Get-Content -LiteralPath (Join-Path $moduleDir 'Private\SpaceWalker.cs') -Raw
    foreach ($p in @('GENERIC_WRITE', '0x40000000', 'GENERIC_ALL', 'DELETE\b', 'WriteFile', 'DeviceIoControl',
                     'SetFileInformation', 'SetFileAttributes', 'SetEndOfFile', 'CreateDirectory', 'Process\.Start')) {
        if ($cs -cmatch $p) { throw "SpaceWalker.cs uses '$p'" }
    }
    $opens = [regex]::Matches($cs, 'CreateFileW\(')
    $listOnly = [regex]::Matches($cs, 'CreateFileW\([^,]+, FILE_LIST_DIRECTORY,')
    Assert-Equal ($opens.Count - 1) $listOnly.Count 'a CreateFileW call opens something other than a folder listing'
}

Test-Case 'no network API exists anywhere Winnow ships' {
    Assert-NoPattern -What 'network APIs found' -Pattern @(
        '(?i)Invoke-WebRequest', '(?i)Invoke-RestMethod', '(?i)\biwr\b', '(?i)\birm\b',
        '(?i)Net\.WebClient', '(?i)System\.Net\.Http', '(?i)HttpClient', '(?i)WebRequest\]',
        '(?i)Net\.Sockets', '(?i)TcpClient', '(?i)UdpClient', '(?i)Net\.Dns', '(?i)Resolve-DnsName',
        '(?i)Start-BitsTransfer', '(?i)\bbitsadmin\b', '(?i)DownloadString', '(?i)DownloadFile',
        '(?i)\bcurl(\.exe)?\b', '(?i)\bwget\b', '(?i)Test-NetConnection', '(?i)Send-MailMessage',
        '(?i)\bSystem\.Net\b', '(?i)WebRequest'
    )
}

Test-Case 'no elevation, service or scheduled-task API exists anywhere Winnow ships' {
    Assert-NoPattern -What 'privileged or persistent APIs found' -Pattern @(
        '(?i)RunAs', '(?i)\bgsudo\b', '(?i)\bsudo\b',
        '(?i)Register-ScheduledTask', '(?i)\bschtasks\b', '(?i)New-Service', '(?i)\bsc(\.exe)?\s+create\b',
        '(?i)Set-ExecutionPolicy', '(?i)\breg(\.exe)?\s+(add|delete|import)\b',
        '(?i)(Set|New|Remove)-ItemProperty'
    )
}

Test-Case 'tools Winnow asks run offline, from the profile folder' {
    $m = Get-Module Winnow
    $envLine = & $m { Invoke-WinnowCli -Command 'cmd' -Arguments '/d /c set NO_UPDATE_NOTIFIER' }
    Assert-Equal 'NO_UPDATE_NOTIFIER=1' $envLine 'a child process was started with update checks on'
    $pipLine = & $m { Invoke-WinnowCli -Command 'cmd' -Arguments '/d /c set PIP_DISABLE_PIP_VERSION_CHECK' }
    Assert-Equal 'PIP_DISABLE_PIP_VERSION_CHECK=1' $pipLine 'pip would check for updates'
    $cwd = & $m { Invoke-WinnowCli -Command 'cmd' -Arguments '/d /c cd' }
    Assert-Equal ([System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')) $cwd 'a child process ran from the current folder, where a project config could change its answer'
}

Test-Case 'no rule pack contains a literal drive or user path' {
    $offenders = New-Object System.Collections.Generic.List[string]
    foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $moduleDir 'Rules') -Filter '*.ps1' -File)) {
        $text = Get-Content -LiteralPath $f.FullName -Raw
        if ($text -match '[A-Za-z]:\\') { $offenders.Add("$($f.Name): literal drive letter") }
        if ($text -match '(?i)\\Users\\') { $offenders.Add("$($f.Name): literal Users path") }
    }
    if ($offenders.Count -gt 0) { throw ($offenders -join '; ') }
}

Test-Case 'every rule states a consequence' {
    foreach ($r in (Get-WinnowRule)) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($r.Consequence)) "rule '$($r.Id)' has no consequence"
    }
}

Test-Case 'rules loaded' {
    $n = @(Get-WinnowRule).Count
    Assert-True ($n -ge 10) "expected at least 10 rules, loaded $n"
}

Test-Case 'no rule asks for administrator rights' {
    $rules = & (Get-Module Winnow) { Import-WinnowRule -Refresh }
    foreach ($r in $rules) {
        Assert-False ([bool]$r.RequiresAdmin) "rule '$($r.Id)' requires admin; admin steps must be explained, never run"
    }
}

# ==========================================================================
Write-Host ''
Write-Host 'GUARD - must refuse' -ForegroundColor White
# ==========================================================================

# Private functions are called in module scope.
$M = Get-Module Winnow
function Guard { param([string]$P, [string[]]$Allow = @())
    return & $M { param($p, $a) Test-WinnowGuard -Path $p -AllowsInsideProject $a } $P $Allow
}

$win  = $env:WINDIR
$pf   = $env:ProgramFiles
$prof = $env:USERPROFILE
$lad  = $env:LOCALAPPDATA
$ad   = $env:APPDATA
$sysDrive = $env:SystemDrive

$mustRefuse = @(
    @{ P = $win;                                        Why = 'the Windows directory' }
    @{ P = (Join-Path $win 'System32');                  Why = 'System32' }
    @{ P = (Join-Path $win 'WinSxS');                    Why = 'the component store' }
    @{ P = (Join-Path $win 'Temp');                      Why = 'Windows Temp' }
    @{ P = (Join-Path $win 'SoftwareDistribution');      Why = 'the Windows Update cache' }
    @{ P = (Join-Path $win 'System32\DriverStore');      Why = 'the driver store' }
    @{ P = (Join-Path $win 'Installer');                 Why = 'the MSI cache' }
    @{ P = $pf;                                          Why = 'Program Files' }
    @{ P = (Join-Path $pf 'Git');                        Why = 'an installed program' }
    @{ P = (Join-Path $env:ProgramData 'Package Cache'); Why = 'MSI repair sources' }
    @{ P = "$sysDrive\";                                 Why = 'a drive root' }
    @{ P = "$sysDrive\Users";                            Why = 'the users root' }
    @{ P = "$sysDrive\pagefile.sys";                     Why = 'the page file' }
    @{ P = "$sysDrive\hiberfil.sys";                     Why = 'the hibernation file' }
    @{ P = "$sysDrive\swapfile.sys";                     Why = 'the swap file' }
    @{ P = "$sysDrive\`$Recycle.Bin";                    Why = 'the recycle bin' }
    @{ P = "$sysDrive\System Volume Information";        Why = 'volume metadata' }
    @{ P = "$sysDrive\Recovery";                         Why = 'recovery data' }
    @{ P = "$sysDrive\Windows.old";                      Why = 'a previous Windows install' }
    @{ P = $prof;                                        Why = 'the user profile root' }
    @{ P = (Join-Path $prof 'Documents');                Why = 'Documents' }
    @{ P = (Join-Path $prof 'Documents\taxes');          Why = 'inside Documents' }
    @{ P = (Join-Path $prof 'Desktop');                  Why = 'the Desktop' }
    @{ P = (Join-Path $prof 'Downloads');                Why = 'Downloads' }
    @{ P = (Join-Path $prof 'Downloads\thing.zip');      Why = 'a file in Downloads' }
    @{ P = (Join-Path $prof 'Pictures');                 Why = 'Pictures' }
    @{ P = (Join-Path $prof 'Videos');                   Why = 'Videos' }
    @{ P = (Join-Path $prof 'OneDrive');                 Why = 'a cloud sync root' }
    @{ P = (Join-Path $prof 'OneDrive\work\plan.docx');  Why = 'a file inside OneDrive' }
    @{ P = (Join-Path $prof '.ssh');                     Why = 'SSH keys' }
    @{ P = (Join-Path $prof '.ssh\id_rsa');              Why = 'a private key' }
    @{ P = (Join-Path $prof '.aws');                     Why = 'AWS credentials' }
    @{ P = (Join-Path $prof '.aws\credentials');         Why = 'a credentials file' }
    @{ P = (Join-Path $prof '.kube');                    Why = 'kube config' }
    @{ P = (Join-Path $prof '.gnupg');                   Why = 'GPG keys' }
    @{ P = (Join-Path $prof '.azure');                   Why = 'Azure credentials' }
    @{ P = (Join-Path $lad 'thing\secret.pem');          Why = 'a PEM file' }
    @{ P = (Join-Path $lad 'thing\vault.kdbx');          Why = 'a password database' }
    @{ P = (Join-Path $lad 'thing\cert.pfx');            Why = 'a certificate' }
    @{ P = (Join-Path $lad 'thing\.env');                Why = 'an env file' }
    @{ P = $lad;                                         Why = 'an allow-root itself' }
    @{ P = $ad;                                          Why = 'an allow-root itself' }
    @{ P = $env:TEMP;                                    Why = 'an allow-root itself' }
    @{ P = (Join-Path $lad '..\..\..\Windows\System32');  Why = 'traversal into Windows' }
    @{ P = (Join-Path $lad 'a\..\..\..\..\Program Files'); Why = 'traversal into Program Files' }
    @{ P = '\\server\share\folder';                      Why = 'a network share' }
    @{ P = '\\?\GLOBALROOT\Device\Harddisk0';            Why = 'a device namespace path' }
    @{ P = '';                                           Why = 'an empty path' }
    @{ P = 'relative\thing';                             Why = 'a relative path outside allow roots' }
)

foreach ($case in $mustRefuse) {
    $p = $case.P
    $why = $case.Why
    $body = {
        $v = Guard $p
        Assert-False $v.Allowed "guard ALLOWED '$p' (reason given: $($v.Reason))"
    }.GetNewClosure()
    Test-Case -Name "refuses $why" -Body $body
}

# ==========================================================================
Write-Host ''
Write-Host 'GUARD - must permit' -ForegroundColor White
# ==========================================================================

$mustAllow = @(
    @{ P = (Join-Path $lad 'uv\cache');            Why = 'a tool cache under LOCALAPPDATA' }
    @{ P = (Join-Path $lad 'npm-cache');           Why = 'the npm cache' }
    @{ P = (Join-Path $lad 'SomeApp\Code Cache');  Why = 'an app cache directory' }
    @{ P = (Join-Path $prof '.gradle\caches');     Why = 'the Gradle cache' }
    @{ P = (Join-Path $env:TEMP 'leftover-dir');   Why = 'a child of TEMP' }
    @{ P = (Join-Path $ad 'SomeApp\logs');         Why = 'app logs under APPDATA' }
)

foreach ($case in $mustAllow) {
    $p = $case.P
    $why = $case.Why
    $body = {
        $v = Guard $p
        Assert-True $v.Allowed "guard REFUSED '$p': $($v.Reason)"
    }.GetNewClosure()
    Test-Case -Name "permits $why" -Body $body
}

# ==========================================================================
Write-Host ''
Write-Host 'GUARD - fixture behaviour' -ForegroundColor White
# ==========================================================================

$sandbox = Join-Path $lad ('winnow-selftest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

Test-Case 'refuses a path inside a source project, permits a named build dir' {
    $proj = Join-Path $sandbox 'myproject'
    [void](New-Item -ItemType Directory -Path (Join-Path $proj '.git') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $proj 'node_modules') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $proj 'src') -Force)

    $v1 = Guard (Join-Path $proj 'src')
    Assert-False $v1.Allowed 'guard allowed a source directory inside a git project'

    $v2 = Guard (Join-Path $proj 'node_modules')
    Assert-False $v2.Allowed 'node_modules was allowed without the rule opting in'

    $v3 = Guard (Join-Path $proj 'node_modules') @('node_modules')
    Assert-True $v3.Allowed "an opted-in build directory was refused: $($v3.Reason)"

    $v4 = Guard $proj @('node_modules')
    Assert-False $v4.Allowed 'the project root itself was allowed'
}

Test-Case 'refuses a junction and anything reached through one' {
    $target = Join-Path $sandbox 'real-target'
    $link = Join-Path $sandbox 'the-link'
    [void](New-Item -ItemType Directory -Path (Join-Path $target 'inner') -Force)
    $mk = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'mklink', '/J', "`"$link`"", "`"$target`"") `
            -NoNewWindow -Wait -PassThru
    if ($mk.ExitCode -ne 0) { Write-Host '       (skipped: could not create a junction)' -ForegroundColor DarkGray; return }

    $v1 = Guard $link
    Assert-False $v1.Allowed 'guard allowed a junction'

    $v2 = Guard (Join-Path $link 'inner')
    Assert-False $v2.Allowed 'guard allowed a path reached through a junction'
}

Test-Case 'sentinel blocks a directory containing key material' {
    $d = Join-Path $sandbox 'fake-cache'
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d 'server.pem') -Encoding ascii -Value @(
        '-----BEGIN PRIVATE KEY-----', 'bm90IGEgcmVhbCBrZXk=', '-----END PRIVATE KEY-----')
    $s = & $M { param($p) Test-WinnowSentinel -Path $p } $d
    Assert-True $s.Blocked 'sentinel did not block key material'
}

Test-Case 'sentinel does not mistake a certificate bundle for a secret' {
    $d = Join-Path $sandbox 'wheel-cache\certifi'
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d 'cacert.pem') -Encoding ascii -Value @(
        '-----BEGIN CERTIFICATE-----', 'TUlJQmN6Q0NBUm1nQXdJQkFnSVVCdz09', '-----END CERTIFICATE-----')
    $s = & $M { param($p) Test-WinnowSentinel -Path $p } (Join-Path $sandbox 'wheel-cache')
    Assert-False $s.Blocked "a public certificate bundle was treated as a secret: $($s.Reason)"
}

Test-Case 'a folder holding key material is shown as held back, never removable' {
    $d = Join-Path $sandbox 'keyed-cache'
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d 'client.pem') -Encoding ascii -Value @(
        '-----BEGIN RSA PRIVATE KEY-----', 'bm90IGEgcmVhbCBrZXk=', '-----END RSA PRIVATE KEY-----')
    $rule = [pscustomobject]@{
        Id = 'test.keyed'; Title = 'test item'; Category = 'AppCache'; Tier = 'Transient'
        MinBytes = 0; MinAgeDays = 0; RequiresClosed = @(); AllowsInsideProject = @()
        ExpectsDocuments = $true; Reclaim = @(@{ Type = 'Delete' }); Consequence = 'test only'
        Docs = $null; RequiresAdmin = $false
    }
    $cand = [pscustomobject]@{ Path = $d; Strategy = 'Env'; Detail = 'test'; Extra = $null }
    $f = & $M { param($r, $c) Reset-WinnowProcessMap; ConvertTo-WinnowFinding -Rule $r -Candidate $c -RunId 'test' } $rule $cand
    Assert-True ($null -ne $f) 'the folder vanished from the report instead of being explained'
    Assert-True ($f.Suppressed -and $f.SuppressReason -match 'never removed') "not held back as never removable: $($f.SuppressReason)"
    $act = & $M { param($x) Test-WinnowFindingActionable -Finding $x } $f
    Assert-False $act 'a folder holding key material was actionable (ExpectsDocuments must not relax the key check)'
}

Test-Case 'measurement does not follow junctions' {
    $target = Join-Path $sandbox 'measure-target'
    $host1 = Join-Path $sandbox 'measure-host'
    [void](New-Item -ItemType Directory -Path $target -Force)
    [void](New-Item -ItemType Directory -Path $host1 -Force)
    $fs = New-Object byte[] 200000
    [System.IO.File]::WriteAllBytes((Join-Path $target 'blob.bin'), $fs)
    $mk = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'mklink', '/J', "`"$(Join-Path $host1 'link')`"", "`"$target`"") `
            -NoNewWindow -Wait -PassThru
    if ($mk.ExitCode -ne 0) { Write-Host '       (skipped: could not create a junction)' -ForegroundColor DarkGray; return }

    $m = & $M { param($p) Measure-WinnowTree -Path $p } $host1
    Assert-Equal 0 $m.Files 'measurement counted files through a junction'
    Assert-True ($m.SkippedLinks -ge 1) 'measurement did not record a skipped link'
}

Test-Case 'sizes are space on disk, and a hard-linked file counts once' {
    $d = Join-Path $sandbox 'hardlinks'
    [void](New-Item -ItemType Directory -Path (Join-Path $d 'second') -Force)
    $a = Join-Path $d 'a.bin'
    [System.IO.File]::WriteAllBytes($a, (New-Object byte[] 300000))
    [void](New-Item -ItemType HardLink -Path (Join-Path $d 'second\b.bin') -Target $a)

    $one = & $M { param($p) Measure-WinnowTree -Path $p } $a
    Assert-True ($one.Bytes -ge 300000 -and $one.Bytes -lt 400000) "a 300000-byte file measured $($one.Bytes) bytes on disk"

    $w = & $M { param($p) [Winnow.SpaceWalker]::Walk((New-WinnowWalkOptions -Root $p -KeepMinBytes 0 -KeepDepth 5)) } $d
    Assert-Equal $one.Bytes ([double]$w.Bytes) 'a file with two names was counted twice'
    $second = $w.Find((Join-Path $d 'second'))
    Assert-Equal ([math]::Floor($one.Bytes / 2)) ([double]$second.Bytes) 'the second name did not get half the file'
    Assert-Equal 0 ([double]$second.FreeableBytes) 'deleting one name was reported as freeing the file'
    Assert-Equal $one.Bytes ([double]$w.Find($d).FreeableBytes) 'deleting both names was not reported as freeing the file'
}

Test-Case 'sentinel blocks a folder that holds a virtual disk' {
    $d = Join-Path $sandbox 'disk-cache'
    [void](New-Item -ItemType Directory -Path $d -Force)
    Set-Content -LiteralPath (Join-Path $d 'machine.vhdx') -Value 'not a disk' -Encoding ascii
    $s = & $M { param($p) Test-WinnowSentinel -Path $p } $d
    Assert-True $s.Blocked 'a folder holding a virtual disk was not blocked'
    Assert-True ($s.Reason -match 'virtual disk') "unexpected reason: $($s.Reason)"
}

Test-Case 'lock detection sees a held file, and stops seeing it when released' {
    $d = Join-Path $sandbox 'locked-cache'
    [void](New-Item -ItemType Directory -Path $d -Force)
    $file = Join-Path $d 'held.bin'
    Set-Content -LiteralPath $file -Value 'payload' -Encoding ascii

    $free = & $M { param($p) Test-WinnowTreeLocked -Path $p } $d
    Assert-False $free 'reported a lock on an unheld tree'

    $fs = [System.IO.File]::Open($file, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $held = & $M { param($p) Test-WinnowTreeLocked -Path $p } $d
        Assert-True $held 'did not detect a file held with FileShare.None'
    } finally {
        $fs.Close(); $fs.Dispose()
    }

    $after = & $M { param($p) Test-WinnowTreeLocked -Path $p } $d
    Assert-False $after 'still reported a lock after release'
}

Test-Case 'the delete primitive refuses a guard-denied path' {
    $r = & $M { param($p) Remove-WinnowPath -Path $p -Confirm:$false } (Join-Path $env:WINDIR 'System32')
    Assert-False $r.Removed 'the delete primitive acted on System32'
    Assert-True ($r.Reason -match 'guard refused') "unexpected refusal reason: $($r.Reason)"
    Assert-True (Test-Path (Join-Path $env:WINDIR 'System32')) 'System32 is gone; this is very bad'
}

Test-Case 'the delete primitive removes a permitted path' {
    $d = Join-Path $sandbox 'deleteme'
    [void](New-Item -ItemType Directory -Path (Join-Path $d 'nested') -Force)
    Set-Content -LiteralPath (Join-Path $d 'nested\f.txt') -Value 'x' -Encoding ascii
    $r = & $M { param($p) Remove-WinnowPath -Path $p -Confirm:$false } $d
    Assert-True $r.Removed "permitted path was not removed: $($r.Reason)"
    Assert-False (Test-Path $d) 'path still exists after a reported removal'
}

Test-Case 'SkipGuard is refused outside the test fixture root' {
    $threw = $false
    try {
        & $M { param($p) Remove-WinnowPath -Path $p -SkipGuard -Confirm:$false } (Join-Path $env:WINDIR 'System32')
    } catch { $threw = $true }
    Assert-True $threw 'SkipGuard was accepted outside the fixture root'
    Assert-True (Test-Path (Join-Path $env:WINDIR 'System32')) 'System32 is gone; this is very bad'
}

# ==========================================================================
Write-Host ''
Write-Host 'REMOVAL AND REPORTING' -ForegroundColor White
# ==========================================================================

# Minimal rule for driving the pipeline directly
$fakeRule = [pscustomobject]@{
    Id = 'test.fake'; Title = 'test item'; Category = 'AppCache'; Tier = 'Transient'
    MinBytes = 0; MinAgeDays = 0; RequiresClosed = @(); AllowsInsideProject = @()
    ExpectsDocuments = $false; Reclaim = @(@{ Type = 'Delete' }); Consequence = 'test only'
    Docs = $null; RequiresAdmin = $false
}

Test-Case 'last-resort purge handles a path with spaces and stays inside it' {
    # Unquoted arguments once split 'User Data' and mirrored over 'User';
    # robocopy /MIR follows junctions inside the target even with /XJ.
    $base    = Join-Path $sandbox 'robo'
    $target  = Join-Path $base 'User Data\Default\Cache'
    $decoy   = Join-Path $base 'User'
    $outside = Join-Path $sandbox 'robo-outside'
    [void](New-Item -ItemType Directory -Path (Join-Path $target 'nested') -Force)
    [void](New-Item -ItemType Directory -Path $decoy -Force)
    [void](New-Item -ItemType Directory -Path $outside -Force)
    Set-Content -LiteralPath (Join-Path $target 'nested\blob.bin') -Value 'cache' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $decoy 'keep.txt') -Value 'keep' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $base 'User Data\keep.txt') -Value 'keep' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value 'keep' -Encoding ascii
    $mk = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'mklink', '/J', "`"$(Join-Path $target 'link')`"", "`"$outside`"") `
            -NoNewWindow -Wait -PassThru

    $err = & $M { param($p) Invoke-WinnowMirrorPurge -Path $p } $target

    Assert-False (Test-Path -LiteralPath $target) "the target survived the purge: $err"
    Assert-True (Test-Path -LiteralPath (Join-Path $decoy 'keep.txt')) 'a sibling folder named like the first word of the path was purged'
    Assert-True (Test-Path -LiteralPath (Join-Path $base 'User Data\keep.txt')) 'the parent of the target was touched'
    if ($mk.ExitCode -eq 0) {
        Assert-True (Test-Path -LiteralPath (Join-Path $outside 'precious.txt')) 'the purge followed a junction out of the target'
    } else {
        Write-Host '       (junction half skipped: could not create a junction)' -ForegroundColor DarkGray
    }
}

Test-Case 'removing a tree that contains a junction leaves what it points to alone' {
    $tree    = Join-Path $sandbox 'linked-cache'
    $outside = Join-Path $sandbox 'linked-outside'
    [void](New-Item -ItemType Directory -Path (Join-Path $tree 'deep\er') -Force)
    [void](New-Item -ItemType Directory -Path $outside -Force)
    Set-Content -LiteralPath (Join-Path $tree 'deep\er\c.bin') -Value 'cache' -Encoding ascii
    Set-Content -LiteralPath (Join-Path $outside 'precious.txt') -Value 'keep' -Encoding ascii
    $mk = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/c', 'mklink', '/J', "`"$(Join-Path $tree 'deep\link')`"", "`"$outside`"") `
            -NoNewWindow -Wait -PassThru
    if ($mk.ExitCode -ne 0) { Write-Host '       (skipped: could not create a junction)' -ForegroundColor DarkGray; return }

    $r = & $M { param($p) Remove-WinnowPath -Path $p -Confirm:$false } $tree
    Assert-True $r.Removed "the tree was not removed: $($r.Reason)"
    Assert-True (Test-Path -LiteralPath (Join-Path $outside 'precious.txt')) 'removal followed a junction out of the tree'
}

Test-Case 'last-resort purge asks the guard itself' {
    $err = & $M { param($p) Invoke-WinnowMirrorPurge -Path $p } (Join-Path $env:WINDIR 'System32')
    Assert-True ($err -match 'guard refused') "the purge did not refuse System32: $err"
    Assert-True (Test-Path (Join-Path $env:WINDIR 'System32')) 'System32 is gone; this is very bad'
}

Test-Case 'freed space is measured on disk, not copied from the scan' {
    $d = Join-Path $sandbox 'measured'
    [void](New-Item -ItemType Directory -Path (Join-Path $d 'sub') -Force)
    [System.IO.File]::WriteAllBytes((Join-Path $d 'a.bin'), (New-Object byte[] 300000))
    [System.IO.File]::WriteAllBytes((Join-Path $d 'sub\b.bin'), (New-Object byte[] 100000))
    $onDisk = (& $M { param($p) Measure-WinnowTree -Path $p } $d).Bytes
    Assert-True ($onDisk -ge 400000) "400000 bytes of files measured $onDisk on disk"
    $r = & $M { param($p) Remove-WinnowPath -Path $p -Confirm:$false } $d
    Assert-True $r.Removed "not removed: $($r.Reason)"
    Assert-Equal $onDisk ([double]$r.BytesClaimed) "reported $($r.BytesClaimed) bytes freed for $onDisk on disk"
    Assert-Equal 0 ([double]$r.BytesLeft) 'reported bytes left over after a full removal'
}

Test-Case 'a cache left at its old location is found, and a nested hit counts once' {
    $active  = Join-Path $sandbox 'resolve\active'
    $oldBase = Join-Path $sandbox 'resolve\oldbase'
    [void](New-Item -ItemType Directory -Path (Join-Path $active 'inner') -Force)
    [void](New-Item -ItemType Directory -Path (Join-Path $oldBase 'cache') -Force)
    $env:WINNOW_TEST_ACTIVE = $active
    $env:WINNOW_TEST_OLDBASE = $oldBase
    try {
        $chain = @(
            @{ Type = 'Env'; Name = 'WINNOW_TEST_ACTIVE' }
            @{ Type = 'Env'; Name = 'WINNOW_TEST_ACTIVE'; Sub = 'inner' }
            @{ Type = 'Path'; Base = 'WINNOW_TEST_OLDBASE'; Sub = 'cache' }
        )
        $hits = @(& $M { param($c) Resolve-WinnowRoot -Resolve $c -All } $chain)
        Assert-Equal 2 $hits.Count "expected the active and the old location, got $($hits.Count)"
        Assert-True $hits[0].Primary 'the active location is not marked as the one in use'
        Assert-False $hits[1].Primary 'the old location is marked as the one in use'
        Assert-True ($hits[1].Path -like '*\oldbase\cache') "unexpected second location: $($hits[1].Path)"

        $first = & $M { param($c) Resolve-WinnowRoot -Resolve $c } $chain
        Assert-Equal $hits[0].Path $first.Path 'the single-answer lookup changed'
    } finally {
        [Environment]::SetEnvironmentVariable('WINNOW_TEST_ACTIVE', $null, 'Process')
        [Environment]::SetEnvironmentVariable('WINNOW_TEST_OLDBASE', $null, 'Process')
    }
}

Test-Case 'an old-location copy is deleted directly, never via the vendor command' {
    $old = Join-Path $sandbox 'old-copy'
    [void](New-Item -ItemType Directory -Path $old -Force)
    Set-Content -LiteralPath (Join-Path $old 'x.bin') -Value 'x' -Encoding ascii
    $rule = $fakeRule.PSObject.Copy()
    $rule.Reclaim = @(@{ Type = 'VendorCli'; Command = 'cmd'; Args = '/d /c exit 0' }, @{ Type = 'Delete' })
    $cand = [pscustomobject]@{ Path = $old; Strategy = 'Path'; Detail = 'test'; Extra = $null; Primary = $false }
    $f = & $M { param($r, $c) Reset-WinnowProcessMap; ConvertTo-WinnowFinding -Rule $r -Candidate $c -RunId 'test' } $rule $cand
    Assert-Equal 'Delete' $f.Action 'an old-location copy would be handed to the vendor command'
}

Test-Case 'overlapping paths from different rules are counted once' {
    $claimed = New-Object System.Collections.Generic.List[string]
    $claimed.Add('C:\x\owned')
    $cands = @(
        [pscustomobject]@{ Path = 'C:\x\owned' }
        [pscustomobject]@{ Path = 'C:\x\owned\inside' }
        [pscustomobject]@{ Path = 'C:\x' }
        [pscustomobject]@{ Path = 'C:\x\owned-not' }
        [pscustomobject]@{ Path = 'C:\x\other' }
    )
    $kept = @(& $M { param($c, $k) Select-WinnowUnclaimedCandidate -Candidate $c -Claimed $k } $cands $claimed)
    Assert-Equal 'C:\x\owned-not,C:\x\other' (($kept | ForEach-Object { $_.Path }) -join ',')
}

Test-Case 'a folder a running program executes from is held back, not hidden' {
    # One running process: the result has no .Count unless wrapped in @().
    $app = Join-Path $sandbox 'liveapp'
    [void](New-Item -ItemType Directory -Path $app -Force)
    $exe = Join-Path $app 'winnow-test-live.exe'
    [System.IO.File]::Copy((Join-Path $env:WINDIR 'System32\cmd.exe'), $exe)
    $p = $null
    try { $p = Start-Process -FilePath $exe -ArgumentList '/d', '/k' -WindowStyle Hidden -PassThru } catch { }
    if (-not $p) { Write-Host '       (skipped: could not start a test process)' -ForegroundColor DarkGray; return }
    try {
        # The image path is unreadable for a moment after start.
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            $gp = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
            if ($gp -and $gp.Path) { break }
            Start-Sleep -Milliseconds 100
        }
        $cand = [pscustomobject]@{ Path = $app; Strategy = 'Env'; Detail = 'test'; Extra = $null }
        $f = & $M { param($r, $c) Reset-WinnowProcessMap; ConvertTo-WinnowFinding -Rule $r -Candidate $c -RunId 'test' } $fakeRule $cand
        Assert-True ($null -ne $f) 'the in-use folder vanished from the report'
        Assert-True $f.Suppressed 'the in-use folder was not held back'
        Assert-True ($f.SuppressReason -match 'winnow-test-live') "the reason does not name the program: $($f.SuppressReason)"
        $act = & $M { param($x) Test-WinnowFindingActionable -Finding $x } $f
        Assert-False $act 'an in-use folder was actionable'
    } finally {
        if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) }
        & $M { Reset-WinnowProcessMap }
    }
}

Test-Case 'choosing a held-back item says why, not that it is missing' {
    $f = & $M {
        param($r)
        $x = New-WinnowFinding -Rule $r -Path 'C:\nowhere\held' -RunId 'test' -Bytes 1MB
        $x.Suppressed = $true
        $x.SuppressReason = 'an update is in flight for this application'
        $x
    } $fakeRule
    $report = [pscustomobject]@{ RunId = 'test'; Findings = @($f); Volumes = @() }
    $w = $null
    Invoke-WinnowClean -Report $report -Id $f.Id -Quiet -WarningVariable w -WarningAction SilentlyContinue | Out-Null
    $text = ($w | ForEach-Object { "$_" }) -join ' '
    Assert-True ($text -match 'held back: an update is in flight') "unexpected warning: $text"
    Assert-False ($text -match 'not present|not in (this|the)') "still says the id is missing: $text"
}

# ==========================================================================
Write-Host ''
Write-Host 'SCAN' -ForegroundColor White
# ==========================================================================

# One full scan, shared by the tests below.
Write-Host '  (scanning once, reused by the tests below)' -ForegroundColor DarkGray
$scan = Get-WinnowReport -AsObject

Test-Case 'a scan produces a report and changes nothing' {
    Assert-Equal 'winnow/report/1' $scan.Schema
    Assert-True ($scan.Volumes.Count -ge 1) 'no volumes reported'
    Assert-True ($null -ne $scan.Findings) 'no findings collection'
    Assert-Equal 0 $scan.RuleErrors.Count "scan reported rule errors: $(($scan.RuleErrors | ForEach-Object { $_.RuleId + ': ' + $_.Message }) -join '; ')"
}

Test-Case 'every path a rule produced is accepted by the guard' {
    foreach ($f in $scan.Findings) {
        $v = Guard $f.Path @($f.AllowsInsideProject)
        Assert-True $v.Allowed "rule '$($f.RuleId)' produced a guard-refused path '$($f.Path)': $($v.Reason)"
    }
}

Test-Case 'no space is counted twice: no finding sits inside another' {
    $paths = @($scan.Findings | ForEach-Object { $_.Path.TrimEnd('\') })
    for ($i = 0; $i -lt $paths.Count; $i++) {
        for ($j = 0; $j -lt $paths.Count; $j++) {
            if ($i -eq $j) { continue }
            $a = $paths[$i]; $b = $paths[$j]
            if ($a.Equals($b, [System.StringComparison]::OrdinalIgnoreCase) -or
                $a.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "'$a' is counted, and so is '$b' which contains it"
            }
        }
    }
}

Test-Case 'every finding carries a consequence and a tier' {
    foreach ($f in $scan.Findings) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($f.Consequence)) "finding $($f.Id) has no consequence"
        Assert-True ($null -ne $f.Tier) "finding $($f.Id) has no tier"
    }
}

Test-Case 'no finding is tiered UserData or SystemManaged and also actionable' {
    foreach ($f in $scan.Findings) {
        if ($f.Tier -eq 'UserData' -or $f.Tier -eq 'SystemManaged') {
            $act = & $M { param($x) Test-WinnowFindingActionable -Finding $x } $f
            Assert-False $act "a $($f.Tier) finding was actionable"
        }
    }
}

Test-Case 'Invoke-WinnowClean -WhatIf changes nothing' {
    $before = (Get-PSDrive -Name ($env:SystemDrive.Substring(0, 1))).Free
    Invoke-WinnowClean -Report $scan -WhatIf -Quiet | Out-Null
    $after = (Get-PSDrive -Name ($env:SystemDrive.Substring(0, 1))).Free
    # Allows for background churn.
    Assert-True ([math]::Abs($after - $before) -lt 200MB) 'free space moved during a WhatIf run'
}

# Teardown
if (Test-Path $sandbox) {
    Get-ChildItem -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
        ForEach-Object { [void](Start-Process cmd.exe -ArgumentList @('/d', '/c', 'rmdir', "`"$($_.FullName)`"") -NoNewWindow -Wait) }
    [System.IO.Directory]::Delete($sandbox, $true)
}

# ==========================================================================
Write-Host ''
Write-Host ('-' * 60)
if ($script:Fail -eq 0) {
    Write-Host ("PASS   $($script:Pass) test(s)") -ForegroundColor Green
} else {
    Write-Host ("FAIL   $($script:Fail) of $($script:Pass + $script:Fail) test(s)") -ForegroundColor Red
    foreach ($f in $script:Failures) { Write-Host "  $f" -ForegroundColor DarkGray }
}
Write-Host ''
exit $script:Fail

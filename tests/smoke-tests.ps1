# smoke-tests.ps1 - dependency-free smoke tests for dsh-launcher.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tests\smoke-tests.ps1
# Exit code 0 = all passed, 1 = something failed.
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path | Split-Path -Parent
$MainScript = Join-Path $RepoRoot 'src\Start-Harness.ps1'
$passed = 0; $failed = 0

function Assert {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { $script:passed++; Write-Host "  [PASS] $Name" }
  else { $script:failed++; Write-Host "  [FAIL] $Name" }
}

Write-Host '== 1. syntax check =='
foreach ($f in @($MainScript, (Join-Path $RepoRoot 'src\Start-HotkeyListener.ps1'))) {
  $tokens = $null; $errors = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
  Assert -Name ("parse " + (Split-Path $f -Leaf) + " errors=0") -Cond ($errors.Count -eq 0)
}

# load the main script's pure functions via the AST
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($MainScript, [ref]$tokens, [ref]$errors)
$ScriptDir = Join-Path $RepoRoot 'src'
$DataDir = Join-Path $RepoRoot 'data'
$LogDir = Join-Path $DataDir 'logs'
$LauncherConfigFile = Join-Path $DataDir 'harness-config.json'
$DefaultHarnessRoot = Join-Path $env:USERPROFILE 'deepseek-harness'
$PortConfigFile = Join-Path $DataDir 'harness-port-config.txt'
$OptionsFile = Join-Path $DataDir 'harness-options.txt'
$Port = 3080
$NoPopup = $true
$DshRoot = ''
function Log($m) { }
# load the i18n table ($I18n = @{...}) so T() works in tests
$i18nAst = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.VariablePath.UserPath -eq 'I18n' }, $true)
if ($i18nAst) { Invoke-Expression $i18nAst.Extent.Text }
$Lang = 'zh'
$loadNames = 'Test-VersionAtLeast','Get-NodeVersion','Get-PnpmVersion','Get-LocalHarnessVersion','Test-PortListening','Get-AvailablePorts','Test-PortIsMajorService','Load-PortConfig','Save-PortConfig','Get-LauncherOptions','Save-LauncherOptions','Get-VersionNoticeOption','Set-VersionNoticeOption','Get-LanguageOption','Set-LanguageOption','Get-WarmupOption','Set-WarmupOption','Get-StopPromptOption','Set-StopPromptOption','Get-WarmupStartupCommand','Set-WarmupStartup','Test-IsHarnessRoot','Resolve-HarnessRoot','Get-ProgressState','T','Get-BytesSha256','Clean-Logs','Get-GitHubCommitSha','Update-HarnessSource','Get-PreviousHarnessBackup','Restore-PreviousHarness','Confirm-HarnessUpdate','Start-HarnessOnce','Test-HarnessProcessCommandLine','Stop-StaleHarnessProcesses','Test-ServiceStartLocked','Get-RunningHarnessPort','Get-PortOwnerPids','Ensure-NodeAndPnpm','Get-HarnessWebviewTargets','Test-ValidPortInput'
foreach ($name in $loadNames) {
  $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
  if (-not $fn) { Assert -Name ("function exists: " + $name) -Cond $false; continue }
  Invoke-Expression $fn.Extent.Text
  Assert -Name ("function loads: " + $name) -Cond $true
}

Write-Host '== 2. version compare =='
Assert -Name '24.18.0 >= 22.19.0' -Cond (Test-VersionAtLeast '24.18.0' '22.19.0')
Assert -Name '22.18.0 < 22.19.0' -Cond (-not (Test-VersionAtLeast '22.18.0' '22.19.0'))
Assert -Name '0.1.0-rc.5 < 0.1.0-rc.6' -Cond (-not (Test-VersionAtLeast '0.1.0-rc.5' '0.1.0-rc.6'))
Assert -Name '0.2.0 >= 0.1.9' -Cond (Test-VersionAtLeast '0.2.0' '0.1.9')

Write-Host '== 3. harness root detection =='
# portable: passes on machines that have a harness AND on machines that don't
$foundRoot = Resolve-HarnessRoot
if ($foundRoot) {
  Assert -Name 'harness root auto-detected (package.json identity)' -Cond $true
  Assert -Name 'detected root is a real harness' -Cond (Test-IsHarnessRoot $foundRoot)
} else {
  Assert -Name 'no harness source on this machine (detection skipped)' -Cond $true
}
Assert -Name 'random folder rejected' -Cond (-not (Test-IsHarnessRoot $RepoRoot))

Write-Host '== 4. port scan =='
$MajorServicePorts = @(80,443,8080,3306,5432,7897,27017)
$Port = 3080
$avail = Get-AvailablePorts -Count 10 -StartAt 4000
Assert -Name 'scan returns 10 free ports' -Cond ($avail.Count -eq 10)
Assert -Name 'no major-service ports leaked' -Cond (@($avail | Where-Object { $MajorServicePorts -contains $_ }).Count -eq 0)
Assert -Name 'no occupied ports leaked' -Cond (@($avail | Where-Object { Test-PortListening -PortNumber $_ }).Count -eq 0)

Write-Host '== 5. config roundtrip (data dir) =='
$tmpCfg = Join-Path $env:TEMP 'smoke-port-cfg.txt'; $tmpOpt = Join-Path $env:TEMP 'smoke-opt.txt'
Remove-Item $tmpCfg, $tmpOpt -Force -ErrorAction SilentlyContinue
$PortConfigFile = $tmpCfg; $OptionsFile = $tmpOpt
Save-PortConfig 4321 $true
$c = Load-PortConfig
Assert -Name 'port config roundtrip' -Cond ($c.Port -eq 4321 -and $c.Remember)
Set-VersionNoticeOption $false
Assert -Name 'version-notice option roundtrip' -Cond (-not (Get-VersionNoticeOption))
Set-WarmupOption $true
Assert -Name 'warmup option roundtrip (default off, can be enabled)' -Cond (Get-WarmupOption)
Set-WarmupOption $false
Assert -Name 'warmup option back to off' -Cond (-not (Get-WarmupOption))
Set-StopPromptOption $false
Assert -Name 'stop-prompt option roundtrip (default on, can be suppressed)' -Cond (-not (Get-StopPromptOption))
Set-StopPromptOption $true
Assert -Name 'stop-prompt option back to on' -Cond (Get-StopPromptOption)
Remove-Item $tmpCfg, $tmpOpt -Force -ErrorAction SilentlyContinue

Write-Host '== 5b. warm-up startup command =='
$wc = Get-WarmupStartupCommand
Assert -Name 'warmup cmd: launches wscript + vbs + -WarmupOnly -NoPopup (hidden)' -Cond (($wc -match 'wscript') -and ($wc -match 'Start-Harness\.vbs') -and ($wc -match '-WarmupOnly') -and ($wc -match '-NoPopup'))

Write-Host '== 6. progress state (average ETA) =='
$st = Get-ProgressState -Elapsed 30 -PortUp $false -HttpUp $false -MedianTotal 60 -MedianPortToReady 0 -PortUpElapsed 0 -HistoryCount 2 -LogActive $true -Failed $false -FailMsg '' -TimeoutSeconds 180
Assert -Name 'phase-1 with history shows ETA' -Cond ($st.Eta -match '30')
$st2 = Get-ProgressState -Elapsed 30 -PortUp $false -HttpUp $false -MedianTotal 0 -MedianPortToReady 0 -PortUpElapsed 0 -HistoryCount 0 -LogActive $true -Failed $false -FailMsg '' -TimeoutSeconds 180
Assert -Name 'no-history is indeterminate (marquee)' -Cond $st2.Marquee

Write-Host '== 7. i18n =='
$Lang = 'zh'
Assert -Name 'i18n zh lookup' -Cond ((T 'portOk') -eq '确认使用')
Assert -Name 'i18n in-use port hint (selectable, not blocking)' -Cond ((T 'portInUseWarn') -match '已使用中')
$Lang = 'en'
Assert -Name 'i18n en lookup' -Cond ((T 'portOk') -eq 'Use Port')
Assert -Name 'i18n missing key fallback' -Cond ((T 'noSuchKey') -eq 'noSuchKey')

Write-Host '== 8. supply-chain hash + log rotation =='
# SHA-256('abc') is a well-known constant -> verifies the PS5.1-compatible hash path
$knownSha = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
Assert -Name "SHA-256('abc') matches known constant" -Cond ((Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes('abc'))) -eq $knownSha)
# log rotation with a stubbed Test-PortListening (environment-independent)
function Test-PortListening { param([int]$PortNumber = 0, [int]$TimeoutMs = 500) $script:tpResult }
$script:tpResult = $false
$savedLogDir = $LogDir
$LogDir = Join-Path $env:TEMP ('smoke-logtest-' + [guid]::NewGuid().ToString('N'))
$LogRetentionDays = 7; $LogMaxSizeMB = 5
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$oldF = Join-Path $LogDir 'old.log'; Set-Content -Path $oldF -Value 'old'
(Get-Item $oldF).LastWriteTime = (Get-Date).AddDays(-10)
$bigF = Join-Path $LogDir 'big.log'; [System.IO.File]::WriteAllBytes($bigF, (New-Object byte[] (6MB)))
$smallF = Join-Path $LogDir 'small.log'; Set-Content -Path $smallF -Value 'x'
$webF = Join-Path $LogDir 'harness-web.out.log'; [System.IO.File]::WriteAllBytes($webF, (New-Object byte[] (6MB)))
Clean-Logs
Assert -Name 'log rotation: old log removed' -Cond (-not (Test-Path $oldF))
Assert -Name 'log rotation: oversized rotated to .1' -Cond ((Test-Path ($bigF + '.1')) -and (Test-Path $smallF))
Assert -Name 'log rotation: web log rotated when svc down' -Cond (Test-Path ($webF + '.1'))
Remove-Item $LogDir -Recurse -Force
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$webF2 = Join-Path $LogDir 'harness-web.err.log'; [System.IO.File]::WriteAllBytes($webF2, (New-Object byte[] (6MB)))
$script:tpResult = $true
Clean-Logs
Assert -Name 'log rotation: web log kept when svc up' -Cond ((Test-Path $webF2) -and -not (Test-Path ($webF2 + '.1')))
Remove-Item $LogDir -Recurse -Force -ErrorAction SilentlyContinue
$LogDir = $savedLogDir
# legacy logs folder (<project root>\logs = parent of ScriptDir) removed when unlocked
$savedScriptDir = $ScriptDir
$legacyTmp = Join-Path $env:TEMP ('smoke-legacy-' + [guid]::NewGuid().ToString('N'))
$ScriptDir = Join-Path $legacyTmp 'src'
New-Item -ItemType Directory -Path (Join-Path $legacyTmp 'logs') -Force | Out-Null
Set-Content -Path (Join-Path $legacyTmp 'logs\old.log') -Value 'x'
$script:tpResult = $false
Clean-Logs
Assert -Name 'log rotation: legacy logs folder removed when unlocked' -Cond (-not (Test-Path (Join-Path $legacyTmp 'logs')))
Remove-Item $legacyTmp -Recurse -Force -ErrorAction SilentlyContinue
$ScriptDir = $savedScriptDir

Write-Host '== 9. supply-chain update path (network stubbed) =='
# real constants from the main script
$uAst = [System.Management.Automation.Language.Parser]::ParseFile($MainScript, [ref]$null, [ref]$null)
foreach ($cn in 'GithubApi','GithubCodeloadBase','GithubCodeload') {
  $a = $uAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.VariablePath.UserPath -eq $cn }, $true) | Select-Object -First 1
  if ($a) { Invoke-Expression $a.Extent.Text }
}
# stubs: no network in tests
$script:stubSha = 'a' * 40
$script:stubApiPkg = ''
$script:stubDownloadUri = ''
function Get-GitHubCommitSha { return $script:stubSha }
function Invoke-WebRequest { param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing, [int]$TimeoutSec) $script:stubDownloadUri = $Uri; Copy-Item $script:stubZip $OutFile -Force }
function Invoke-RestMethod { param([string]$Uri, [int]$TimeoutSec, $Headers) return @{ content = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script:stubApiPkg)) } }
# fake harness zips (UTF-8 no BOM, mirroring GitHub files)
$tmp9 = Join-Path $env:TEMP ('smoke-upd-' + [guid]::NewGuid().ToString('N'))
$fakeSrc = Join-Path $tmp9 'fake-harness'
New-Item -ItemType Directory -Path $fakeSrc -Force | Out-Null
$noBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $fakeSrc 'package.json'), '{"name":"@deepseek-ai/dsh-root","version":"9.0.0-V1"}', $noBom)
$zipV1 = Join-Path $tmp9 'v1.zip'; Compress-Archive -Path $fakeSrc -DestinationPath $zipV1 -Force
[System.IO.File]::WriteAllText((Join-Path $fakeSrc 'package.json'), '{"name":"@deepseek-ai/dsh-root","version":"9.0.0-EVIL"}', $noBom)
$zipV2 = Join-Path $tmp9 'v2.zip'; Compress-Archive -Path $fakeSrc -DestinationPath $zipV2 -Force
# A: honest download -> verified + swapped + backed up
$savedLogDir = $LogDir
$LogDir = Join-Path $tmp9 'a\logs'; New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$StagingDir = Join-Path $tmp9 'a\staging'
$PreflightStateFile = Join-Path $tmp9 'a\state.txt'
$DshRoot = Join-Path $tmp9 'a\old-harness'
New-Item -ItemType Directory -Path $DshRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $DshRoot 'package.json'), '{"old":true}', $noBom)
$script:stubZip = $zipV1
$script:stubApiPkg = '{"name":"@deepseek-ai/dsh-root","version":"9.0.0-V1"}'
Assert -Name 'update: verified download swaps source' -Cond ((Update-HarnessSource) -and ((Get-Content (Join-Path $DshRoot 'package.json') -Raw) -match 'V1'))
Assert -Name 'update: download pinned to commit sha' -Cond ($script:stubDownloadUri -eq ($GithubCodeloadBase + '/' + $script:stubSha))
Assert -Name 'update: old source backed up to .bak-*' -Cond ([bool](Get-ChildItem (Join-Path $tmp9 'a\old-harness.bak-*') -Directory -ErrorAction SilentlyContinue))
# B: tampered download -> abort, nothing touched
$LogDir = Join-Path $tmp9 'b\logs'; New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$StagingDir = Join-Path $tmp9 'b\staging'
$PreflightStateFile = Join-Path $tmp9 'b\state.txt'
$DshRoot = Join-Path $tmp9 'b\old-harness'
New-Item -ItemType Directory -Path $DshRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $DshRoot 'package.json'), '{"old":true}', $noBom)
$script:stubZip = $zipV2
$script:stubApiPkg = '{"name":"@deepseek-ai/dsh-root","version":"9.0.0-V1"}'
Assert -Name 'update: tampered download aborts' -Cond (-not (Update-HarnessSource))
Assert -Name 'update: tamper leaves old source untouched' -Cond ((Get-Content (Join-Path $DshRoot 'package.json') -Raw) -match 'old')
# C: no SHA (network degraded) -> fallback URL, still swaps
$LogDir = Join-Path $tmp9 'c\logs'; New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$StagingDir = Join-Path $tmp9 'c\staging'
$PreflightStateFile = Join-Path $tmp9 'c\state.txt'
$DshRoot = Join-Path $tmp9 'c\old-harness'
New-Item -ItemType Directory -Path $DshRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $DshRoot 'package.json'), '{"old":true}', $noBom)
$script:stubZip = $zipV1
$script:stubSha = ''
Assert -Name 'update: degraded mode falls back and swaps' -Cond ((Update-HarnessSource) -and ($script:stubDownloadUri -eq $GithubCodeload))
Remove-Item $tmp9 -Recurse -Force -ErrorAction SilentlyContinue
$LogDir = $savedLogDir

Write-Host '== 10. rollback safety net =='
$tmp10 = Join-Path $env:TEMP ('smoke-rb-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp10 -Force | Out-Null
$noBom = New-Object System.Text.UTF8Encoding($false)
# previous (working) version lives in a pending .bak-* backup; the new version
# at $DshRoot is broken
$oldV = Join-Path $tmp10 'old-harness'
New-Item -ItemType Directory -Path $oldV -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $oldV 'package.json'), '{"name":"@deepseek-ai/dsh-root","version":"0.9.0-OLD"}', $noBom)
$savedDshRoot = $DshRoot
$DshRoot = Join-Path $tmp10 'harness'
New-Item -ItemType Directory -Path $DshRoot -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $DshRoot 'package.json'), '{"name":"@deepseek-ai/dsh-root","version":"2.0.0-NEW-BROKEN"}', $noBom)
Rename-Item $oldV (Join-Path $tmp10 'harness.bak-20260816120000')
Assert -Name 'rollback: pending backup detected' -Cond ([bool](Get-PreviousHarnessBackup))
Assert -Name 'rollback: restore swaps broken -> previous version' -Cond ((Restore-PreviousHarness) -and ((Get-Content (Join-Path $DshRoot 'package.json') -Raw) -match '0.9.0-OLD'))
Assert -Name 'rollback: broken new source kept as .failed-*' -Cond ([bool](Get-ChildItem $tmp10 -Directory -Filter 'harness.failed-*'))
$StagingDir = Join-Path $tmp10 'staging'
Confirm-HarnessUpdate
Assert -Name 'rollback: confirm removes .failed-* leftover' -Cond (-not [bool](Get-ChildItem $tmp10 -Directory -Filter 'harness.failed-*'))
# no backup for another dir -> restore returns false
$DshRoot2 = Join-Path $tmp10 'fresh'
New-Item -ItemType Directory -Path $DshRoot2 -Force | Out-Null
[System.IO.File]::WriteAllText((Join-Path $DshRoot2 'package.json'), '{"x":1}', $noBom)
$DshRoot = $DshRoot2
Assert -Name 'rollback: no backup -> restore returns false' -Cond (-not (Restore-PreviousHarness))
$DshRoot = Join-Path $tmp10 'harness'
# confirm with a pending .bak removes it too
New-Item -ItemType Directory -Path (Join-Path $tmp10 'harness.bak-20260816130000') -Force | Out-Null
Confirm-HarnessUpdate
Assert -Name 'rollback: confirm removes pending .bak backup' -Cond (-not (Test-Path (Join-Path $tmp10 'harness.bak-20260816130000')))
Remove-Item $tmp10 -Recurse -Force -ErrorAction SilentlyContinue
$DshRoot = $savedDshRoot

Write-Host '== 11. scoped process cleanup (never touch unrelated processes) =='
# launcher predicate: with a known root only root processes match
$savedRoot = $DshRoot
$DshRoot = 'C:\harness-root'
Assert -Name 'kill-scope: root process matched' -Cond (Test-HarnessProcessCommandLine 'node C:\harness-root\node_modules\.bin\dsh web')
Assert -Name 'kill-scope: unrelated node process ignored' -Cond (-not (Test-HarnessProcessCommandLine 'node D:\other-project\server.js'))
Assert -Name 'kill-scope: dsh CLI entry under root matched' -Cond (Test-HarnessProcessCommandLine 'node C:\harness-root\apps\cli\src\bin.ts')
$DshRoot = ''
Assert -Name 'kill-scope: no root -> unrelated still ignored' -Cond (-not (Test-HarnessProcessCommandLine 'node D:\other-project\server.js'))
Assert -Name 'kill-scope: no root -> exact dsh CLI entry matched' -Cond (Test-HarnessProcessCommandLine 'node C:\x\apps\cli\src\bin.ts')
Assert -Name 'kill-scope: no root -> bare harness-path (non-CLI) NOT matched (no mis-kill)' -Cond (-not (Test-HarnessProcessCommandLine 'node D:\x\deepseek-harness\worker.js'))
$DshRoot = $savedRoot
# listener helper: scoped over a stubbed process list
$lAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src\Start-HotkeyListener.ps1'), [ref]$null, [ref]$null)
$lfn = $lAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-HarnessNodeProcesses' }, $true) | Select-Object -First 1
if ($lfn) { Invoke-Expression $lfn.Extent.Text }
function Get-CimInstance { param([string]$Filter) return @(
  [pscustomobject]@{ CommandLine = 'node C:\harness-root\apps\cli\src\bin.ts' },
  [pscustomobject]@{ CommandLine = 'node D:\other-project\server.js' },
  [pscustomobject]@{ CommandLine = 'node C:\unrelated\apps\cli\src\bin.ts' }
) }
$script:ListenerRoot = 'C:\harness-root'
$lp1 = @(Get-HarnessNodeProcesses)
Assert -Name 'listener kill-scope: root + any dsh CLI entry matched, unrelated ignored' -Cond ($lp1.Count -eq 2 -and -not ($lp1 | Where-Object { $_.CommandLine -match 'other-project' }))
$script:ListenerRoot = ''
$lp2 = @(Get-HarnessNodeProcesses)
Assert -Name 'listener kill-scope: fallback = dsh CLI entries only' -Cond ($lp2.Count -eq 2 -and -not ($lp2 | Where-Object { $_.CommandLine -match 'other-project' }))

Write-Host '== 12. concurrent-start race guard (never spawn a 2nd instance) =='
# stub the detection predicates and forbid Start-Process entirely
function Test-HarnessUp { return $script:raceHttpUp }
function Test-PortListening { param([int]$PortNumber = 0, [int]$TimeoutMs = 500) return $script:racePortUp }
function Test-ServiceProcess { return $script:raceProcUp }
function Start-Process { throw 'Start-Process must NOT be called - would spawn a 2nd instance' }
$savedLogDir = $LogDir
$LogDir = Join-Path $env:TEMP ('smoke-race-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$OutLog = Join-Path $LogDir 'out.log'; $ErrLog = Join-Path $LogDir 'err.log'
$ServicePidFile = Join-Path $LogDir 'svc.pid'; $PortUpMarker = Join-Path $LogDir 'port.marker'
$StartLockFile = Join-Path $LogDir 'service-start.running'
$DshRoot = Join-Path $env:TEMP ('smoke-race-root-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $DshRoot -Force | Out-Null
$Port = 3080
$script:raceHttpUp = $false; $script:racePortUp = $true; $script:raceProcUp = $false
Assert -Name 'race guard: port already up -> returns starting, no spawn' -Cond ((Start-HarnessOnce) -eq 'starting')
$script:raceHttpUp = $false; $script:racePortUp = $false; $script:raceProcUp = $true
Assert -Name 'race guard: process already up -> returns starting, no spawn' -Cond ((Start-HarnessOnce) -eq 'starting')
$script:raceHttpUp = $true; $script:racePortUp = $false; $script:raceProcUp = $false
Assert -Name 'race guard: http already up -> returns ready, no spawn' -Cond ((Start-HarnessOnce) -eq 'ready')
Remove-Item function:Start-Process -ErrorAction SilentlyContinue   # restore the real cmdlet for later tests
Remove-Item $LogDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $DshRoot -Recurse -Force -ErrorAction SilentlyContinue
$LogDir = $savedLogDir

Write-Host '== 13. service start lock (single-instance guarantee) =='
$savedLogDir = $LogDir
$LogDir = Join-Path $env:TEMP ('smoke-lock-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$StartLockFile = Join-Path $LogDir 'service-start.running'
Assert -Name 'start lock: absent -> unlocked' -Cond (-not (Test-ServiceStartLocked))
[System.IO.File]::WriteAllText($StartLockFile, [string]$PID)
Assert -Name 'start lock: own pid -> self-lock never blocks' -Cond (-not (Test-ServiceStartLocked))
[System.IO.File]::WriteAllText($StartLockFile, '999999999')
Assert -Name 'start lock: stale (dead) lock -> unlocked + removed' -Cond ((-not (Test-ServiceStartLocked)) -and (-not (Test-Path $StartLockFile)))
$helper = Start-Process powershell -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 30') -WindowStyle Hidden -PassThru
try {
  [System.IO.File]::WriteAllText($StartLockFile, [string]$helper.Id)
  Assert -Name 'start lock: held by another live process -> locked' -Cond (Test-ServiceStartLocked)
} finally {
  Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
}
Remove-Item $LogDir -Recurse -Force -ErrorAction SilentlyContinue
$LogDir = $savedLogDir

Write-Host '== 14. launcher actual-port detection (port-independent) =='
$DshRoot = ''   # root-scoping falls back to the exact dsh CLI entry
# Get-RunningHarnessPort must extract the real --port from a running dsh process
function Get-CimInstance { param([string]$Filter) return @([pscustomobject]@{ CommandLine = 'node --import tsx/esm apps/cli/src/bin.ts "web" "--port" "3099"' }) }
Assert -Name 'launcher port: extracts actual port from the process' -Cond ((Get-RunningHarnessPort) -eq 3099)
function Get-CimInstance { param([string]$Filter) return @() }
Assert -Name 'launcher port: no process -> 0' -Cond ((Get-RunningHarnessPort) -eq 0)

Write-Host '== 15. hard-stop: port owner discovery (netstat, no CIM) =='
Assert -Name 'hard-stop: free port has no owner' -Cond ((@(Get-PortOwnerPids 39999)).Count -eq 0)
$is3081Up = $false
try { $null = Invoke-WebRequest -Uri 'http://127.0.0.1:3081' -UseBasicParsing -TimeoutSec 1; $is3081Up = $true } catch {}
if ($is3081Up) {
  Assert -Name 'hard-stop: running service port owner discovered' -Cond ((@(Get-PortOwnerPids 3081)).Count -ge 1)
}

Write-Host '== 16. shared "stop-prompt" option: launcher & listener stay in sync =='
# listener's Set-StopPromptOption must update ONLY the stopPrompt line and keep
# the other options (versionNotice / lang / warmup) intact - the two UIs read
# the same file, so they can never diverge.
$lAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'src\Start-HotkeyListener.ps1'), [ref]$null, [ref]$null)
foreach ($fnName in 'Get-StopPromptOption','Set-StopPromptOption') {
  $lf = $lAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fnName }, $true) | Select-Object -First 1
  if ($lf) { Invoke-Expression $lf.Extent.Text }
}
$tmpDir16 = Join-Path $env:TEMP ('smoke-stopopt-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir16 -Force | Out-Null
$opt16 = Join-Path $tmpDir16 'harness-options.txt'
Set-Content -Path $opt16 -Value @('versionNotice=0','lang=en','warmup=1') -Encoding ASCII
$savedDataDir = $DataDir
$savedOptionsFile = $OptionsFile
$DataDir = $tmpDir16
$OptionsFile = $opt16
Set-StopPromptOption $false
$after = Get-Content $opt16
Assert -Name 'sync: stopPrompt written' -Cond (@($after | Where-Object { $_ -eq 'stopPrompt=0' }).Count -eq 1)
Assert -Name 'sync: other options preserved (no divergence)' -Cond ((@($after | Where-Object { $_ -eq 'versionNotice=0' }).Count -eq 1) -and (@($after | Where-Object { $_ -eq 'lang=en' }).Count -eq 1) -and (@($after | Where-Object { $_ -eq 'warmup=1' }).Count -eq 1))
Assert -Name 'sync: launcher reads the same value' -Cond ((Get-LauncherOptions).StopPrompt -eq $false -and (Get-StopPromptOption) -eq $false)
$DataDir = $savedDataDir
$OptionsFile = $savedOptionsFile
Remove-Item $tmpDir16 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '== 17. env pre-flight: pnpm MUST be present before starting/building =='
$NodeMinVersion = '22.19.0'
$NodeMirrorBase = 'https://npmmirror.com/mirrors/node/'
$NpmMirrorRegistry = 'https://registry.npmmirror.com'
$ToolsDir = Join-Path $env:TEMP ('smoke-envtools-' + [guid]::NewGuid().ToString('N'))
$PortableNodeDir = Join-Path $ToolsDir 'node'
$PreflightStateFile = Join-Path $env:TEMP 'smoke-pf-state.txt'
function Get-NodeVersion { return '24.18.0' }   # node OK
function Get-PnpmVersion { return '' }           # pnpm missing
function npm { param([string]$install = '', [string]$g = '', [string]$prefix = '', [string]$registry = '', [switch]$noFund, [switch]$noAudit) $global:LASTEXITCODE = 1 }
Assert -Name 'env-ensure: missing pnpm -> pnpm-install-failed (no raw cmd error)' -Cond ((Ensure-NodeAndPnpm) -eq 'pnpm-install-failed')
function Get-PnpmVersion { return '11.21.0' }    # pnpm present
Assert -Name 'env-ensure: pnpm present -> ok' -Cond ((Ensure-NodeAndPnpm) -eq $true)
Remove-Item $ToolsDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $PreflightStateFile -Force -ErrorAction SilentlyContinue

Write-Host '== 18. WebView2 cleanup: start-time filtered (never other apps) =='
# Get-HarnessWebviewTargets must ONLY return webview2 processes that started
# at/after the service start time; the pid file is only a fallback
function Get-Process { param([string]$Name) return @(
  [pscustomobject]@{ Id = 1001; StartTime = [datetime]'2026-01-01 10:00:00' },   # before service -> NOT ours
  [pscustomobject]@{ Id = 1002; StartTime = [datetime]'2026-01-01 12:00:00' },   # after service  -> ours
  [pscustomobject]@{ Id = 1003; StartTime = $null }                              # unknown start  -> excluded
) }
$svcStart = [datetime]'2026-01-01 11:00:00'
$t1 = @(Get-HarnessWebviewTargets -svcStart $svcStart -pidFile '')
Assert -Name 'webview2: only start-time>=service processes targeted' -Cond ($t1.Count -eq 1 -and ($t1 -contains 1002))
$tmpPidFile = Join-Path $env:TEMP ('smoke-wv-' + [guid]::NewGuid().ToString('N') + '.pids')
Set-Content -Path $tmpPidFile -Value '1001,1002' -Encoding ASCII
$t2 = @(Get-HarnessWebviewTargets -svcStart $null -pidFile $tmpPidFile)
Assert -Name 'webview2: no start time -> pid-file fallback only' -Cond ($t2.Count -eq 2 -and ($t2 -contains 1001) -and ($t2 -contains 1002))
Remove-Item $tmpPidFile -Force -ErrorAction SilentlyContinue

Write-Host '== 19. single-instance: Windows named mutex =='
$m1 = New-Object System.Threading.Mutex($false, 'Local\DshSmokeTestMutex')
$owned1 = $m1.WaitOne(0)
Assert -Name 'mutex: first instance owns it' -Cond $owned1
# cross-process check: a SECOND process must NOT be able to acquire it
$mutexOut = Join-Path $env:TEMP ('smoke-mutex-' + [guid]::NewGuid().ToString('N') + '.txt')
$cmdStr = "`$m = New-Object System.Threading.Mutex(`$false, 'Local\DshSmokeTestMutex'); `$r = `$m.WaitOne(0); Set-Content -Path '" + $mutexOut + "' -Value `$r -Encoding ASCII"
$helper = Start-Process powershell -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-Command',$cmdStr) -WindowStyle Hidden -PassThru
try {
  $null = Wait-Process -Id $helper.Id -Timeout 15 -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  $otherOwned = $false
  if (Test-Path $mutexOut) { $otherOwned = ((Get-Content $mutexOut -Raw).Trim() -eq 'True') }
  Assert -Name 'mutex: second PROCESS is blocked (single-instance)' -Cond (-not $otherOwned)
} finally {
  Stop-Process -Id $helper.Id -Force -ErrorAction SilentlyContinue
  Remove-Item $mutexOut -Force -ErrorAction SilentlyContinue
}
$m1.ReleaseMutex()
$m1.Dispose()

Write-Host '== 20. port input injection hardening =='
# Test-ValidPortInput: only plain integers 1..65535 pass; anything that could
# carry injected content (commands, symbols, quotes, huge numbers) is rejected
Assert -Name 'inject: valid port accepted' -Cond (Test-ValidPortInput '3080')
Assert -Name 'inject: whitespace-trimmed port accepted' -Cond (Test-ValidPortInput '  3080  ')
Assert -Name 'inject: 0 rejected (range)' -Cond (-not (Test-ValidPortInput '0'))
Assert -Name 'inject: 65536 rejected (range)' -Cond (-not (Test-ValidPortInput '65536'))
Assert -Name 'inject: letters rejected' -Cond (-not (Test-ValidPortInput 'abc'))
Assert -Name 'inject: command injection rejected' -Cond (-not (Test-ValidPortInput '3080; calc'))
Assert -Name 'inject: quote/shell injection rejected' -Cond (-not (Test-ValidPortInput '3080" && whoami'))
Assert -Name 'inject: empty rejected' -Cond (-not (Test-ValidPortInput ''))

Write-Host ''
Write-Host ("RESULT: $passed passed, $failed failed")
if ($failed -gt 0) { exit 1 }
exit 0

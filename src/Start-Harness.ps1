# Start-Harness.ps1 - hidden launcher for DeepSeek Harness (dsh web).
# Detection logic (runs on every launch):
#   1. Web UI already responding (HTTP 200)      -> open the browser directly.
#   2. Service starting up (port open or dsh process alive, HTTP not ready)
#                                                -> wait silently (usually short),
#                                                   then open the browser (never
#                                                   start a 2nd instance).
#   3. Nothing running                           -> start "pnpm dsh web" hidden, wait
#                                                   until ready, then open the browser.
# The progress window is only shown in case 3 (a real cold start, which takes a
# while). When the service is already running or already starting (cases 1/2) no
# progress UI appears - the browser just opens quickly.
# Progress window content is REAL and monitored live every second: elapsed time,
# stage transitions (process -> configured port -> HTTP ready) and service-log activity.
# The estimated time remaining comes from the average of this machine's measured
# startups (logs\startup-times.log) and is labeled with the sample count; each
# completed cold start records total + port-up time so the estimate improves
# automatically. With no history yet the bar is indeterminate and the text says
# "monitoring, cannot predict" instead of inventing a number.
# A time-based double-click guard warns only when a second launch happens within
# 3 seconds; reopening the service after it was stopped proceeds normally.
# Also arms the global hotkey listener (Start-HotkeyListener.ps1) so the service
# can be stopped with one keypress.
# Usage: normally launched by Start-Harness.vbs (hidden).
#        Pass -NoPopup to suppress message boxes, the progress window and browser
#        opening (used for automated tests).
param([switch]$NoPopup, [switch]$ChangePortOnly, [switch]$CheckVersionOnly, [switch]$StopServiceOnly, [switch]$WarmupOnly)

$ErrorActionPreference = 'Continue'
# PS 5.1 may default to TLS 1.0/1.1; GitHub (api/codeload) requires TLS 1.2+
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# runtime data (logs/config/tools) lives OUTSIDE the source tree (clean OSS layout)
$DataDir = Join-Path (Split-Path $ScriptDir -Parent) 'data'
$LogDir = Join-Path $DataDir 'logs'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# DeepSeek Harness source is AUTO-DETECTED (no hardcoded paths): saved location
# (data\harness-config.json) -> $env:DSH_ROOT -> common locations scan -> shallow
# recursive scan -> interactive folder picker.
$LauncherConfigFile = Join-Path $DataDir 'harness-config.json'
$DefaultHarnessRoot = Join-Path $env:USERPROFILE 'deepseek-harness'
$DshRoot = ''

$DefaultPort = 3080
$Port = $DefaultPort
$Url = "http://127.0.0.1:$Port"
$PortConfigFile = Join-Path $DataDir 'harness-port-config.txt'
$ServicePidFile = Join-Path $LogDir 'harness-service.pid'
$ListenerScript = Join-Path $ScriptDir 'Start-HotkeyListener.ps1'
$HotkeyLog = Join-Path $LogDir 'harness-hotkey.log'
$LauncherLog = Join-Path $LogDir 'harness-launcher.log'
$OutLog = Join-Path $LogDir 'harness-web.out.log'
$ErrLog = Join-Path $LogDir 'harness-web.err.log'
$StartupHistoryFile = Join-Path $LogDir 'startup-times.log'
$PortUpMarker = Join-Path $LogDir 'port-up.marker'
$StartLockFile = Join-Path $LogDir 'service-start.running'   # cross-process start lock (single instance)

function Log($m) {
  # UTF-8 for logs so Chinese is never garbled on any system ANSI codepage
  Add-Content -Path $LauncherLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
}

function Set-FormIcon($form) {
  # unify the icon of every dialog with the launcher (green) icon
  try {
    $icoPath = Join-Path $ScriptDir 'launcher.ico'
    if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
  } catch {}
}

function Show-Popup($msg, $title = 'DeepSeek Harness') {
  # custom message box that shows the same (green) icon as the shortcut, instead of the generic system icons
  if ($NoPopup) { Log ("[popup suppressed] " + $msg); return }
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    $form = New-Object System.Windows.Forms.Form
    $form.Text = $title
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    Set-FormIcon $form
    $form.Add_Shown({ $form.Activate(); $form.BringToFront() })
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(16, 34)
    $pic.Size = New-Object System.Drawing.Size(48, 48)
    $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pngPath = Join-Path $ScriptDir 'launcher.png'
    if (Test-Path $pngPath) { try { $pic.Image = [System.Drawing.Image]::FromFile($pngPath) } catch {} }
    $form.Controls.Add($pic)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(76, 18)
    $lbl.Size = New-Object System.Drawing.Size(348, 78)
    $lbl.AutoSize = $true
    $lbl.MaximumSize = New-Object System.Drawing.Size(348, 0)
    $lbl.Text = $msg
    $form.Controls.Add($lbl)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point(332, 92)
    $btn.Size = New-Object System.Drawing.Size(88, 26)
    $btn.Text = T 'popupOk'
    $btn.DialogResult = 'OK'
    $form.AcceptButton = $btn
    $form.Controls.Add($btn)
    # size the window to fit the message (short and multi-line messages alike)
    $needH = 60 + $lbl.Height + 44
    $form.ClientSize = New-Object System.Drawing.Size(440, ([Math]::Max(128, $needH)))
    $null = $form.ShowDialog()
    $form.Dispose()
  } catch { Log ("[popup failed] " + $msg) }
}

# ---------- harness source location (auto-detect, no hardcoded paths) ----------
function Test-IsHarnessRoot($dir) {
  $pkg = Join-Path $dir 'package.json'
  if (Test-Path $pkg) {
    try {
      $j = Get-Content $pkg -Raw -ErrorAction Stop | ConvertFrom-Json
      return ($j.name -eq '@deepseek-ai/dsh-root')
    } catch { return $false }
  }
  return $false
}

function Save-LauncherConfig($dshRoot) {
  try {
    Set-Content -Path $LauncherConfigFile -Value (@{ dshRoot = $dshRoot } | ConvertTo-Json) -Encoding ASCII
  } catch { Log ("[config save failed] " + $_.Exception.Message) }
}

function Resolve-HarnessRoot {
  # 1) saved location (harness-config.json)
  if (Test-Path $LauncherConfigFile) {
    try {
      $j = Get-Content $LauncherConfigFile -Raw | ConvertFrom-Json
      if ($j.dshRoot -and (Test-IsHarnessRoot $j.dshRoot)) { return $j.dshRoot }
    } catch {}
  }
  # 2) environment override
  if ($env:DSH_ROOT -and (Test-IsHarnessRoot $env:DSH_ROOT)) { return $env:DSH_ROOT }
  # 3) common locations
  $candidates = @(
    (Join-Path $ScriptDir '..\deepseek-harness-master'),
    (Join-Path $ScriptDir '..\..\deepseek-harness-master'),
    'C:\deepseek-harness',
    'C:\dev\deepseek-harness',
    'D:\deepseek-harness',
    (Join-Path $env:USERPROFILE 'deepseek-harness'),
    (Join-Path $env:USERPROFILE 'dev\deepseek-harness'),
    (Join-Path $env:USERPROFILE 'source\deepseek-harness')
  )
  foreach ($c in $candidates) { if ($c -and (Test-IsHarnessRoot $c)) { return $c } }
  # 4) shallow recursive scan (depth 2) from likely roots
  foreach ($root in @('D:\', $env:USERPROFILE)) {
    if ($root -and (Test-Path $root)) {
      try {
        $hit = Get-ChildItem -Path $root -Directory -Filter '*deepseek-harness*' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          Where-Object { Test-IsHarnessRoot $_.FullName } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
      } catch {}
    }
  }
  # 5) interactive folder picker (skipped in -NoPopup mode)
  if (-not $NoPopup) {
    try {
      Add-Type -AssemblyName System.Windows.Forms | Out-Null
      $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
      $dlg.Description = T 'pickerDesc'
      if ($dlg.ShowDialog() -eq 'OK') {
        if (Test-IsHarnessRoot $dlg.SelectedPath) { Save-LauncherConfig $dlg.SelectedPath; return $dlg.SelectedPath }
      }
    } catch {}
  }
  return ''
}

# ---------- port configuration ----------
# The port is configurable. The launcher actively scans this machine for free
# ports (excluding ports used by major services) and presents them in a small
# UI; the choice can be remembered in harness-port-config.txt.

# ports used by major/common services - the scanner never suggests these
$MajorServicePorts = @(
  20,21,22,23,25,53,67,68,69,80,110,123,135,137,138,139,143,161,389,443,445,
  465,514,587,636,873,993,995,1080,1433,1521,1723,2049,2181,2375,3128,3306,
  3389,4369,5000,5060,5061,5222,5432,5672,5900,5984,6379,7001,7002,7890,7897,
  8000,8005,8008,8009,8080,8081,8088,8443,8500,8888,9000,9042,9090,9092,9200,
  9300,9999,10000,11211,15672,27017,28017,50070,61616
)

function Load-PortConfig {
  $p = 0; $r = $false
  if (Test-Path $PortConfigFile) {
    foreach ($line in (Get-Content $PortConfigFile -ErrorAction SilentlyContinue)) {
      if ($line -match '^port=(\d+)$') { $v = [int]$matches[1]; if ($v -ge 1 -and $v -le 65535) { $p = $v } }
      elseif ($line -match '^remember=([01])$') { $r = ($matches[1] -eq '1') }
    }
  }
  return @{ Port = $p; Remember = $r }
}

function Save-PortConfig($port, $remember) {
  try {
    Set-Content -Path $PortConfigFile -Value @("port=$port", ('remember=' + $(if ($remember) { 1 } else { 0 }))) -Encoding ASCII
  } catch { Log ("[save port config failed] " + $_.Exception.Message) }
}

# ---- user options (independent of the port config) ----
$OptionsFile = Join-Path $DataDir 'harness-options.txt'

function Get-LauncherOptions {
  $o = @{ VersionNotice = $true; Lang = 'zh'; Warmup = $false; StopPrompt = $true }
  if (Test-Path $OptionsFile) {
    foreach ($line in (Get-Content $OptionsFile -ErrorAction SilentlyContinue)) {
      if ($line -match '^versionNotice=([01])$') { $o.VersionNotice = ($matches[1] -eq '1') }
      elseif ($line -match '^lang=([a-z]+)$') { $o.Lang = $matches[1] }
      elseif ($line -match '^warmup=([01])$') { $o.Warmup = ($matches[1] -eq '1') }
      elseif ($line -match '^stopPrompt=([01])$') { $o.StopPrompt = ($matches[1] -eq '1') }
    }
  }
  return $o
}

function Save-LauncherOptions($o) {
  try {
    Set-Content -Path $OptionsFile -Value @(('versionNotice=' + $(if ($o.VersionNotice) { 1 } else { 0 })), ('lang=' + $o.Lang), ('warmup=' + $(if ($o.Warmup) { 1 } else { 0 })), ('stopPrompt=' + $(if ($o.StopPrompt) { 1 } else { 0 }))) -Encoding ASCII
  } catch { Log ("[options save failed] " + $_.Exception.Message) }
}

function Get-VersionNoticeOption { return (Get-LauncherOptions).VersionNotice }
function Set-VersionNoticeOption($on) { $o = Get-LauncherOptions; $o.VersionNotice = $on; Save-LauncherOptions $o }
function Get-LanguageOption { return (Get-LauncherOptions).Lang }
function Set-LanguageOption($lang) { $o = Get-LauncherOptions; $o.Lang = $lang; Save-LauncherOptions $o; $script:Lang = $lang }
function Get-WarmupOption { return (Get-LauncherOptions).Warmup }
function Set-WarmupOption($on) { $o = Get-LauncherOptions; $o.Warmup = $on; Save-LauncherOptions $o }
function Get-StopPromptOption { return (Get-LauncherOptions).StopPrompt }
function Set-StopPromptOption($on) { $o = Get-LauncherOptions; $o.StopPrompt = $on; Save-LauncherOptions $o }

# ---- Windows-login warm-up (pre-start the web service so the first real launch
# is instant). Registered in the HKCU Run key; default OFF (user opts in).
$WarmupRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$WarmupValueName = 'DeepSeekHarnessWarmup'

function Get-WarmupStartupCommand {
  # wscript -> Start-Harness.vbs -> Start-Harness.ps1 -WarmupOnly -NoPopup (hidden)
  return ('"' + (Join-Path $env:WINDIR 'System32\wscript.exe') + '" "' + (Join-Path $ScriptDir 'Start-Harness.vbs') + '" -WarmupOnly -NoPopup')
}

function Set-WarmupStartup($on, [string]$keyPath = $WarmupRunKey, [string]$name = $WarmupValueName) {
  # register / remove the Windows-login warm-up entry (HKCU Run key)
  try {
    if ($on) { Set-ItemProperty -Path $keyPath -Name $name -Value (Get-WarmupStartupCommand) -Force }
    else { Remove-ItemProperty -Path $keyPath -Name $name -ErrorAction SilentlyContinue }
  } catch { Log ("[warmup startup failed] " + $_.Exception.Message) }
}

# ---- i18n (bilingual UI) ----
$I18n = @{
  zh = @{
    appTitle = 'DeepSeek Harness'
    portTitle = 'DeepSeek Harness - 端口配置'
    portScanLabel = '已自动扫描以下可用端口（已排除常用服务端口）：'
    portScanCount = '已扫描到 {0} 个可用端口（已排除常用服务端口）'
    portRescan = '重新扫描'
    portScanning = '正在扫描可用端口…'
    portOk = '确认使用'
    portCancel = '取消'
    portRemember = '记住此配置，下次启动自动使用'
    portNoticeToggle = '弹出"已是最新版本"提示（可关闭）'
    portLangLabel = '界面语言：'
    portHint = '下拉列表为扫描到的空闲端口；也可手动输入（无效/常用服务端口会提示；已使用中的端口可直接使用）。'
    portInvalid = '端口无效：请输入 1-65535 之间的数字'
    portInUseWarn = '端口 {0} 已使用中（可直接使用）'
    portMajorService = '端口 {0} 为常用服务端口，建议避开'
    portAvailable = '端口 {0} 可用 ✓'
    portRestartNote = '端口配置修改后，需要重启服务才会生效。'
    progressTitle = 'DeepSeek Harness 正在启动'
    progressStarting = '正在启动 DeepSeek Harness 服务…'
    progressPortReady = '端口 {0} 已就绪，正在初始化页面…'
    progressWaitingStart = '检测到服务正在启动，等待就绪…'
    progressMonitorActive = '实时监测：日志持续输出'
    progressMonitorIdle = '实时监测：日志输出暂缓'
    progressElapsed = '已用 {0} 秒'
    progressEta = '预计剩余约 {0} 秒'
    progressEtaSample = '（{0} 次实测）'
    progressEtaFirstRun = '（首次启动，经验估算）'
    progressNoHistory = '暂无历史数据，无法预估剩余时间，正在实时监测…'
    progressAboutReady = '即将就绪…'
    progressOverAvg = '已超过平均耗时，即将就绪…'
    progressPageInit = '端口已就绪，页面初始化中，即将完成…'
    progressPageInitEta = '页面初始化，预计还需约 {0} 秒'
    progressCloseHint = '关闭此窗口不影响启动，就绪后仍会自动打开浏览器'
    progressFailedExit = '服务进程异常退出，启动失败。'
    progressTimeout = '启动超时（超过 {0} 秒）。'
    progressErrorLog = '请查看 logs\harness-web.err.log / harness-web.out.log'
    versionNoticeTitle = 'DeepSeek Harness - 版本检测'
    versionUpdateTitle = 'DeepSeek Harness - 发现更新'
    versionLatest = '版本检测完成：已是最新版本 v{0}'
    versionNewFound = '发现新版本：本地 v{0} → 最新 v{1}`n是否现在更新并重启服务？'
    versionLater = '稍后'
    versionUpdateRestart = '更新并重启'
    versionOk = '知道了'
    updateTitle = 'DeepSeek Harness - 更新'
    updateInstallTitle = 'DeepSeek Harness - 首次安装'
    updateInstallMsg = '本机未检测到 DeepSeek Harness 源码。`n将从 GitHub 拉取并安装到：{0}'
    updateInstall = '安装'
    updateConfirm = '确认'
    updateCancel = '取消'
    updateNow = '立即更新'
    errorTitle = 'DeepSeek Harness - 安装/更新失败'
    errorStep = '失败步骤：{0}'
    errorText = '错误：{0}'
    errorFix = '修复建议：{0}'
    errorCleanHint = '已拉取/安装的内容可能不完整。你可以选择清除这些内容后重新安装，或清除后退出（不会影响原有正常版本）。'
    errorReinstall = '清除并重装'
    errorCleanExit = '清除并退出'
    errorExit = '仅退出'
    popupAlreadyRunning = '服务已在运行，请勿多次开启同一服务！`n已为你打开浏览器：{0}`n快捷键监听器已{1}。`n`n关闭服务快捷键：{2}'
    popupListenerActive = '在运行'
    popupListenerReArmed = '重新挂载'
    popupDoubleClick = '检测到重复双击（3 秒内）。`n请勿多次开启同一服务！`n如果服务正在启动，请稍候片刻。'
    popupCase2Timeout = '服务正在启动但 2 分钟内未就绪。`n日志：{0}'
    popupRootNotFound = '未找到 DeepSeek Harness 源码目录。`n请将源码放到常见位置（如 C:\deepseek-harness）后重试，`n或手动创建 harness-config.json 指定 dshRoot 路径。`n（源码根目录的 package.json 中 name 应为 @deepseek-ai/dsh-root）'
    popupStartFailed = 'DeepSeek Harness 启动失败（或超过 3 分钟未就绪）。`n日志：{0}`n`n请查看 harness-web.out.log / harness-web.err.log'
    popupHotkeyFallback = 'Ctrl+Alt+Shift+F12（若可用）'
    popupReady = '检测到服务已就绪。`n已打开浏览器：{0}`n`n关闭服务快捷键：{1}'
    popupStarted = 'DeepSeek Harness 服务已启动。`n已打开浏览器：{0}`n日志目录：{1}`n`n关闭服务快捷键：{2}'
    popupStartFailedTitle = 'DeepSeek Harness - 启动失败'
    rollbackTitle = 'DeepSeek Harness - 自动回滚'
    rollbackBuildFailed = '更新后的版本构建失败，已自动回滚到上一版本，正在用上一版本启动服务。'
    rollbackStartFailed = '更新后的版本启动失败，已自动回滚到上一版本并重新启动。'
    rollbackUpdateFailed = '更新下载/校验失败，已保持当前版本并重新启动服务。'
    popupTitleHint = 'DeepSeek Harness - 提示'
    popupOk = '确定'
    portWarmup = '开机预热服务（防止首次等待，默认关闭）'
    portStopPrompt = '不再提示静默模式'
    hardStopBtn = '硬关闭服务'
    hardStopDone = '服务已硬关闭：所有相关后台进程（服务 / cmd 包装 / WebView2）已全部终止。'
    svcStopped = 'DeepSeek Harness 服务已停止。'
    popupTitleError = 'DeepSeek Harness - 错误'
    pickerDesc = '请选择 DeepSeek Harness 源码目录（包含 package.json 的文件夹）'
    errStepEnv = '环境预检'
    errTextNode = 'Node.js / pnpm 配置失败（{0}）'
    errFixNode = '请检查网络连接后重试；或手动安装 Node.js ≥ 22.19.0 与 pnpm'
    errStepInstall = '首次安装'
    errTextPull = '从 GitHub 拉取源码失败'
    errFixPull = '请检查网络，或手动下载 https://github.com/deepseek-ai/deepseek-harness 后解压到 {0}'
    errStepInstallBuild = '首次安装构建'
    errTextBuild = 'pnpm install / build 失败'
    errFixBuild = '请查看 logs\harness-launcher.log 获取详细错误'
    errStepUpdateBuild = '更新后构建'
    errFixUpdateBuild = '请查看日志后重试'
    errStepBgUpdateBuild = '后台更新构建'
  }
  en = @{
    appTitle = 'DeepSeek Harness'
    portTitle = 'DeepSeek Harness - Port Configuration'
    portScanLabel = 'Available ports scanned (common service ports excluded):'
    portScanCount = 'Scanned {0} available ports (common service ports excluded)'
    portRescan = 'Rescan'
    portScanning = 'Scanning available ports…'
    portOk = 'Use Port'
    portCancel = 'Cancel'
    portRemember = 'Remember this config for next launch'
    portNoticeToggle = 'Show "already latest" notice'
    portLangLabel = 'Language:'
    portHint = 'Pick a scanned free port, or type one manually (invalid / common service ports are rejected; ports already in use are usable as-is).'
    portInvalid = 'Invalid port: enter a number between 1-65535'
    portInUseWarn = 'Port {0} in use (usable as-is)'
    portMajorService = 'Port {0} is a common service port, avoid it'
    portAvailable = 'Port {0} available ✓'
    portRestartNote = 'The port change takes effect after the service restarts.'
    progressTitle = 'DeepSeek Harness is starting'
    progressStarting = 'Starting DeepSeek Harness service…'
    progressPortReady = 'Port {0} ready, initializing page…'
    progressWaitingStart = 'Service is starting, waiting for it to become ready…'
    progressMonitorActive = 'Live monitor: log is being written'
    progressMonitorIdle = 'Live monitor: no new log output'
    progressElapsed = 'Elapsed {0}s'
    progressEta = 'about {0}s remaining'
    progressEtaSample = ' ({0} runs)'
    progressEtaFirstRun = ' (first run, estimate)'
    progressNoHistory = 'No history yet, cannot estimate remaining time; monitoring live…'
    progressAboutReady = 'almost ready…'
    progressOverAvg = 'past the average time, almost ready…'
    progressPageInit = 'Port ready, page initializing, almost done…'
    progressPageInitEta = 'page initializing, about {0}s remaining'
    progressCloseHint = 'Closing this window does not cancel startup; the browser opens when ready'
    progressFailedExit = 'Service process exited unexpectedly, startup failed.'
    progressTimeout = 'Startup timed out (over {0}s).'
    progressErrorLog = 'See logs\harness-web.err.log / harness-web.out.log'
    versionNoticeTitle = 'DeepSeek Harness - Version Check'
    versionUpdateTitle = 'DeepSeek Harness - Update Available'
    versionLatest = 'Version check complete: already up to date (v{0})'
    versionNewFound = 'New version available: local v{0} -> latest v{1}`nUpdate and restart the service now?'
    versionLater = 'Later'
    versionUpdateRestart = 'Update & Restart'
    versionOk = 'OK'
    updateTitle = 'DeepSeek Harness - Update'
    updateInstallTitle = 'DeepSeek Harness - First Install'
    updateInstallMsg = 'No DeepSeek Harness source found on this machine.`nInstall from GitHub to: {0}'
    updateInstall = 'Install'
    updateConfirm = 'OK'
    updateCancel = 'Cancel'
    updateNow = 'Update Now'
    errorTitle = 'DeepSeek Harness - Install/Update Failed'
    errorStep = 'Failed step: {0}'
    errorText = 'Error: {0}'
    errorFix = 'How to fix: {0}'
    errorCleanHint = 'The downloaded/installed content may be incomplete. You can clear it and reinstall, or clear and exit (your previous working version is kept).'
    errorReinstall = 'Clear & Reinstall'
    errorCleanExit = 'Clear & Exit'
    errorExit = 'Exit Only'
    popupAlreadyRunning = 'The service is already running - do not start it twice!`nBrowser opened: {0}`nHotkey listener {1}.`n`nStop-service hotkey: {2}'
    popupListenerActive = 'active'
    popupListenerReArmed = 're-armed'
    popupDoubleClick = 'Double-click detected (within 3s).`nDo not start the service twice!`nIf it is still starting, please wait.'
    popupCase2Timeout = 'The service was starting but did not become ready within 2 minutes.`nLogs: {0}'
    popupRootNotFound = 'DeepSeek Harness source not found.`nPut the source somewhere common (e.g. C:\deepseek-harness) and retry,`nor create harness-config.json with a dshRoot entry.`n(The root package.json must have name @deepseek-ai/dsh-root)'
    popupStartFailed = 'DeepSeek Harness failed to start (or took longer than 3 minutes).`nLogs: {0}`n`nSee harness-web.out.log / harness-web.err.log'
    popupHotkeyFallback = 'Ctrl+Alt+Shift+F12 (if available)'
    popupReady = 'Service detected and ready.`nBrowser opened: {0}`n`nStop-service hotkey: {1}'
    popupStarted = 'DeepSeek Harness service started.`nBrowser opened: {0}`nLogs: {1}`n`nStop-service hotkey: {2}'
    popupStartFailedTitle = 'DeepSeek Harness - Start Failed'
    rollbackTitle = 'DeepSeek Harness - Auto Rollback'
    rollbackBuildFailed = 'The updated version failed to build. Automatically rolled back to the previous version and it is starting now.'
    rollbackStartFailed = 'The updated version failed to start. Automatically rolled back and restarting the previous version.'
    rollbackUpdateFailed = 'Update download/verification failed. Keeping the current version and restarting the service.'
    popupTitleHint = 'DeepSeek Harness - Notice'
    popupOk = 'OK'
    portWarmup = 'Pre-warm the service at Windows login (skip the first-launch wait; off by default)'
    portStopPrompt = 'Don''t ask again for the silent stop'
    hardStopBtn = 'Hard Stop'
    hardStopDone = 'Service hard-stopped: all related background processes (service / cmd wrapper / WebView2) have been terminated.'
    svcStopped = 'DeepSeek Harness service has been stopped.'
    popupTitleError = 'DeepSeek Harness - Error'
    pickerDesc = 'Select the DeepSeek Harness source folder (contains package.json)'
    errStepEnv = 'Environment check'
    errTextNode = 'Node.js / pnpm setup failed ({0})'
    errFixNode = 'Check your network and retry; or install Node.js >= 22.19.0 and pnpm manually'
    errStepInstall = 'First install'
    errTextPull = 'Failed to pull the source from GitHub'
    errFixPull = 'Check your network, or download https://github.com/deepseek-ai/deepseek-harness and extract it to {0}'
    errStepInstallBuild = 'First install - build'
    errTextBuild = 'pnpm install / build failed'
    errFixBuild = 'See logs\harness-launcher.log for details'
    errStepUpdateBuild = 'Update - build'
    errFixUpdateBuild = 'Check the logs and retry'
    errStepBgUpdateBuild = 'Background update - build'
  }
}

function T($key) {
  # values are stored with a literal backtick-n marker; expand it to a real newline
  $nl = [string][char]96 + 'n'
  if ($I18n[$Lang] -and $I18n[$Lang].ContainsKey($key)) { return ([string]$I18n[$Lang][$key]).Replace($nl, "`n") }
  if ($I18n['en'].ContainsKey($key)) { return ([string]$I18n['en'][$key]).Replace($nl, "`n") }
  return $key
}

$Lang = Get-LanguageOption
if ($Lang -ne 'zh' -and $Lang -ne 'en') { $Lang = 'zh' }

function Test-PortIsMajorService([int]$portNumber) {
  return ($MajorServicePorts -contains $portNumber)
}

# Actively scan this machine for free ports, skipping ports used by major
# services. Starts at $StartAt and collects up to $Count free ports.
function Get-AvailablePorts {
  param([int]$Count = 15, [int]$StartAt = 3080)
  $found = @()
  $p = $StartAt
  while ($found.Count -lt $Count -and $p -le 65535) {
    if (-not (Test-PortIsMajorService $p) -and -not (Test-PortListening -PortNumber $p -TimeoutMs 150)) {
      $found += $p
    }
    $p++
  }
  return @($found)
}

function Show-PortConfigDialog {
  param([int]$DefaultPort, [string]$Note = '')
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = T 'portTitle'
  Set-FormIcon $form
  $form.ClientSize = New-Object System.Drawing.Size(460, 318)
  $form.AutoScroll = $true   # guarantee every control (incl. the OK button) stays reachable
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.TopMost = $true
  $form.ShowInTaskbar = $false

  # keep the dialog on top of the browser and give it focus when it appears
  $form.Add_Shown({ $form.Activate(); $form.BringToFront() })

  # optional warning note (e.g. "change takes effect after restart") as the top line
  $noteOffset = 0
  if ($Note) {
    $noteLbl = New-Object System.Windows.Forms.Label
    $noteLbl.Location = New-Object System.Drawing.Point(15, 12)
    $noteLbl.Size = New-Object System.Drawing.Size(430, 22)
    $noteLbl.Text = $Note
    $noteLbl.ForeColor = [System.Drawing.Color]::Red
    $noteLbl.Font = New-Object System.Drawing.Font('Microsoft YaHei', 8.75, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($noteLbl)
    $noteOffset = 24
    $form.ClientSize = New-Object System.Drawing.Size(460, 342)
  }

  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Location = New-Object System.Drawing.Point(15, (16 + $noteOffset))
  $lbl.Size = New-Object System.Drawing.Size(430, 22)
  $lbl.Text = T 'portScanLabel'
  $form.Controls.Add($lbl)

  $cmb = New-Object System.Windows.Forms.ComboBox
  $cmb.Location = New-Object System.Drawing.Point(15, (44 + $noteOffset))
  $cmb.Size = New-Object System.Drawing.Size(300, 24)
  $cmb.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown   # editable
  $form.Controls.Add($cmb)

  $btnScan = New-Object System.Windows.Forms.Button
  $btnScan.Location = New-Object System.Drawing.Point(325, (43 + $noteOffset))
  $btnScan.Size = New-Object System.Drawing.Size(70, 26)
  $btnScan.Text = T 'portRescan'
  $form.Controls.Add($btnScan)

  $status = New-Object System.Windows.Forms.Label
  $status.Location = New-Object System.Drawing.Point(15, (76 + $noteOffset))
  $status.Size = New-Object System.Drawing.Size(430, 22)
  $status.Text = ''
  $status.ForeColor = [System.Drawing.Color]::DimGray
  $form.Controls.Add($status)

  $chk = New-Object System.Windows.Forms.CheckBox
  $chk.Location = New-Object System.Drawing.Point(15, (104 + $noteOffset))
  $chk.Size = New-Object System.Drawing.Size(300, 22)
  $chk.Text = T 'portRemember'
  $chk.Checked = $true
  $form.Controls.Add($chk)

  $chkNotice = New-Object System.Windows.Forms.CheckBox
  $chkNotice.Location = New-Object System.Drawing.Point(15, (126 + $noteOffset))
  $chkNotice.Size = New-Object System.Drawing.Size(320, 22)
  $chkNotice.Text = T 'portNoticeToggle'
  $chkNotice.Checked = Get-VersionNoticeOption
  $form.Controls.Add($chkNotice)

  # language selector (persisted in harness-options.txt)
  $lblLang = New-Object System.Windows.Forms.Label
  $lblLang.Location = New-Object System.Drawing.Point(15, (152 + $noteOffset))
  $lblLang.Size = New-Object System.Drawing.Size(80, 22)
  $lblLang.Text = T 'portLangLabel'
  $form.Controls.Add($lblLang)
  $cmbLang = New-Object System.Windows.Forms.ComboBox
  $cmbLang.Location = New-Object System.Drawing.Point(100, (150 + $noteOffset))
  $cmbLang.Size = New-Object System.Drawing.Size(110, 24)
  $cmbLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
  $cmbLang.Items.AddRange(@('中文 (Chinese)', 'English'))
  if ($Lang -eq 'en') { $cmbLang.SelectedIndex = 1 } else { $cmbLang.SelectedIndex = 0 }
  $form.Controls.Add($cmbLang)

  # Windows-login warm-up toggle (default OFF - user opts in manually)
  $chkWarmup = New-Object System.Windows.Forms.CheckBox
  $chkWarmup.Location = New-Object System.Drawing.Point(15, (176 + $noteOffset))
  $chkWarmup.Size = New-Object System.Drawing.Size(430, 22)
  $chkWarmup.Text = T 'portWarmup'
  $chkWarmup.Checked = Get-WarmupOption
  $form.Controls.Add($chkWarmup)

  # "silent-stop popup" suppression toggle (shared with the hotkey stop - the
  # SAME option file, so both UIs are always in sync)
  $chkStopPrompt = New-Object System.Windows.Forms.CheckBox
  $chkStopPrompt.Location = New-Object System.Drawing.Point(15, (198 + $noteOffset))
  $chkStopPrompt.Size = New-Object System.Drawing.Size(430, 22)
  $chkStopPrompt.Text = T 'portStopPrompt'
  $chkStopPrompt.Checked = -not (Get-StopPromptOption)
  $form.Controls.Add($chkStopPrompt)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Location = New-Object System.Drawing.Point(15, (222 + $noteOffset))
  $hint.Size = New-Object System.Drawing.Size(430, 20)
  $hint.Text = T 'portHint'
  $hint.ForeColor = [System.Drawing.Color]::Gray
  $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 8.25)
  $form.Controls.Add($hint)

  $btnHardStop = New-Object System.Windows.Forms.Button
  $btnHardStop.Location = New-Object System.Drawing.Point(15, (270 + $noteOffset))
  $btnHardStop.Size = New-Object System.Drawing.Size(105, 28)
  $btnHardStop.Text = T 'hardStopBtn'
  $btnHardStop.ForeColor = [System.Drawing.Color]::Firebrick
  $form.Controls.Add($btnHardStop)

  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Location = New-Object System.Drawing.Point(270, (270 + $noteOffset))
  $btnOk.Size = New-Object System.Drawing.Size(85, 28)
  $btnOk.Text = T 'portOk'
  $form.Controls.Add($btnOk)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Location = New-Object System.Drawing.Point(365, (270 + $noteOffset))
  $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
  $btnCancel.Text = T 'portCancel'
  $btnCancel.DialogResult = 'Cancel'
  $form.Controls.Add($btnCancel)

  # NOTE: PowerShell event-handler closures cannot update function variables, so
  # the result is passed back through the form's Tag property.

  function Fill-Scan {
    $cmb.Items.Clear()
    $avail = Get-AvailablePorts -Count 15 -StartAt $DefaultPort
    if ($avail.Count -eq 0) { $avail = Get-AvailablePorts -Count 15 -StartAt 1024 }
    foreach ($prt in $avail) { [void]$cmb.Items.Add([string]$prt) }
    if ($cmb.Items.Count -gt 0) { $cmb.Text = [string]$cmb.Items[0] } else { $cmb.Text = [string]$DefaultPort }
    $status.Text = ([string]::Format((T 'portScanCount'), $cmb.Items.Count))
    $status.ForeColor = [System.Drawing.Color]::Green
    Update-Status
  }

  function Test-ValidPortInput([string]$raw) {
    # STRICT validation - the ONLY way a typed value can ever become a port.
    # Plain integers 1..65535 only; anything else (commands, symbols, quotes)
    # is rejected, so the port value can never carry injected content into the
    # config file or the "pnpm dsh web --port" command line.
    $p = 0
    return ($raw -and [int]::TryParse($raw, [ref]$p) -and $p -ge 1 -and $p -le 65535)
  }

  function Update-Status {
    $raw = $cmb.Text.Trim()
    if (-not (Test-ValidPortInput $raw)) {
      $status.Text = T 'portInvalid'
      $status.ForeColor = [System.Drawing.Color]::Red
      return
    }
    $p = [int]$raw
    if (Test-PortIsMajorService $p) {
      $status.Text = ([string]::Format((T 'portMajorService'), $p))
      $status.ForeColor = [System.Drawing.Color]::OrangeRed
      return
    }
    if (Test-PortListening -PortNumber $p) {
      # in-use port: usable as-is (the launcher's port-independent detection
      # uses the running service) - shown as a hint, never a blocking error
      $status.Text = ([string]::Format((T 'portInUseWarn'), $p))
      $status.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
      $status.Text = ([string]::Format((T 'portAvailable'), $p))
      $status.ForeColor = [System.Drawing.Color]::Green
    }
  }

  # injection hardening: the port field accepts DIGITS ONLY (plus backspace)
  $cmb.Add_KeyPress({
    param($sender, $e)
    if ($e.KeyChar -ne [char]8 -and -not [char]::IsDigit($e.KeyChar)) { $e.Handled = $true }
  })

  $cmb.Add_TextChanged({ Update-Status })
  $cmb.Add_SelectedIndexChanged({ Update-Status })
  $btnScan.Add_Click({
    $status.Text = T 'portScanning'
    $status.ForeColor = [System.Drawing.Color]::DimGray
    Fill-Scan
  })
  # HARD STOP: one click kills the service by port (works even if process
  # matching fails) - the "guaranteed close" counterpart to the silent soft
  # stop of the hotkey.
  $btnHardStop.Add_Click({
    try {
      Log 'Hard stop requested from the port dialog.'
      Stop-HarnessService
      # persist the "silent-stop popup" suppression too (shared option file)
      Set-StopPromptOption (-not $chkStopPrompt.Checked)
      Show-Popup (T 'hardStopDone') (T 'popupTitleHint')
      $form.Tag = @{ Port = 0; Remember = $chk.Checked; VersionNotice = $chkNotice.Checked; HardStop = $true }
      $form.DialogResult = 'OK'
      $form.Close()
    } catch { Log ('[hard stop error] ' + $_.Exception.Message) }
  })
  $btnOk.Add_Click({
    $raw = $cmb.Text.Trim()
    if (-not (Test-ValidPortInput $raw)) {
      $status.Text = T 'portInvalid'
      $status.ForeColor = [System.Drawing.Color]::Red
      return
    }
    $p = [int]$raw
    # only INVALID numbers and MAJOR-SERVICE ports are blocked; a port that is
    # already IN USE is accepted (hint shown) so the UI can always be confirmed
    if (Test-PortIsMajorService $p) {
      Update-Status
      return
    }
    # persist the chosen UI language
    if ($cmbLang.SelectedIndex -eq 1) { Set-LanguageOption 'en' } else { Set-LanguageOption 'zh' }
    # persist the warm-up option and keep the Windows-login entry in sync
    Set-WarmupOption $chkWarmup.Checked
    Set-WarmupStartup $chkWarmup.Checked
    # persist the "silent-stop popup" suppression (shared with the hotkey stop)
    Set-StopPromptOption (-not $chkStopPrompt.Checked)
    $form.Tag = @{ Port = $p; Remember = $chk.Checked; VersionNotice = $chkNotice.Checked }
    $form.DialogResult = 'OK'
    $form.Close()
  })

  Fill-Scan
  $null = $form.ShowDialog()
  $tag = $form.Tag
  $cmb.Dispose(); $cmbLang.Dispose(); $lblLang.Dispose(); $chk.Dispose(); $chkNotice.Dispose(); $status.Dispose(); $lbl.Dispose(); $hint.Dispose(); $btnScan.Dispose(); $btnOk.Dispose(); $btnCancel.Dispose(); $form.Dispose()
  if ($tag) { return @{ Port = $tag.Port; Remember = $tag.Remember; VersionNotice = $tag.VersionNotice } }
  return @{ Port = 0; Remember = $false; VersionNotice = $true }
}

# ---------- double-click guard (time-based) ----------
# A second launch within 3 seconds is treated as a double-click and warned;
# after 3 seconds a launch is a fresh start (e.g. reopening after stopping the
# service) and proceeds normally. The timestamp is managed in the main flow.

# ---------- detection helpers ----------
function Test-HarnessUp {   # HTTP level: the web UI is actually responding
  param([int]$PortNumber = $Port)
  $u = "http://127.0.0.1:$PortNumber"
  try { $null = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 2; return $true }
  catch { return $false }
}

function Test-PortListening {   # TCP level: a connection to the port can be established
  param([int]$PortNumber = $Port, [int]$TimeoutMs = 500)
  try {
    $client = New-Object System.Net.Sockets.TcpClient
    $task = $client.ConnectAsync('127.0.0.1', $PortNumber)
    $connected = $false
    try { $connected = ($task.Wait($TimeoutMs) -and $client.Connected) } catch { $connected = $false }
    $client.Close()
    return $connected
  } catch { return $false }
}

function Test-ServiceProcess {  # process level: a dsh CLI node process (bin.ts) exists
  try {
    return [bool](Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop |
      Where-Object { $_.CommandLine -match 'apps[\\/]cli[\\/]src[\\/]bin\.ts' })
  } catch { return $false }
}

function Get-RunningHarnessPort {
  # the port the running dsh service is actually listening on (from --port N;
  # the real command line is e.g. ... "web" "--port" "3080" - quotes included).
  # Returns 0 when no service is running or the port cannot be determined.
  $p = Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { Test-HarnessProcessCommandLine ([string]$_.CommandLine) } | Select-Object -First 1
  if ($p -and $p.CommandLine -match '--port[" =]*(\d+)') { return [int]$matches[1] }
  return 0
}

function Test-HarnessProcessCommandLine([string]$cmd) {
  # true for processes that belong to the harness. Matches:
  #   1) command lines containing the resolved harness root (this install), OR
  #   2) the dsh CLI entry (apps\cli\src\bin.ts) from ANY copy/location.
  # Unrelated node processes (no root, no CLI entry) are NEVER matched, so the
  # stop can never mis-kill other software.
  if (-not $cmd) { return $false }
  if ($DshRoot -and $cmd.ToLowerInvariant().Contains([string]$DshRoot.ToLowerInvariant())) { return $true }
  return ($cmd -match 'apps[\\/]cli[\\/]src[\\/]bin\.ts')
}

function Stop-StaleHarnessProcesses {
  # Kill leftover dsh node processes from earlier instances that were not fully
  # stopped (e.g. the agent companion on a secondary port), so two harness
  # instances can never run at the same time. Only called when nothing is serving.
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { Test-HarnessProcessCommandLine ([string]$_.CommandLine) } |
    ForEach-Object {
      try { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null } catch {}
      Log ("Stale dsh process killed: pid " + $_.ProcessId)
    }
}

function Test-ServiceStartLocked {
  # SINGLE-INSTANCE GUARANTEE: true when ANOTHER launcher process is mid-start
  # (holding the service-start lock). A lock held by ourselves or by a dead
  # process never blocks; stale locks are removed automatically.
  if (-not (Test-Path $StartLockFile)) { return $false }
  try {
    $lockPid = [int]((Get-Content $StartLockFile -Raw).Trim())
    if ($lockPid -eq $PID) { return $false }
    if (-not (Get-Process -Id $lockPid -ErrorAction SilentlyContinue)) {
      Remove-Item $StartLockFile -Force -ErrorAction SilentlyContinue
      return $false
    }
    return $true
  } catch { return $false }
}

function Get-HarnessWebviewTargets($svcStart, [string]$pidFile) {
  # WebView2 processes to close when stopping the service. ONLY processes that
  # started at or after the service start time are targeted - other
  # applications' WebView2 (browsers, Office, editors, ...) are never touched.
  # The recorded pid file is only used as a fallback when the start time is
  # unknown (e.g. logs were cleaned while the service kept running).
  $targets = @()
  if ($svcStart) {
    Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue | ForEach-Object {
      try { if ($_.StartTime -ge $svcStart) { $targets += [int]$_.Id } } catch {}
    }
    return @($targets | Select-Object -Unique)
  }
  if ($pidFile -and (Test-Path $pidFile)) {
    foreach ($wp in ((Get-Content $pidFile -Raw) -split ',')) {
      $wp = $wp.Trim()
      if ($wp -match '^\d+$') { $targets += [int]$wp }
    }
  }
  return @($targets | Select-Object -Unique)
}

function Stop-HarnessService {
  # full, THOROUGH cleanup of the harness (shared by the stop hotkey, the
  # version-check update path and -StopServiceOnly): recorded pid tree
  # (identity-checked), ALL harness-related node processes (root-scoped + any
  # path mentioning the harness), the "cmd /c pnpm dsh web" wrapper, and the
  # recorded WebView2 processes - then a post-stop audit that verifies NOTHING
  # harness-related is left occupying hardware.
  $svcPidFile = Join-Path $LogDir 'harness-service.pid'
  if (Test-Path $svcPidFile) {
    try {
      $sp = [int]((Get-Content $svcPidFile -Raw).Trim())
      if ($sp -gt 0) {
        $pi = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $sp) -ErrorAction SilentlyContinue
        if ($pi -and ($pi.Name -eq 'cmd.exe' -or ($pi.CommandLine -match 'pnpm|dsh'))) { & taskkill.exe /PID $sp /T /F 2>&1 | Out-Null }
      }
    } catch {}
  }
  # 1) harness node processes (any location)
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { Test-HarnessProcessCommandLine ([string]$_.CommandLine) } |
    ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
  # 2) the "cmd /c pnpm dsh web" wrapper itself (survives if the pid file is stale)
  Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pnpm dsh web' } |
    ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
  # 3) the harness's WebView2 GUI processes - ONLY those that started at or
  #    after the service start time (never other applications' WebView2)
  $wpFile = Join-Path $LogDir 'harness-webview.pids'
  $svcStartT = $null
  $stFile = Join-Path $LogDir 'harness-start-time.txt'
  if (Test-Path $stFile) { try { $svcStartT = [datetime]::Parse((Get-Content $stFile -Raw).Trim()) } catch {} }
  $webviewTargets = @(Get-HarnessWebviewTargets -svcStart $svcStartT -pidFile $wpFile)
  foreach ($wt in $webviewTargets) { & taskkill.exe /PID $wt /T /F 2>&1 | Out-Null }
  Remove-Item $svcPidFile -Force -ErrorAction SilentlyContinue
  # HARD layer: kill whatever is actually LISTENING on the harness ports
  Stop-HarnessByPort
  # post-stop audit: node + cmd wrapper + targeted WebView2 must all be gone
  Start-Sleep -Milliseconds 500
  $remaining = @()
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { Test-HarnessProcessCommandLine ([string]$_.CommandLine) } |
    ForEach-Object { $remaining += ('node pid ' + $_.ProcessId) }
  Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'pnpm dsh web' } |
    ForEach-Object { $remaining += ('cmd pid ' + $_.ProcessId) }
  foreach ($wt in $webviewTargets) {
    if (Get-Process -Id $wt -ErrorAction SilentlyContinue) { $remaining += ('webview2 pid ' + $wt) }
  }
  if ($remaining.Count -gt 0) { Log ("POST-STOP CHECK: leftover -> " + ($remaining -join '; ')) }
  else { Log 'POST-STOP CHECK: clean - no harness processes remain.' }
}

function Get-PortOwnerPids([int]$portNumber) {
  # PIDs of processes LISTENING on 127.0.0.1:$portNumber (netstat-based, no CIM)
  $pids = @()
  try {
    $lines = netstat -ano -p TCP | Select-String ("127\.0\.0\.1:" + $portNumber + "\s") | Select-String 'LISTENING'
    foreach ($l in $lines) {
      $parts = ($l.ToString() -split '\s+')
      $p = $parts[$parts.Count - 1]
      if ($p -match '^\d+$') { $pids += [int]$p }
    }
  } catch {}
  return @($pids | Select-Object -Unique)
}

function Stop-HarnessByPort {
  # HARD-stop layer (hard close): whatever process is actually LISTENING on the
  # harness web port(s) is force-killed. Works even when command-line matching
  # fails (e.g. the service was started with a relative path). The owner is only
  # killed when it looks like the harness chain (node with a harness marker, or
  # the cmd/pnpm wrapper) - an unrelated app that took the port is protected.
  $ports = @(3080, 54313)
  $cfgP = (Load-PortConfig).Port
  if ($cfgP -ge 1 -and ($ports -notcontains $cfgP)) { $ports += $cfgP }
  foreach ($hp in $ports) {
    foreach ($op in (Get-PortOwnerPids $hp)) {
      $pi = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $op) -ErrorAction SilentlyContinue
      $ours = $false
      if ($pi) {
        $cl = [string]$pi.CommandLine
        if ($pi.Name -eq 'node.exe' -and (Test-HarnessProcessCommandLine $cl)) { $ours = $true }
        elseif ($pi.Name -eq 'cmd.exe' -and ($cl -match 'pnpm dsh web')) { $ours = $true }
      }
      if ($ours) { & taskkill.exe /PID $op /T /F 2>&1 | Out-Null; Log ("[hard-stop] killed port " + $hp + " owner pid " + $op) }
      elseif ($pi) { Log ("[hard-stop] port " + $hp + " owner pid " + $op + " (" + $pi.Name + ") not recognized as harness - skipped") }
    }
  }
}

function Open-Browser {
  if ($NoPopup) { return }
  Start-Process $Url | Out-Null
}

# ---------- startup history: "total_seconds,port_seconds" per line ----------
function Get-StartupHistory {
  if (Test-Path $StartupHistoryFile) {
    $runs = @()
    foreach ($line in (Get-Content $StartupHistoryFile -ErrorAction SilentlyContinue)) {
      $parts = ($line -split ',')
      if ($parts.Count -ge 1 -and $parts[0] -match '^\d+$') {
        $runs += [pscustomobject]@{
          Total = [int]$parts[0]
          Port  = if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') { [int]$parts[1] } else { 0 }
        }
      }
    }
    return @($runs)
  }
  return @()
}

function Add-StartupHistory($totalSeconds, $portSeconds) {
  try {
    Add-Content -Path $StartupHistoryFile -Value ($totalSeconds.ToString() + ',' + $portSeconds.ToString())
    $all = @(Get-Content $StartupHistoryFile -ErrorAction SilentlyContinue | Select-Object -Last 20)
    Set-Content -Path $StartupHistoryFile -Value $all
  } catch {}
}

# Migrate legacy bare-second entries (e.g. "153") to the new "total,port" format
function Ensure-HistoryFormat {
  try {
    if (Test-Path $StartupHistoryFile) {
      $needsMigrate = $false
      foreach ($l in (Get-Content $StartupHistoryFile -ErrorAction SilentlyContinue)) {
        if ($l -match '^\d+$') { $needsMigrate = $true; break }
      }
      if ($needsMigrate) {
        $out = @()
        foreach ($l in (Get-Content $StartupHistoryFile -ErrorAction SilentlyContinue)) {
          if ($l -match '^\d+$') { $out += ($l + ',0') } else { $out += $l }
        }
        Set-Content -Path $StartupHistoryFile -Value $out
      }
    }
  } catch {}
}

function Get-StartupStats {
  # averages of the recorded runs (the history file keeps the latest ~20);
  # PortToReady is computed from runs that captured the port-up milestone (port > 0)
  $runs = Get-StartupHistory
  $count = $runs.Count
  $total = 0; $portToReady = 0
  if ($count -gt 0) {
    $ts = @($runs | ForEach-Object { $_.Total })
    if ($ts.Count -gt 0) { $total = [int][Math]::Round(($ts | Measure-Object -Average).Average) }
    $pr = @($runs | Where-Object { $_.Port -gt 0 } | ForEach-Object { $_.Total - $_.Port })
    if ($pr.Count -gt 0) { $portToReady = [int][Math]::Round(($pr | Measure-Object -Average).Average) }
  }
  return @{ Total = $total; PortToReady = $portToReady; Count = $count }
}

# ---------- progress window state (pure logic, unit-testable) ----------
# Live monitoring: elapsed time, real stage transitions (process -> port -> HTTP),
# service-log activity, and a dynamically updated ETA from measured history.
# With no history yet the estimate honestly says "monitoring, cannot predict" and
# the bar is indeterminate (Marquee) instead of inventing a number.
function Get-ProgressState {
  param(
    [int]$Elapsed,
    [bool]$PortUp,
    [bool]$HttpUp,
    [int]$MedianTotal,          # median total startup seconds from history (0 = none)
    [int]$MedianPortToReady,    # median port->ready seconds from history (0 = none)
    [int]$PortUpElapsed,        # elapsed seconds when the port was first observed (0 = not yet)
    [int]$HistoryCount,         # number of recorded runs
    [bool]$LogActive,           # is the service log file still growing
    [bool]$Failed,
    [string]$FailMsg,
    [int]$TimeoutSeconds
  )
  if ($HttpUp) { return @{ Done = $true; Stage = ''; Eta = ''; Pct = 100; Marquee = $false } }
  if ($Failed) {
    return @{ Done = $false; Stage = $FailMsg; Eta = T 'progressErrorLog'; Pct = 100; Marquee = $false }
  }

  $monitor = if ($LogActive) { T 'progressMonitorActive' } else { T 'progressMonitorIdle' }

  $stage = ''
  $eta = ''
  $pct = 0
  $marquee = $false
  $elapsedTxt = [string]::Format((T 'progressElapsed'), $Elapsed)
  $sampleTxt = [string]::Format((T 'progressEtaSample'), $HistoryCount)

  if ($PortUp) {
    # ---- phase 2: port ready, page initializing ----
    $stage = ([string]::Format((T 'progressPortReady'), $Port) + '（' + $monitor + '）')
    $phaseElapsed = $Elapsed - $PortUpElapsed
    if ($MedianPortToReady -gt 0) {
      $remaining = $MedianPortToReady - $phaseElapsed
      if ($remaining -le 0) { $eta = ($elapsedTxt + '，' + (T 'progressAboutReady')) }
      else { $eta = ($elapsedTxt + '，' + [string]::Format((T 'progressPageInitEta'), $remaining) + $sampleTxt) }
      $pct = 85 + [Math]::Min(14, [int](14 * $phaseElapsed / [Math]::Max($MedianPortToReady, 1)))
    } else {
      $eta = ($elapsedTxt + '，' + (T 'progressPageInit'))
      $pct = 90
    }
  } elseif ($MedianTotal -gt 0) {
    # ---- phase 1 with history: count down from the measured average ----
    $stage = ((T 'progressStarting') + '（' + $monitor + '）')
    $ratio = [Math]::Min($Elapsed / $MedianTotal, 1.0)
    $pct = [int](20 + 62 * $ratio)
    $remaining = $MedianTotal - $Elapsed
    if ($remaining -le 0) { $eta = ($elapsedTxt + '，' + (T 'progressOverAvg')) }
    else { $eta = ($elapsedTxt + '，' + [string]::Format((T 'progressEta'), $remaining) + $sampleTxt) }
  } else {
    # ---- phase 1 without history: honest live monitoring, indeterminate bar ----
    $stage = ((T 'progressStarting') + '（' + $monitor + '）')
    $eta = ($elapsedTxt + '，' + (T 'progressNoHistory'))
    $marquee = $true
  }

  return @{ Done = $false; Stage = $stage; Eta = $eta; Pct = $pct; Marquee = $marquee }
}

# ---------- progress window ----------
function Show-StartupProgress {
  param(
    [System.Diagnostics.Process]$ServiceProc,   # $null in 'wait' mode
    [datetime]$StartTime,
    [int]$MedianTotal = 0,
    [int]$MedianPortToReady = 0,
    [int]$HistoryCount = 0,
    [string]$PortUpMarker = '',                  # file to record when the port is first seen
    [string]$ActivityLog = '',                   # service stdout log, monitored for live activity
    [string]$Mode = 'start',                     # 'start' = we launched it, 'wait' = external service starting
    [int]$TimeoutSeconds = 180
  )
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null

  $form = New-Object System.Windows.Forms.Form
  $form.Text = T 'progressTitle'
  Set-FormIcon $form
  $form.ClientSize = New-Object System.Drawing.Size(400, 160)
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.ControlBox = $true
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.TopMost = $true
  $form.ShowInTaskbar = $false

  # keep the progress window on top of the browser and give it focus when it appears
  $form.Add_Shown({ $form.Activate(); $form.BringToFront() })

  $stage = New-Object System.Windows.Forms.Label
  $stage.Location = New-Object System.Drawing.Point(15, 12)
  $stage.Size = New-Object System.Drawing.Size(370, 22)
  $stage.Text = T 'progressStarting'
  $form.Controls.Add($stage)

  $bar = New-Object System.Windows.Forms.ProgressBar
  $bar.Location = New-Object System.Drawing.Point(15, 40)
  $bar.Size = New-Object System.Drawing.Size(370, 20)
  $bar.Minimum = 0
  $bar.Maximum = 100
  $form.Controls.Add($bar)

  $eta = New-Object System.Windows.Forms.Label
  $eta.Location = New-Object System.Drawing.Point(15, 66)
  $eta.Size = New-Object System.Drawing.Size(370, 22)
  $eta.Text = ''
  $form.Controls.Add($eta)

  $hint = New-Object System.Windows.Forms.Label
  $hint.Location = New-Object System.Drawing.Point(15, 92)
  $hint.Size = New-Object System.Drawing.Size(370, 20)
  $hint.Text = T 'progressCloseHint'
  $hint.ForeColor = [System.Drawing.Color]::Gray
  $hint.Font = New-Object System.Drawing.Font('Microsoft YaHei', 8.25)
  $form.Controls.Add($hint)

  # Event-handler closures cannot update function variables in PowerShell, so all
  # cross-tick state uses $script: variables and the result uses the form's Tag.
  $script:dialogPortSeen = $false
  $script:dialogPortUpElapsed = 0
  $script:dialogLastLogSize = -1L

  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 1000
  $timer.Add_Tick({
    try {
      $elapsed = [int]((Get-Date) - $StartTime).TotalSeconds
      $httpUp = Test-HarnessUp
      $portUp = Test-PortListening

      # record the real port-up milestone (elapsed seconds) for this run's history
      if ($portUp -and -not $script:dialogPortSeen) {
        $script:dialogPortSeen = $true
        $script:dialogPortUpElapsed = $elapsed
        if ($PortUpMarker) { try { Set-Content -Path $PortUpMarker -Value ([string]$elapsed) -ErrorAction Stop } catch {} }
      }

      # live activity signal: is the service log file still growing?
      $logActive = $false
      if ($ActivityLog -and (Test-Path $ActivityLog)) {
        try {
          $sz = (Get-Item $ActivityLog).Length
          $logActive = ($sz -ne $script:dialogLastLogSize)
          $script:dialogLastLogSize = $sz
        } catch {}
      }

      $failed = $false
      $failMsg = ''
      if ($Mode -eq 'start' -and $ServiceProc) {
        try { $ServiceProc.Refresh(); $exited = $ServiceProc.HasExited } catch { $exited = $false }
        # a parent that exits early is NOT a failure if the service is already
        # up (HTTP responding) - only "process exited AND HTTP down" is a failure
        if ($exited -and -not $httpUp) { $failed = $true; $failMsg = T 'progressFailedExit' }
      }
      if ($elapsed -ge $TimeoutSeconds) { $failed = $true; $failMsg = [string]::Format((T 'progressTimeout'), $TimeoutSeconds) }
      if ($failed) { $form.Tag = @{ Ready = $false; Failed = $true } }

      $st = Get-ProgressState -Elapsed $elapsed -PortUp $portUp -HttpUp $httpUp -MedianTotal $MedianTotal -MedianPortToReady $MedianPortToReady -PortUpElapsed $script:dialogPortUpElapsed -HistoryCount $HistoryCount -LogActive $logActive -Failed $failed -FailMsg $failMsg -TimeoutSeconds $TimeoutSeconds
      if ($st.Done) { $form.Tag = @{ Ready = $true; Failed = $false }; $timer.Stop(); $form.Close(); return }

      $stage.Text = $st.Stage
      $eta.Text = $st.Eta
      if ($st.Marquee) { $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee }
      else { $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks; $bar.Value = $st.Pct }
    } catch {
      # never let a tick error freeze the window silently
      try { Log ('[dialog tick error] ' + $_.Exception.Message) } catch {}
    }
  })

  $timer.Start()   # IMPORTANT: without Start() the window would never update or auto-close
  $null = $form.ShowDialog()
  $timer.Stop()
  $timer.Dispose()

  # result passed via the form's Tag (closures cannot update function variables)
  $ready = $false; $failed = $false
  $tag = $form.Tag
  if ($tag) { $ready = $tag.Ready; $failed = $tag.Failed }
  $form.Dispose()

  # defensive: if the service is already up by the time the dialog closed, treat as ready
  if (-not $ready -and -not $failed -and (Test-HarnessUp)) { $ready = $true }
  return @{ Ready = $ready; Failed = $failed }
}

# ---------- silent wait (used for -NoPopup and when the dialog is closed early) ----------
function Wait-ForReady {
  param(
    [System.Diagnostics.Process]$ServiceProc,
    [int]$TimeoutSeconds = 180,
    [datetime]$StartTime,
    [string]$PortUpMarker = ''
  )
  $portSeen = $false
  for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
    if (Test-HarnessUp) { return 'ready' }
    if (-not $portSeen -and $PortUpMarker) {
      if (Test-PortListening) {
        $portSeen = $true
        try { Set-Content -Path $PortUpMarker -Value ([string][int]((Get-Date) - $StartTime).TotalSeconds) -ErrorAction Stop } catch {}
      }
    }
    if ($ServiceProc) {
      try { $ServiceProc.Refresh(); $exited = $ServiceProc.HasExited } catch { $exited = $false }
      if ($exited) { return 'failed' }
    }
    Start-Sleep -Seconds 1
  }
  return 'timeout'
}

# ---------- hotkey listener ----------
function Get-ListenerProcess {
  Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*Start-HotkeyListener.ps1*' }
}

function Ensure-Listener {
  if (Get-ListenerProcess) { return $true }
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$ListenerScript) `
    -WindowStyle Hidden | Out-Null
  return $false
}

function Get-ActiveHotkeyLabel {
  # Only trust the registration line of the listener that is still alive,
  # so stale log entries from earlier (now dead) listeners are ignored.
  $lp = Get-ListenerProcess | Select-Object -First 1
  if ($lp -and (Test-Path $HotkeyLog)) {
    $m = Select-String -Path $HotkeyLog -Pattern ("Hotkey registered: (.+) \(pid " + [regex]::Escape([string]$lp.ProcessId) + "\)") -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($m) { return $m.Matches[0].Groups[1].Value }
  }
  return $null
}

function Finish-Ready($startedByUs) {
  $hk = Get-ActiveHotkeyLabel
  if (-not $hk) { $hk = T 'popupHotkeyFallback' }
  if ($startedByUs) {
    Show-Popup ([string]::Format((T 'popupStarted'), $Url, $LogDir, $hk))
  } else {
    Show-Popup ([string]::Format((T 'popupReady'), $Url, $hk))
  }
  Log 'Done.'
  exit 0
}

# =====================================================================
# ENVIRONMENT PREFLIGHT + AUTO-UPDATE
# - Checks Node.js (>= $NodeMinVersion) and pnpm; installs via domestic
#   mirrors if missing/too old (a portable node under tools\ so the system
#   install is never touched).
# - Checks the local harness source (avoids duplicate installs) and compares
#   its version with the latest GitHub tag. If an update exists the SEPARATE
#   update UI asks for confirmation; when everything is up to date the check
#   is fully silent (no UI).
# - On any failure the SEPARATE error UI shows where/why it stopped and how
#   to fix it, and offers authorized cleanup (clear + reinstall, or clear +
#   exit); half-installed content is never left behind.
# =====================================================================
$NodeMinVersion = '22.19.0'
$NodeMirrorBase = 'https://npmmirror.com/mirrors/node/'
$NpmMirrorRegistry = 'https://registry.npmmirror.com'
$GithubOwner = 'deepseek-ai'
$GithubRepoName = 'deepseek-harness'
$GithubApi = 'https://api.github.com/repos/' + $GithubOwner + '/' + $GithubRepoName
$GithubCodeloadBase = 'https://codeload.github.com/' + $GithubOwner + '/' + $GithubRepoName + '/zip'
$GithubCodeload = $GithubCodeloadBase + '/refs/heads/main'
$LogRetentionDays = 7      # delete log files older than this
$LogMaxSizeMB = 5          # rotate log files larger than this
$ToolsDir = Join-Path $DataDir 'tools'
$PortableNodeDir = Join-Path $ToolsDir 'node'
$StagingDir = Join-Path $DataDir '.update-staging'
$PreflightStateFile = Join-Path $LogDir 'preflight-state.txt'

function Test-VersionAtLeast($installed, $required) {
  # numeric semver-ish compare; prerelease parts are ignored
  try {
    $a = @(($installed -replace '^v','') -split '\.'); $b = @($required -split '\.')
    $n = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $n; $i++) {
      $av = 0; $bv = 0
      if ($i -lt $a.Count) { $av = [int](($a[$i] -split '-')[0] -replace '[^0-9]','') }
      if ($i -lt $b.Count) { $bv = [int](($b[$i] -split '-')[0] -replace '[^0-9]','') }
      if ($av -gt $bv) { return $true }
      if ($av -lt $bv) { return $false }
    }
    return $true
  } catch { return $false }
}

function Get-NodeVersion {
  try { $v = (& node --version 2>$null); if ($v -match 'v?([0-9]+\.[0-9]+\.[0-9]+)') { return $matches[1] } } catch {}
  $pn = Join-Path $PortableNodeDir 'node.exe'
  if (Test-Path $pn) { try { $v = (& $pn --version 2>$null); if ($v -match 'v?([0-9]+\.[0-9]+\.[0-9]+)') { return $matches[1] } } catch {} }
  return ''
}

function Get-PnpmVersion {
  try { $v = (& pnpm --version 2>$null); if ($v -match '([0-9]+\.[0-9]+\.[0-9]+)') { return $matches[1] } } catch {}
  return ''
}

function Get-LocalHarnessVersion {
  $pkg = Join-Path $DshRoot 'package.json'
  if (Test-Path $pkg) {
    try { return ((Get-Content $pkg -Raw | ConvertFrom-Json).version) } catch {}
  }
  return ''
}

function Get-LatestHarnessVersion {
  # GitHub API tags; returns $null if unreachable (the check is skipped silently)
  try {
    $tags = Invoke-RestMethod -Uri ($GithubApi + '/tags?per_page=10') -TimeoutSec 8 -Headers @{ 'User-Agent' = 'dsh-launcher' }
    $names = @($tags | ForEach-Object { $_.name } | Where-Object { $_ -match '^v?[0-9]' })
    if ($names.Count -eq 0) { return $null }
    $best = $names[0]
    foreach ($nm in $names) { if (-not (Test-VersionAtLeast ($best -replace '^v','') ($nm -replace '^v',''))) { $best = $nm } }
    return ($best -replace '^v','')
  } catch { return $null }
}

function Install-PortableNode {
  try {
    New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null
    $version = ''
    try {
      $idx = Invoke-RestMethod -Uri ($NodeMirrorBase + 'index.json') -TimeoutSec 10
      $v22 = @($idx | Where-Object { $_.version -match '^v22\.' -and $_.version -notmatch '-' } | ForEach-Object { $_.version })
      if ($v22.Count -gt 0) { $version = ($v22 | Sort-Object { [int](($_ -split '\.')[1]) } -Descending | Select-Object -First 1) }
    } catch {}
    if (-not $version) { $version = 'v' + $NodeMinVersion }
    $zipUrl = $NodeMirrorBase + $version + '/node-' + $version + '-win-x64.zip'
    $zipPath = Join-Path $ToolsDir ('node-' + $version + '-win-x64.zip')
    Log ("[preflight] downloading portable node " + $version)
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 300
    $extractTo = Join-Path $ToolsDir ('node-' + $version + '-win-x64')
    if (Test-Path $extractTo) { Remove-Item $extractTo -Recurse -Force }
    Expand-Archive -Path $zipPath -DestinationPath $ToolsDir -Force
    if (Test-Path $PortableNodeDir) { Remove-Item $PortableNodeDir -Recurse -Force }
    Move-Item -Path $extractTo -Destination $PortableNodeDir
    Remove-Item $zipPath -Force
    Add-Content -Path $PreflightStateFile -Value $PortableNodeDir -Encoding ASCII
    return (Test-Path (Join-Path $PortableNodeDir 'node.exe'))
  } catch {
    Log ("[preflight] portable node install failed: " + $_.Exception.Message)
    return $false
  }
}

function Ensure-NodeAndPnpm {
  $nodeV = Get-NodeVersion
  if ($nodeV -and (Test-VersionAtLeast $nodeV $NodeMinVersion)) {
    Log ("[preflight] node " + $nodeV + " ok")
  } else {
    Log ("[preflight] node '" + $nodeV + "' < " + $NodeMinVersion + "; installing portable node...")
    if (-not (Install-PortableNode)) { return 'node-install-failed' }
    $env:Path = $PortableNodeDir + ';' + $env:Path
    Log '[preflight] portable node ready'
  }
  $pnpmV = Get-PnpmVersion
  if ($pnpmV) {
    Log ("[preflight] pnpm " + $pnpmV + " ok")
  } else {
    Log '[preflight] pnpm missing; installing LOCALLY under data\tools\pnpm (system npm untouched)...'
    try {
      $pnpmPrefix = Join-Path $ToolsDir 'pnpm'
      New-Item -ItemType Directory -Path $pnpmPrefix -Force | Out-Null
      & npm install -g pnpm --prefix $pnpmPrefix --registry $NpmMirrorRegistry --no-fund --no-audit 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { return 'pnpm-install-failed' }
      $env:Path = (Join-Path $pnpmPrefix 'node_modules\.bin') + ';' + $pnpmPrefix + ';' + $env:Path
    } catch { return 'pnpm-install-failed' }
    if (-not (Get-PnpmVersion)) { return 'pnpm-install-failed' }
    Log '[preflight] pnpm installed (local, data\tools\pnpm)'
  }
  return $true
}

function Get-BytesSha256($bytes) {
  # SHA-256 hex of a byte array (PS 5.1 compatible; Get-FileHash -InputStream needs PS6+)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') } finally { $sha.Dispose() }
  } catch { return '' }
}

function Get-GitHubCommitSha {
  # tip commit SHA of the default branch, used to pin the download
  try {
    $c = Invoke-RestMethod -Uri ($GithubApi + '/commits/main') -TimeoutSec 10 -Headers @{ 'User-Agent' = 'dsh-launcher' }
    return [string]$c.sha
  } catch { return '' }
}

function Clean-Logs {
  # log rotation: delete logs older than $LogRetentionDays and rotate files
  # larger than $LogMaxSizeMB. Files the running service is writing to
  # (harness-web.*.log) are skipped while the service is up (TCP probe:
  # fast, ~200ms max, so launcher startup is not slowed down).
  try {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    $sizeLimit = $LogMaxSizeMB * 1MB
    $active = Test-PortListening -TimeoutMs 200
    Get-ChildItem -Path $LogDir -File -ErrorAction SilentlyContinue | ForEach-Object {
      $isWebLog = ($_.Name -like 'harness-web.*.log')
      if ($active -and $isWebLog) { return }   # never touch logs being written now
      if ($_.LastWriteTime -lt $cutoff) {
        try { Remove-Item $_.FullName -Force -ErrorAction Stop; Log ("[log-rotate] removed old: " + $_.Name) } catch {}
      } elseif ($_.Length -gt $sizeLimit) {
        try {
          $old = $_.FullName + '.1'
          Remove-Item $old -Force -ErrorAction SilentlyContinue
          Move-Item $_.FullName $old -Force
          Log ("[log-rotate] rotated: " + $_.Name)
        } catch {}
      }
    }
    # legacy: pre-restructure launchers kept logs in <project root>\logs; once the
    # service is stopped the files are unlocked, so remove the whole legacy folder
    # (silently skipped while the running service still holds the files)
    try {
      $legacyLogs = Join-Path (Split-Path $ScriptDir -Parent) 'logs'
      if (Test-Path $legacyLogs) {
        Remove-Item $legacyLogs -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $legacyLogs)) { Log '[log-rotate] removed legacy logs folder' }
      }
    } catch {}
  } catch {}
}

function Update-HarnessSource {
  # download the latest source zip from codeload (github.com itself is often
  # blocked in CN; codeload + api usually work), extract and swap in place.
  # Supply-chain hardening: the download is pinned to the tip commit SHA from
  # the GitHub API and the extracted package.json hash is verified against the
  # same commit's content returned by the API (tamper detection).
  try {
    $sha = Get-GitHubCommitSha
    Log ("[preflight] downloading harness source (codeload) commit=" + $(if ($sha) { $sha.Substring(0, [Math]::Min(12, $sha.Length)) } else { 'unknown' }))
    $zip = Join-Path $LogDir 'harness-update.zip'
    if ($sha) { Invoke-WebRequest -Uri ($GithubCodeloadBase + '/' + $sha) -OutFile $zip -UseBasicParsing -TimeoutSec 600 }
    else { Invoke-WebRequest -Uri $GithubCodeload -OutFile $zip -UseBasicParsing -TimeoutSec 600 }
    if (Test-Path $StagingDir) { Remove-Item $StagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $StagingDir -Force
    Remove-Item $zip -Force
    $src = Get-ChildItem -Path $StagingDir -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName 'package.json'))) {
      Log '[preflight] downloaded source is invalid'
      return $false
    }
    # supply-chain verification: package.json SHA-256 vs the pinned commit's content
    if ($sha) {
      try {
        $localHash = (Get-FileHash -Path (Join-Path $src.FullName 'package.json') -Algorithm SHA256).Hash
        $apiPkg = Invoke-RestMethod -Uri ($GithubApi + '/contents/package.json?ref=' + $sha) -TimeoutSec 10 -Headers @{ 'User-Agent' = 'dsh-launcher' }
        $b64 = ([string]$apiPkg.content) -replace '\s', ''
        $expectedHash = Get-BytesSha256 ([Convert]::FromBase64String($b64))
        if ($localHash -ne $expectedHash) {
          Log ("[preflight] SECURITY: package.json hash mismatch (download tampered?) local=" + $localHash + " expected=" + $expectedHash)
          return $false
        }
        Log ("[preflight] download verified: package.json sha256 " + $localHash.Substring(0, 12) + "... matches commit " + $sha.Substring(0, 8))
      } catch {
        Log ('[preflight] download verification skipped (API unavailable): ' + $_.Exception.Message)
      }
    }
    if (Test-Path $DshRoot) {
      $bak = $DshRoot + '.bak-' + (Get-Date -Format 'yyyyMMddHHmmss')
      Rename-Item -Path $DshRoot -NewName (Split-Path $bak -Leaf)
      Add-Content -Path $PreflightStateFile -Value $bak -Encoding ASCII
    }
    Move-Item -Path $src.FullName -Destination $DshRoot
    Add-Content -Path $PreflightStateFile -Value $StagingDir -Encoding ASCII
    return $true
  } catch {
    Log ("[preflight] source update failed: " + $_.Exception.Message)
    return $false
  }
}

function Build-Harness {
  try {
    Log '[preflight] running pnpm install...'
    Push-Location $DshRoot
    try {
      & pnpm install 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { return $false }
      Log '[preflight] running pnpm run build...'
      & pnpm run build 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { return $false }
    } finally { Pop-Location }
    return $true
  } catch { return $false }
}

function Clean-PreflightArtifacts {
  # remove/restore only what THIS run pulled or installed; never the working copy
  if (Test-Path $PreflightStateFile) {
    foreach ($p in (Get-Content $PreflightStateFile -ErrorAction SilentlyContinue)) {
      if (-not $p) { continue }
      if (($p -like '*.bak-*') -and (Test-Path $p) -and -not (Test-Path $DshRoot)) {
        # the swap moved the original away and the new copy is broken -> restore it
        try { Rename-Item -Path $p -NewName (Split-Path $DshRoot -Leaf) -ErrorAction Stop; continue } catch {}
      }
      if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item $PreflightStateFile -Force -ErrorAction SilentlyContinue
  }
  Remove-Item $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $LogDir 'harness-update.zip') -Force -ErrorAction SilentlyContinue
}

# =====================================================================
# ROLLBACK SAFETY NET (兜底方案)
# Guarantee: the service must always be able to start. After an update the
# previous version is kept as .bak-<ts> until the new version is CONFIRMED
# serving HTTP. On any failure (build or start) the previous working version
# is restored automatically and the service is started from it; once the new
# version is confirmed, the backup and any failed leftovers are dropped.
# =====================================================================
function Get-PreviousHarnessBackup {
  # most recent rollback backup for the current source dir (.bak-<ts>);
  # it exists only while an update is pending confirmation
  $leaf = Split-Path $DshRoot -Leaf
  return (Get-ChildItem -Path (Split-Path $DshRoot -Parent) -Directory -Filter ($leaf + '.bak-*') -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Restore-PreviousHarness {
  # move the broken new source aside (.failed-<ts>) and restore the previous
  # version from .bak-<ts> so the service can always start
  $bak = Get-PreviousHarnessBackup
  if (-not $bak) { Log '[rollback] no previous backup found; nothing to restore.'; return $false }
  try {
    if (Test-Path $DshRoot) {
      $failed = $DshRoot + '.failed-' + (Get-Date -Format 'yyyyMMddHHmmss')
      Rename-Item -Path $DshRoot -NewName (Split-Path $failed -Leaf)
      Log ("[rollback] broken new source moved to " + (Split-Path $failed -Leaf))
    }
    Rename-Item -Path $bak.FullName -NewName (Split-Path $DshRoot -Leaf)
    Log ('[rollback] restored previous version from ' + $bak.Name)
    return $true
  } catch {
    Log ('[rollback] restore failed: ' + $_.Exception.Message)
    return $false
  }
}

function Confirm-HarnessUpdate {
  # called once the (possibly new) version is confirmed serving HTTP:
  # drop failed leftovers and, if a backup is still pending, the backup too
  $leaf = Split-Path $DshRoot -Leaf
  $parent = Split-Path $DshRoot -Parent
  Get-ChildItem -Path $parent -Directory -Filter ($leaf + '.failed-*') -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Log ("[rollback] removed failed leftover " + $_.Name) }
  if (Get-PreviousHarnessBackup) {
    Get-ChildItem -Path $parent -Directory -Filter ($leaf + '.bak-*') -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue; Log ("[rollback] update confirmed; removed backup " + $_.Name) }
    Remove-Item $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Start-HarnessOnce {
  # one cold-start attempt: clean stale processes/logs, spawn "pnpm dsh web"
  # hidden, then wait for the web UI (progress window unless -NoPopup).
  # Returns 'ready' when the service is up, 'starting' when ANOTHER instance is
  # already starting it (we must never spawn a 2nd one), 'failed' otherwise.
  Remove-Item $OutLog, $ErrLog, $ServicePidFile, $PortUpMarker -Force -ErrorAction SilentlyContinue
  Stop-StaleHarnessProcesses
  Start-Sleep -Seconds 2
  # race guard: never start a second instance. If the service is up, or another
  # instance is already starting it (port/process/lock visible), just wait for it.
  # NOTE: explicit parentheses - `-TimeoutMs 200 -or ...` would parse as the
  # -TimeoutMs argument value and silently drop the process check.
  if (Test-ServiceStartLocked) {
    Log 'Another launcher is starting the service (start lock held); waiting for it.'
    return 'starting'
  }
  if (Test-HarnessUp) { Log 'Service already up (another instance).'; return 'ready' }
  if ((Test-PortListening -TimeoutMs 200) -or (Test-ServiceProcess)) {
    Log 'Service is being started by another instance; waiting for it instead of starting a 2nd one.'
    return 'starting'
  }
  # pre-flight dependency check: pnpm (and Node) MUST exist before spawning.
  # Run-Preflight is skipped in -NoPopup / warm-up mode, so this is the
  # guarantee that the service can never fail with "pnpm is not recognized".
  $envOk = Ensure-NodeAndPnpm
  if ($envOk -ne $true) {
    Log ("[preflight] node/pnpm unavailable (" + $envOk + "); aborting start.")
    return 'failed'
  }
  # acquire the start lock (only ONE launcher may spawn the service cmd)
  try { [System.IO.File]::WriteAllText($StartLockFile, [string]$PID) } catch {}
  Log ("Starting: pnpm dsh web in " + $DshRoot)
  $script:startTime = Get-Date
  $script:p = Start-Process -FilePath 'cmd.exe' `
    -ArgumentList @('/c','pnpm','dsh','web','--port',"$Port") `
    -WorkingDirectory $DshRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrLog `
    -PassThru
  [System.IO.File]::WriteAllText($ServicePidFile, [string]$script:p.Id)
  Set-Content -Path (Join-Path $LogDir 'harness-start-time.txt') -Value $script:startTime.ToString('o') -Encoding ASCII
  if ($NoPopup) {
    $s = Wait-ForReady -ServiceProc $script:p -TimeoutSeconds 180 -StartTime $script:startTime -PortUpMarker $PortUpMarker
    if ($s -eq 'ready') { return 'ready' }
    return 'failed'
  }
  $res = Show-StartupProgress -ServiceProc $script:p -StartTime $script:startTime -MedianTotal $stats.Total -MedianPortToReady $stats.PortToReady -HistoryCount $stats.Count -PortUpMarker $PortUpMarker -ActivityLog $OutLog -Mode 'start' -TimeoutSeconds 180
  if ($res.Ready) { return 'ready' }
  if ($res.Failed) { return 'failed' }
  $s = Wait-ForReady -ServiceProc $script:p -TimeoutSeconds 180 -StartTime $script:startTime -PortUpMarker $PortUpMarker  # dialog closed early
  if ($s -eq 'ready') { return 'ready' }
  return 'failed'
}

function Show-UpdateDialog {
  param([string]$Message, [string]$ButtonLabel = (T 'updateConfirm'), [string]$Title = (T 'updateTitle'))
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null
  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  Set-FormIcon $form
  $form.ClientSize = New-Object System.Drawing.Size(440, 150)
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Add_Shown({ $form.Activate(); $form.BringToFront() })
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Location = New-Object System.Drawing.Point(15, 15)
  $lbl.Size = New-Object System.Drawing.Size(410, 65)
  $lbl.Text = $Message
  $form.Controls.Add($lbl)
  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Location = New-Object System.Drawing.Point(250, 105)
  $btnOk.Size = New-Object System.Drawing.Size(85, 28)
  $btnOk.Text = $ButtonLabel
  $form.Controls.Add($btnOk)
  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Location = New-Object System.Drawing.Point(345, 105)
  $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
  $btnCancel.Text = T 'updateCancel'
  $btnCancel.DialogResult = 'Cancel'
  $form.Controls.Add($btnCancel)
  $btnOk.Add_Click({ $form.Tag = 'ok'; $form.Close() })
  $null = $form.ShowDialog()
  $result = ($form.Tag -eq 'ok')
  $form.Dispose()
  return $result
}

function Show-ErrorDialog {
  param([string]$Step, [string]$ErrorText, [string]$FixText)
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null
  $form = New-Object System.Windows.Forms.Form
  $form.Text = T 'errorTitle'
  Set-FormIcon $form
  $form.ClientSize = New-Object System.Drawing.Size(480, 270)
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Add_Shown({ $form.Activate(); $form.BringToFront() })
  $txt = ([string]::Format((T 'errorStep'), $Step) + "`n`n" + [string]::Format((T 'errorText'), $ErrorText) + "`n`n" + [string]::Format((T 'errorFix'), $FixText) + "`n`n" + (T 'errorCleanHint'))
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Location = New-Object System.Drawing.Point(15, 12)
  $lbl.Size = New-Object System.Drawing.Size(450, 150)
  $lbl.Text = $txt
  $form.Controls.Add($lbl)
  $btnReinstall = New-Object System.Windows.Forms.Button
  $btnReinstall.Location = New-Object System.Drawing.Point(120, 225)
  $btnReinstall.Size = New-Object System.Drawing.Size(110, 30)
  $btnReinstall.Text = T 'errorReinstall'
  $form.Controls.Add($btnReinstall)
  $btnCleanExit = New-Object System.Windows.Forms.Button
  $btnCleanExit.Location = New-Object System.Drawing.Point(240, 225)
  $btnCleanExit.Size = New-Object System.Drawing.Size(110, 30)
  $btnCleanExit.Text = T 'errorCleanExit'
  $form.Controls.Add($btnCleanExit)
  $btnExit = New-Object System.Windows.Forms.Button
  $btnExit.Location = New-Object System.Drawing.Point(360, 225)
  $btnExit.Size = New-Object System.Drawing.Size(100, 30)
  $btnExit.Text = T 'errorExit'
  $form.Controls.Add($btnExit)
  $btnReinstall.Add_Click({ $form.Tag = 'reinstall'; $form.Close() })
  $btnCleanExit.Add_Click({ $form.Tag = 'clean-exit'; $form.Close() })
  $btnExit.Add_Click({ $form.Tag = 'exit'; $form.Close() })
  $null = $form.ShowDialog()
  $result = $form.Tag
  $form.Dispose()
  return $result
}

function Handle-PreflightError($step, $errText, $fixText) {
  $choice = Show-ErrorDialog -Step $step -ErrorText $errText -FixText $fixText
  if ($choice -eq 'reinstall') {
    Clean-PreflightArtifacts
    Log '[preflight] user chose: clean + reinstall'
    return 'reinstall'
  } elseif ($choice -eq 'clean-exit') {
    Clean-PreflightArtifacts
    Log '[preflight] user chose: clean + exit'
    return 'clean-exit'
  }
  Log '[preflight] user chose: exit without cleanup'
  return 'exit'
}

function Run-Preflight {
  # returns $true to proceed, 'reinstall' to retry, or $false to stop
  if ($NoPopup) { Log '[preflight] skipped in NoPopup test mode.'; return $true }

  $envResult = Ensure-NodeAndPnpm
  if ($envResult -ne $true) {
    return Handle-PreflightError -Step (T 'errStepEnv') -ErrorText ([string]::Format((T 'errTextNode'), $envResult)) -FixText (T 'errFixNode')
  }

  $localV = Get-LocalHarnessVersion
  if (-not $localV) {
    # first run: no local harness source -> install from GitHub
    Log '[preflight] no local harness source found; offering first-run install.'
    if (Show-UpdateDialog -Title (T 'updateInstallTitle') -Message ([string]::Format((T 'updateInstallMsg'), $DshRoot)) -ButtonLabel (T 'updateInstall')) {
      if (-not (Update-HarnessSource)) {
        return Handle-PreflightError -Step (T 'errStepInstall') -ErrorText (T 'errTextPull') -FixText ([string]::Format((T 'errFixPull'), $DshRoot))
      }
      if (-not (Build-Harness)) {
        # 兜底方案: if a previous-version backup exists, restore it and continue
        if (Restore-PreviousHarness) {
          Log '[preflight] build failed; rolled back to previous version.'
          if (-not $NoPopup) { Show-Popup (T 'rollbackBuildFailed') (T 'rollbackTitle') }
        } else {
          return Handle-PreflightError -Step (T 'errStepInstallBuild') -ErrorText (T 'errTextBuild') -FixText (T 'errFixBuild')
        }
      }
      $localV = Get-LocalHarnessVersion
    } else {
      Log '[preflight] first-run install declined; launcher exits.'
      return $false
    }
  }

  # the GitHub version check is NOT done here (it runs in the background via
  # -CheckVersionOnly after launch), so startup is not delayed by the network.

  Run-SecurityCheck
  return $true
}

function Run-SecurityCheck {
  # fast, silent security self-check: localhost-only binding + folder ACL hardening
  try {
    # 1) verify the harness ports bind to 127.0.0.1 only (no external exposure)
    $listeners = netstat -ano | Select-String 'LISTENING' | Select-String ':3080|:54313'
    $bad = @($listeners | Where-Object { $_ -notmatch '127\.0\.0\.1' })
    if ($bad.Count -gt 0) {
      Log ("[security] WARNING: harness port not bound to 127.0.0.1 only -> " + ($bad -join '; '))
    } else {
      Log '[security] harness ports bound to 127.0.0.1 only (no external exposure).'
    }
    # 2) folder ACL audit - READ-ONLY. The launcher never modifies permissions
    #    (a permanent ACL change could lock files out or break cloud sync);
    #    it only reports whether the folder is broadly accessible.
    try {
      $aclOut = (& icacls $ScriptDir 2>&1 | Out-String)
      if ($aclOut -match 'Everyone|BUILTIN\\Users') {
        Log '[security] INFO: folder ACL includes Everyone/Users (broad). Harden manually if this machine is shared.'
      } else {
        Log '[security] folder ACL looks restrictive (no Everyone/Users).'
      }
    } catch { Log ('[security] ACL audit skipped: ' + $_.Exception.Message) }
    return $true
  } catch { return $true }
}

function Show-VersionNoticeDialog {
  # time-limited notice: auto-dismisses after 2s (acts as the default button),
  # or the user can click a button to proceed immediately.
  param([string]$Message, [string]$OkLabel = (T 'versionOk'), [bool]$HasSecondary = $false, [string]$SecondaryLabel = '', [string]$Title = (T 'versionNoticeTitle'))
  Add-Type -AssemblyName System.Windows.Forms | Out-Null
  Add-Type -AssemblyName System.Drawing | Out-Null
  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  Set-FormIcon $form
  $form.ClientSize = New-Object System.Drawing.Size(430, 135)
  $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.Add_Shown({ $form.Activate(); $form.BringToFront() })
  $lbl = New-Object System.Windows.Forms.Label
  $lbl.Location = New-Object System.Drawing.Point(15, 14)
  $lbl.Size = New-Object System.Drawing.Size(400, 55)
  $lbl.Text = $Message
  $form.Controls.Add($lbl)
  $okX = if ($HasSecondary) { 220 } else { 320 }
  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Location = New-Object System.Drawing.Point($okX, 88)
  $btnOk.Size = New-Object System.Drawing.Size(90, 28)
  $btnOk.Text = $OkLabel
  $form.Controls.Add($btnOk)
  $btnSecondary = $null
  if ($HasSecondary) {
    $btnSecondary = New-Object System.Windows.Forms.Button
    $btnSecondary.Location = New-Object System.Drawing.Point(320, 88)
    $btnSecondary.Size = New-Object System.Drawing.Size(90, 28)
    $btnSecondary.Text = $SecondaryLabel
    $form.Controls.Add($btnSecondary)
  }
  $btnOk.Add_Click({ $form.Tag = 'ok'; $form.Close() })
  if ($btnSecondary) { $btnSecondary.Add_Click({ $form.Tag = 'secondary'; $form.Close() }) }
  $timer = New-Object System.Windows.Forms.Timer
  $timer.Interval = 2000
  $timer.Add_Tick({
    $timer.Stop()
    if (-not $form.Tag) { $form.Tag = 'ok' }
    $form.Close()
  })
  $timer.Start()
  $null = $form.ShowDialog()
  $timer.Stop(); $timer.Dispose()
  $result = $form.Tag
  $form.Dispose()
  if (-not $result) { $result = 'ok' }
  return $result
}

function Start-VersionCheck {
  # spawn the background version check (non-blocking); it shows a 2s notice
  # with the result and respects the user's "已是最新提示" option
  try {
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $ScriptDir 'Start-Harness.ps1'),'-CheckVersionOnly') `
      -WindowStyle Hidden | Out-Null
  } catch { Log ("[version-check spawn failed] " + $_.Exception.Message) }
}

# ============================================================
# ---- resolve the DeepSeek Harness source location (auto-detect) ----
$DshRoot = Resolve-HarnessRoot
if (-not $DshRoot) {
  Log 'Could not locate the DeepSeek Harness source.'
  Show-Popup (T 'popupRootNotFound') (T 'popupTitleError')
  exit 1
}
Log ("DSH root: " + $DshRoot)

# ---- change-port-only mode: show the port config UI without starting anything ----
# (invoked by the port-config hotkey Ctrl+Alt+P via Start-HotkeyListener.ps1)
if ($ChangePortOnly) {
  if ($NoPopup) {
    Log 'ChangePortOnly in NoPopup mode: no dialog shown (test path).'
    exit 0
  }
  # single-instance guard for the dialog itself: refuse to stack another dialog
  $cpMarker = Join-Path $LogDir 'change-port.running'
  if (Test-Path $cpMarker) {
    Log 'Another port-config dialog is already open; this instance exits.'
    exit 0
  }
  Set-Content -Path $cpMarker -Value ([string]$PID) -Encoding ASCII
  Log 'Change-port mode: showing port configuration dialog.'
  try {
    $cfg = Load-PortConfig
    $dlg = Show-PortConfigDialog -DefaultPort ($(if ($cfg.Port -ge 1) { $cfg.Port } else { $DefaultPort })) -Note (T 'portRestartNote')
    if ($dlg.HardStop) {
      Log 'Hard stop performed from the port dialog.'
    } elseif ($dlg.Port -gt 0) {
      if ($dlg.Remember) { Save-PortConfig $dlg.Port $true }
      else { Remove-Item $PortConfigFile -Force -ErrorAction SilentlyContinue }
      Set-VersionNoticeOption $dlg.VersionNotice
      Log ("Port config changed to " + $dlg.Port + " (remember=" + $dlg.Remember + ").")
    } else {
      Log 'Port config dialog cancelled (no change).'
    }
  } finally {
    Remove-Item $cpMarker -Force -ErrorAction SilentlyContinue
  }
  exit 0
}

# ---- warm-up mode: start the web service hidden (Windows-login pre-warm) ----
# Registered in the HKCU Run key when the user enables "warm-up" in the port
# dialog. It only PRE-STARTS the web service (no browser, no popups, no version
# check, no tray) so the first real launch finds it already ready. The update
# flow is untouched: updates still stop/rebuild the source normally.
if ($WarmupOnly) {
  $NoPopup = $true   # never show UI from a login warm-up
  Log 'Warmup mode: starting the harness web service hidden.'
  $cfg = Load-PortConfig
  $Port = $(if ($cfg.Port -ge 1) { $cfg.Port } else { $DefaultPort })
  $Url = "http://127.0.0.1:$Port"
  # already warm? (configured port or default port responding - no duplicate)
  if (Test-HarnessUp -PortNumber $Port -or (Test-PortListening -PortNumber $Port -TimeoutMs 300)) { Log 'Warmup: service already running.'; exit 0 }
  if (Test-HarnessUp -PortNumber $DefaultPort -or (Test-PortListening -PortNumber $DefaultPort -TimeoutMs 300)) { Log 'Warmup: service already running (default port).'; exit 0 }
  if (-not (Test-Path (Join-Path $DshRoot 'package.json'))) { Log 'Warmup: source missing, skipping.'; exit 0 }
  Ensure-HistoryFormat
  $stats = Get-StartupStats
  $status = Start-HarnessOnce
  if ($status -eq 'starting') { $s = Wait-ForReady -ServiceProc $null -TimeoutSeconds 180; $status = $(if ($s -eq 'ready') { 'ready' } else { 'failed' }) }
  Remove-Item $StartLockFile -Force -ErrorAction SilentlyContinue
  Log ("Warmup: " + $status)
  exit 0
}

# ---- stop-service-only mode (stop hotkey / manual stop) ----
if ($StopServiceOnly) {
  Log 'StopServiceOnly mode: stopping the harness.'
  Stop-HarnessService
  Show-Popup (T 'svcStopped') (T 'popupTitleHint')
  exit 0
}

# ---- check-version-only mode: background version check + 2s notice ----
# (spawned by the launcher after the service flow; never blocks startup)
if ($CheckVersionOnly) {
  if ($NoPopup) { Log 'CheckVersionOnly in NoPopup mode: no UI (test path).'; exit 0 }
  $showNotice = Get-VersionNoticeOption
  # anti-double-click cache (60 s): every launch still queries GitHub fresh,
  # so a newly released version is detected in real time (background, non-blocking)
  $cacheFile = Join-Path $LogDir 'last-version-check.txt'
  $latest = ''; $fromCache = $false
  if (Test-Path $cacheFile) {
    try {
      $cached = (Get-Content $cacheFile -Raw | ConvertFrom-Json)
      if (((Get-Date) - [datetime]$cached.When).TotalSeconds -lt 60) { $latest = [string]$cached.Latest; $fromCache = $true }
    } catch {}
  }
  if (-not $latest) {
    $latest = Get-LatestHarnessVersion
    if ($latest) {
      try { Set-Content -Path $cacheFile -Value (@{ When = (Get-Date).ToString('o'); Latest = $latest } | ConvertTo-Json) -Encoding ASCII } catch {}
    }
  }
  if (-not $latest) { Log '[version-check] unreachable; silent.'; exit 0 }
  $localV = Get-LocalHarnessVersion
  Log ("[version-check] local " + $localV + ", latest " + $latest + $(if ($fromCache) { ' (cached)' } else { '' }))
  if (Test-VersionAtLeast $localV $latest) {
    if ($showNotice) { $null = Show-VersionNoticeDialog -Message ([string]::Format((T 'versionLatest'), $localV)) }
    exit 0
  }
  # update available
  $choice = Show-VersionNoticeDialog -Message ([string]::Format((T 'versionNewFound'), $localV, $latest)) -OkLabel (T 'versionLater') -HasSecondary $true -SecondaryLabel (T 'versionUpdateRestart') -Title (T 'versionUpdateTitle')
  if ($choice -eq 'secondary') {
    Log '[version-check] user chose update-and-restart.'
    # stop the running harness (full, SAFE cleanup - same routine as the hotkey stop)
    Stop-HarnessService
    if (-not (Update-HarnessSource)) {
      # the old source is untouched (the swap never happened) -> keep it and restart
      Log '[version-check] update download/verify failed; keeping current version.'
      if (-not $NoPopup) { Show-Popup (T 'rollbackUpdateFailed') (T 'rollbackTitle') }
      Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $ScriptDir 'Start-Harness.ps1')) `
        -WindowStyle Hidden | Out-Null
      exit 0
    }
    # pre-flight dependency check BEFORE building (pnpm must exist to install/build)
    $envOk = Ensure-NodeAndPnpm
    if ($envOk -ne $true) {
      Log ("[version-check] node/pnpm unavailable (" + $envOk + "); update aborted.")
      $null = Handle-PreflightError -Step (T 'errStepBgUpdateBuild') -ErrorText (T 'errTextBuild') -FixText (T 'errFixBuild')
      exit 1
    }
    if (-not (Build-Harness)) {
      # 兜底方案: build failed -> automatically restore the previous version
      Log '[version-check] build failed; attempting automatic rollback.'
      if (Restore-PreviousHarness) {
        if (-not $NoPopup) { Show-Popup (T 'rollbackBuildFailed') (T 'rollbackTitle') }
        Start-Process -FilePath 'powershell.exe' `
          -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $ScriptDir 'Start-Harness.ps1')) `
          -WindowStyle Hidden | Out-Null
        Log '[version-check] rolled back; launcher restarted with previous version.'
        exit 0
      }
      $null = Handle-PreflightError -Step (T 'errStepBgUpdateBuild') -ErrorText (T 'errTextBuild') -FixText (T 'errFixUpdateBuild')
      exit 1
    }
    # relaunch the launcher fresh (starts the service + browser on the new version)
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $ScriptDir 'Start-Harness.ps1')) `
      -WindowStyle Hidden | Out-Null
    Log '[version-check] update applied; launcher restarted.'
  } else {
    Log '[version-check] update deferred (user chose later / auto-dismissed).'
  }
  exit 0
}

Log 'Launcher started.'
Clean-Logs   # log rotation: purge old logs, rotate oversized ones

# ---- single-instance guard: a Windows NAMED MUTEX prevents concurrent launcher
# processes (the 3s timestamp below only powers the double-click hint).
$script:launchMutex = New-Object System.Threading.Mutex($false, 'Local\DeepSeekHarnessLauncher')
$script:launchMutexOwned = $false
try { $script:launchMutexOwned = $script:launchMutex.WaitOne(0) } catch { $script:launchMutexOwned = $true }
if (-not $script:launchMutexOwned) {
  # another launcher is already running (e.g. a repeated click during startup) -
  # the primary instance will open the browser when the service is ready
  Log 'Another launcher instance is running (named mutex held); duplicate click exits.'
  Show-Popup (T 'popupDoubleClick') (T 'popupTitleHint')
  exit 0
}

# ---- double-click guard: only a second click within 3s gets the warning ----
$LastStartFile = Join-Path $LogDir 'launcher-last-start.txt'
$isRapidRepeat = $false
if (Test-Path $LastStartFile) {
  try {
    $lastStart = [datetime]::Parse((Get-Content $LastStartFile -Raw).Trim())
    if (((Get-Date) - $lastStart).TotalSeconds -lt 3) { $isRapidRepeat = $true }
  } catch {}
}
Set-Content -Path $LastStartFile -Value (Get-Date).ToString('o') -Encoding ASCII
if ($isRapidRepeat) {
  Log 'Rapid repeat launch detected (within 3s); warning instead of starting again.'
  Show-Popup (T 'popupDoubleClick') (T 'popupTitleHint')
  exit 0
}

# ---- environment preflight (fast, local-only; no network in the critical path) ----
$preflightResult = Run-Preflight
if ($preflightResult -eq 'reinstall') { $preflightResult = Run-Preflight }
if ($preflightResult -ne $true) {
  Log 'Preflight failed; launcher exits.'
  exit 1
}

# ---- background version check (non-blocking; 2s notice with the result) ----
if (-not $NoPopup) { Start-VersionCheck }
# keep the Windows-login warm-up entry in sync with the option file
if (-not $NoPopup) { Set-WarmupStartup (Get-WarmupOption) }

# ---- detection (PORT-INDEPENDENT: works with any configured / actual port) ----
# The configured port can differ from the port the service actually runs on
# (e.g. the config was changed but the service was not restarted). Detection
# probes, in order: the configured port, the port the running dsh process is
# actually listening on, and the default port 3080 - using whichever responds.
# Pure HTTP/TCP probes, so it works even when process inspection is unavailable.
$cfgEarly = Load-PortConfig
$detectPort = $(if ($cfgEarly.Port -ge 1) { $cfgEarly.Port } else { $DefaultPort })
$procUp = Test-ServiceProcess
$actualPort = 0
if ($procUp) { $actualPort = Get-RunningHarnessPort }
$candPorts = @($detectPort)
if ($actualPort -gt 0 -and ($candPorts -notcontains $actualPort)) { $candPorts += $actualPort }
if ($candPorts -notcontains $DefaultPort) { $candPorts += $DefaultPort }
$httpUp = $false; $portUp = $false; $servingPort = $detectPort
foreach ($p in $candPorts) {
  if (Test-HarnessUp -PortNumber $p) { $httpUp = $true; $servingPort = $p; break }
}
if (-not $httpUp) {
  foreach ($p in $candPorts) {
    if (Test-PortListening -PortNumber $p -TimeoutMs 200) { $portUp = $true; $servingPort = $p; break }
  }
}
# last resort: scan a small loopback range for the harness web UI, so the
# launcher works even where process inspection is unavailable. Only ports that
# actually respond with HTTP are accepted (never a bare TCP listener).
if (-not $httpUp -and -not $portUp) {
  foreach ($p in (3080..3100)) {
    if ($candPorts -contains $p) { continue }
    if (Test-PortListening -PortNumber $p -TimeoutMs 150) {
      if (Test-HarnessUp -PortNumber $p) { $httpUp = $true; $servingPort = $p; Log ("Service found on port " + $p + " (loopback scan)."); break }
    }
  }
}
if ($servingPort -ne $detectPort) { Log ("Service found on port " + $servingPort + " (configured port was " + $detectPort + ").") }
$Port = $servingPort
$Url = "http://127.0.0.1:$Port"
Log ("Detect result -> http=" + $httpUp + " port=" + $portUp + " process=" + $procUp + " (port in use: " + $Port + ")")

# ---- Case 1: already running -> open browser directly ----
if ($httpUp) {
  Log 'Service already running (HTTP up). Opening browser.'
  Open-Browser
  $fresh = Ensure-Listener
  $hk = Get-ActiveHotkeyLabel
  if (-not $hk) { $hk = T 'popupHotkeyFallback' }
  if ($fresh) {
    Show-Popup ([string]::Format((T 'popupAlreadyRunning'), $Url, (T 'popupListenerActive'), $hk))
  } else {
    Show-Popup ([string]::Format((T 'popupAlreadyRunning'), $Url, (T 'popupListenerReArmed'), $hk))
  }
  Log 'Done (already running).'
  exit 0
}

# ---- Case 2: service is starting (port/process up, HTTP not ready) -> wait silently ----
# No progress window here: the service is already up at the port level, so this
# wait is usually short. Only a real cold start (case 3) shows the progress window.
if ($portUp -or $procUp) {
  Log 'Service detected as starting (port/process up, HTTP not ready). Waiting silently for it to become ready...'
  Ensure-Listener | Out-Null
  $status = Wait-ForReady -ServiceProc $null -TimeoutSeconds 120
  if ($status -eq 'ready') {
    Log 'Service became ready.'
    Open-Browser
    Finish-Ready $false
  } else {
    Log 'Service did not become ready in time.'
    Show-Popup ([string]::Format((T 'popupCase2Timeout'), $LogDir)) (T 'popupStartFailedTitle')
    exit 1
  }
}

# ---- Case 3: nothing running -> start the service hidden ----
if (-not (Test-Path (Join-Path $DshRoot 'package.json'))) {
  Log ("DSH root not found: " + $DshRoot)
  Show-Popup (T 'popupRootNotFound') (T 'popupTitleError')
  exit 1
}

# AUTHORITY RE-CHECK (single-instance guarantee): if a harness service process
# is alive (e.g. another click already started it between detection and here),
# NEVER start a second one - wait for it and open the browser instead.
if (Test-ServiceProcess) {
  Log 'A harness service process is already running; waiting for it and opening the browser instead of starting another.'
  Ensure-Listener | Out-Null
  $status = Wait-ForReady -ServiceProc $null -TimeoutSeconds 120
  if ($status -eq 'ready') {
    Log 'Service became ready.'
    Open-Browser
    Finish-Ready $false
  } else {
    Log 'Service did not become ready in time.'
    Show-Popup ([string]::Format((T 'popupCase2Timeout'), $LogDir)) (T 'popupStartFailedTitle')
    exit 1
  }
}

# ---- choose the port (UI + validation + remember option) ----
$cfg = Load-PortConfig
$usePort = $cfg.Port
$cfgRemember = $cfg.Remember
$conflict = $false
if ($usePort -ge 1 -and (Test-PortListening -PortNumber $usePort)) {
  # the saved port is already taken by another application -> yield to it and ask
  $conflict = $true
  Log ("Saved port " + $usePort + " is occupied; asking user to reconfigure.")
}
if ($NoPopup) {
  # silent/test mode: no UI - use the saved port or the default
  if ($usePort -lt 1 -or $conflict) { $usePort = $DefaultPort }
} elseif ($usePort -lt 1 -or $conflict -or -not $cfgRemember) {
  Log 'No remembered port config; asking user for a port.'
  $dlg = Show-PortConfigDialog -DefaultPort ($(if ($usePort -ge 1) { $usePort } else { $DefaultPort }))
  if ($dlg.HardStop) {
    Log 'Hard stop performed from the port dialog; launcher exits.'
    exit 0
  }
  if ($dlg.Port -le 0) {
    Log 'Port configuration cancelled; launcher exits.'
    exit 0
  }
  $usePort = $dlg.Port
  $cfgRemember = $dlg.Remember
  if ($cfgRemember) { Save-PortConfig $usePort $true }
  else { Remove-Item $PortConfigFile -Force -ErrorAction SilentlyContinue }
  Set-VersionNoticeOption $dlg.VersionNotice
} else {
  # remembered config, no conflict -> cookie behavior: skip the dialog entirely
  Log ("Using remembered port " + $usePort + " (no port dialog needed).")
}
$Port = $usePort
$Url = "http://127.0.0.1:$Port"
Log ("Using port " + $Port)

Ensure-Listener | Out-Null
Ensure-HistoryFormat
$stats = Get-StartupStats

# ---- start + wait; if the (updated) source fails to come up, auto-rollback ----
$status = Start-HarnessOnce
if ($status -eq 'starting') {
  # another instance is starting the service - wait silently (never spawn a 2nd)
  Log 'Another instance is starting the service; waiting silently for it.'
  $s = Wait-ForReady -ServiceProc $null -TimeoutSeconds 180
  $status = $(if ($s -eq 'ready') { 'ready' } else { 'failed' })
}
# rollback only when the service is genuinely NOT up and an update is pending
if ($status -ne 'ready' -and -not (Test-HarnessUp) -and (Get-PreviousHarnessBackup)) {
  # 兜底方案: an unconfirmed update is present and the new version did not
  # start -> automatically restore the previous working version and retry
  Log '[rollback] new version failed to start; restoring previous version.'
  if (Restore-PreviousHarness) {
    if (-not $NoPopup) { Show-Popup (T 'rollbackStartFailed') (T 'rollbackTitle') }
    $status = Start-HarnessOnce
    if ($status -eq 'starting') { $s = Wait-ForReady -ServiceProc $null -TimeoutSeconds 180; $status = $(if ($s -eq 'ready') { 'ready' } else { 'failed' }) }
  }
}

if ($status -eq 'ready' -or (Test-HarnessUp)) {
  # final safety net: a racing instance may have won the port (our child exited
  # with EADDRINUSE) while the service is actually up - never show a false
  # "start failed" popup in that case
  if ($status -ne 'ready') { Log 'Service is up (started by another instance). Treating as ready.' }
  Remove-Item $StartLockFile -Force -ErrorAction SilentlyContinue   # start complete: release the lock
  $secs = [int]((Get-Date) - $script:startTime).TotalSeconds
  $portSec = 0
  if (Test-Path $PortUpMarker) {
    $raw = (Get-Content $PortUpMarker -Raw -ErrorAction SilentlyContinue).Trim()
    if ($raw -match '^\d+$') { $portSec = [int]$raw }
  }
  Log ("Service is up. Startup took " + $secs + "s (port up at " + $portSec + "s).")
  # single-instance confirmation: report how many dsh node processes exist now
  $dshCount = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue | Where-Object { Test-HarnessProcessCommandLine ([string]$_.CommandLine) }).Count
  Log ("Single-instance check: " + $dshCount + " dsh node process(es) running.")
  Confirm-HarnessUpdate   # update confirmed: drop the rollback backup / failed leftovers
  # record the harness's WebView2 GUI PIDs - ONLY those that started at/after
  # this service start (other apps' WebView2 are never recorded or killed)
  $webviewPids = @(Get-Process -Name msedgewebview2 -ErrorAction SilentlyContinue |
    Where-Object { try { $_.StartTime -ge $script:startTime } catch { $false } } |
    Select-Object -ExpandProperty Id)
  if ($webviewPids.Count -gt 0) { Set-Content -Path (Join-Path $LogDir 'harness-webview.pids') -Value ($webviewPids -join ',') -Encoding ASCII }
  else { Remove-Item (Join-Path $LogDir 'harness-webview.pids') -Force -ErrorAction SilentlyContinue }
  Add-StartupHistory $secs $portSec
  Open-Browser
  Finish-Ready $true
} else {
  Log ("Service did not become ready (" + $status + ").")
  Remove-Item $StartLockFile -Force -ErrorAction SilentlyContinue   # release the lock so future starts are not blocked
  Show-Popup ([string]::Format((T 'popupStartFailed'), $LogDir)) (T 'popupStartFailedTitle')
  exit 1
}

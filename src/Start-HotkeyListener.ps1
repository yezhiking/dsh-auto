# Start-HotkeyListener.ps1 - global hotkey that stops the DeepSeek Harness service.
# - Registers a hotkey via the Win32 RegisterHotKey API
# - Tries the candidates below in order; the first combo that is NOT already
#   taken by another application wins, so there is never a hotkey conflict.
# - On hotkey press: kills the service process tree (and any leftover dsh CLI
#   node process as a fallback), then exits.
# To change the hotkey, edit the $candidates list below (Mod = modifier flags,
# Vk = virtual-key code; see https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes).
param([switch]$NoPopup)

$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# runtime data lives outside the source tree (same layout as the launcher)
$DataDir = Join-Path (Split-Path $ScriptDir -Parent) 'data'
$LogDir = Join-Path $DataDir 'logs'
$ServicePidFile = Join-Path $LogDir 'harness-service.pid'
$HotkeyLog = Join-Path $LogDir 'harness-hotkey.log'
$PortConfigFile = Join-Path $DataDir 'harness-port-config.txt'
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null

# read the configured port (shared with the launcher via harness-port-config.txt)
function Refresh-ConfiguredPort {
  # re-read the port config so a port change takes effect for the next hotkey press
  $p = 3080
  if (Test-Path $PortConfigFile) {
    foreach ($line in (Get-Content $PortConfigFile -ErrorAction SilentlyContinue)) {
      if ($line -match '^port=(\d+)$') { $v = [int]$matches[1]; if ($v -ge 1 -and $v -le 65535) { $p = $v } }
    }
  }
  $script:Port = $p
  $script:Url = "http://127.0.0.1:$p"
}
$Port = 3080
$Url = "http://127.0.0.1:$Port"
Refresh-ConfiguredPort

function Log($m) {
  # UTF-8 for logs so Chinese is never garbled on any system ANSI codepage
  Add-Content -Path $HotkeyLog -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8
}

function Resolve-ListenerRoot {
  # compact auto-detect of the harness root (same order as the launcher, no UI);
  # used ONLY to scope process cleanup so unrelated node processes are never killed
  $cfgFile = Join-Path $DataDir 'harness-config.json'
  if (Test-Path $cfgFile) {
    try { $j = Get-Content $cfgFile -Raw | ConvertFrom-Json; if ($j.dshRoot -and (Test-Path (Join-Path $j.dshRoot 'package.json'))) { return $j.dshRoot } } catch {}
  }
  if ($env:DSH_ROOT -and (Test-Path (Join-Path $env:DSH_ROOT 'package.json'))) { return $env:DSH_ROOT }
  foreach ($c in @((Join-Path $ScriptDir '..\deepseek-harness-master'), 'C:\deepseek-harness', 'D:\deepseek-harness', (Join-Path $env:USERPROFILE 'deepseek-harness'))) {
    if ($c -and (Test-Path (Join-Path $c 'package.json'))) { return $c }
  }
  foreach ($root in @('D:\', $env:USERPROFILE)) {
    if ($root -and (Test-Path $root)) {
      try {
        $hit = Get-ChildItem -Path $root -Directory -Filter '*deepseek-harness*' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
          Where-Object { Test-Path (Join-Path $_.FullName 'package.json') } | Select-Object -First 1
        if ($hit) { return $hit.FullName }
      } catch {}
    }
  }
  return ''
}

function Get-HarnessNodeProcesses {
  # dsh node processes: command lines containing the resolved harness root, OR
  # the dsh CLI entry (apps\cli\src\bin.ts) from any copy/location. Unrelated
  # node processes are never matched, so a stop is thorough but never touches
  # other software.
  Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $cmd = [string]$_.CommandLine
      if (-not $cmd) { return $false }
      if ($ListenerRoot -and $cmd.ToLowerInvariant().Contains([string]$ListenerRoot.ToLowerInvariant())) { return $true }
      return ($cmd -match 'apps[\\/]cli[\\/]src[\\/]bin\.ts')
    }
}

function Get-HarnessWebviewTargets($svcStart, [string]$pidFile) {
  # WebView2 processes to close when stopping. ONLY processes that started at
  # or after the service start time are targeted - other applications' WebView2
  # (browsers, Office, editors, ...) are never touched. The recorded pid file is
  # only a fallback when the start time is unknown.
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

$ListenerRoot = Resolve-ListenerRoot
if ($ListenerRoot) { Log ("Harness root resolved for scoped cleanup: " + $ListenerRoot) }
else { Log 'WARNING: harness root not resolved; process cleanup uses only the narrow dsh CLI pattern.' }

# ---- shared option: "silent-stop popup" (same harness-options.txt as the launcher,
# so the port-dialog checkbox and this popup checkbox are ALWAYS in sync) ----
function Get-StopPromptOption {
  # true = show the popup after a soft stop (default); false = suppressed
  $f = Join-Path $DataDir 'harness-options.txt'
  if (Test-Path $f) {
    foreach ($line in (Get-Content $f -ErrorAction SilentlyContinue)) {
      if ($line -match '^stopPrompt=([01])$') { return ($matches[1] -eq '1') }
    }
  }
  return $true
}

function Set-StopPromptOption([bool]$on) {
  # update ONLY the stopPrompt line, preserving every other option
  $f = Join-Path $DataDir 'harness-options.txt'
  $out = @(); $found = $false
  if (Test-Path $f) {
    foreach ($l in (Get-Content $f -ErrorAction SilentlyContinue)) {
      if ($l -match '^stopPrompt=') { $out += ('stopPrompt=' + $(if ($on) { 1 } else { 0 })); $found = $true }
      else { $out += $l }
    }
  }
  if (-not $found) { $out += ('stopPrompt=' + $(if ($on) { 1 } else { 0 })) }
  try { Set-Content -Path $f -Value $out -Encoding ASCII } catch { try { Log ('[stopPrompt save failed] ' + $_.Exception.Message) } catch {} }
}

function Get-ListenerLang {
  $f = Join-Path $DataDir 'harness-options.txt'
  if (Test-Path $f) {
    foreach ($line in (Get-Content $f -ErrorAction SilentlyContinue)) {
      if ($line -match '^lang=([a-z]+)$') { return $matches[1] }
    }
  }
  return 'zh'
}

function Show-StopNotice {
  # confirmation popup after the silent (soft) stop, with a "don't ask again"
  # checkbox; ticking it persists stopPrompt=0 to the shared options file
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    $lang = Get-ListenerLang
    $msgTxt = if ($lang -eq 'en') { 'Service stopped (silent soft stop); related background processes are closed.' } else { '服务已停止（静默软杀），相关后台进程已关闭。' }
    $chkTxt = if ($lang -eq 'en') { "Don't ask again" } else { '不再提示' }
    $okTxt = if ($lang -eq 'en') { 'OK' } else { '确定' }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'DeepSeek Harness'
    $form.ClientSize = New-Object System.Drawing.Size(430, 152)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $icoPath = Join-Path $ScriptDir 'launcher.ico'
    if (Test-Path $icoPath) { try { $form.Icon = New-Object System.Drawing.Icon($icoPath) } catch {} }
    $form.Add_Shown({ $form.Activate(); $form.BringToFront() })
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(16, 40)
    $pic.Size = New-Object System.Drawing.Size(48, 48)
    $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $pngPath = Join-Path $ScriptDir 'launcher.png'
    if (Test-Path $pngPath) { try { $pic.Image = [System.Drawing.Image]::FromFile($pngPath) } catch {} }
    $form.Controls.Add($pic)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(76, 18)
    $lbl.Size = New-Object System.Drawing.Size(340, 50)
    $lbl.Text = $msgTxt
    $form.Controls.Add($lbl)
    $chk = New-Object System.Windows.Forms.CheckBox
    $chk.Location = New-Object System.Drawing.Point(76, 76)
    $chk.Size = New-Object System.Drawing.Size(300, 22)
    $chk.Text = $chkTxt
    $form.Controls.Add($chk)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point(320, 110)
    $btn.Size = New-Object System.Drawing.Size(90, 26)
    $btn.Text = $okTxt
    $btn.DialogResult = 'OK'
    $form.AcceptButton = $btn
    $form.Controls.Add($btn)
    $null = $form.ShowDialog()
    if ($chk.Checked) { Set-StopPromptOption $false; Log 'Silent-stop popup disabled by user (stopPrompt=0).' }
    $form.Dispose()
  } catch { try { Log ('[stop notice error] ' + $_.Exception.Message) } catch {} }
}

function Test-HarnessUp {
  try { $null = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2; return $true }
  catch { return $false }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HK {
  public const uint WM_HOTKEY = 0x0312;
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll", SetLastError = true)]
  public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  [DllImport("user32.dll")]
  public static extern bool GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
  [StructLayout(LayoutKind.Sequential)]
  public struct MSG {
    public IntPtr hwnd;
    public uint message;
    public IntPtr wParam;
    public IntPtr lParam;
    public uint time;
    public int ptX;
    public int ptY;
  }
}
'@

# MOD_NOREPEAT (0x4000) prevents auto-repeat while the keys are held down.
# Modifier bits: ALT=0x1, CTRL=0x2, SHIFT=0x4, WIN=0x8
$candidates = @(
  @{ Mod = 0x4007; Vk = 0x7B; Label = 'Ctrl+Alt+Shift+F12' },
  @{ Mod = 0x4003; Vk = 0x23; Label = 'Ctrl+Alt+End' },
  @{ Mod = 0x4006; Vk = 0x7B; Label = 'Ctrl+Shift+F12' },
  @{ Mod = 0x4003; Vk = 0x7A; Label = 'Ctrl+Alt+F11' },
  @{ Mod = 0x4007; Vk = 0x7A; Label = 'Ctrl+Alt+Shift+F11' },
  @{ Mod = 0x4003; Vk = 0x79; Label = 'Ctrl+Alt+F10' },
  @{ Mod = 0x4007; Vk = 0x79; Label = 'Ctrl+Alt+Shift+F10' },
  @{ Mod = 0x4003; Vk = 0x7B; Label = 'Ctrl+Alt+F12' }
)

$id = 1
$registered = $null
foreach ($c in $candidates) {
  if ([HK]::RegisterHotKey([IntPtr]::Zero, $id, $c.Mod, $c.Vk)) { $registered = $c; break }
}
if (-not $registered) {
  Log 'ERROR: no hotkey could be registered (all candidates are taken).'
  exit 1
}
Log ("Hotkey registered: " + $registered.Label + " (pid " + $PID + ")")

# Second hotkey: open the port-config dialog (Ctrl+Alt+P). No conflict-avoidance
# needed per request; chosen to not overlap browser/common software shortcuts.
# Edit these values to change it (Mod: ALT=1, CTRL=2, SHIFT=4, MOD_NOREPEAT=0x4000; Vk: 0x50 = P).
$portConfigId = 2
$portConfigMod = 0x4003   # Ctrl+Alt (+ no-repeat)
$portConfigVk = 0x50      # P
if ([HK]::RegisterHotKey([IntPtr]::Zero, $portConfigId, $portConfigMod, $portConfigVk)) {
  Log 'Port-config hotkey registered: Ctrl+Alt+P'
} else {
  Log 'WARNING: port-config hotkey Ctrl+Alt+P could not be registered (already taken).'
}

$msg = New-Object 'HK+MSG'
while ([HK]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0)) {
  try {
    if ($msg.message -eq [HK]::WM_HOTKEY) {
      # re-read the port config so the stop check always uses the current port
      Refresh-ConfiguredPort

      if ([int]$msg.wParam -eq $portConfigId) {
        $cpRunning = Join-Path $LogDir 'change-port.running'
        if (Test-Path $cpRunning) {
          Log 'Port-config hotkey pressed but a port dialog is already open; skipping.'
          continue
        }
        # open the port-config UI (change-port mode) and keep listening
        Log 'Port-config hotkey pressed - opening port configuration dialog.'
        Start-Process -FilePath 'powershell.exe' `
          -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',(Join-Path $ScriptDir 'Start-Harness.ps1'),'-ChangePortOnly') `
          -WindowStyle Hidden | Out-Null
        continue
      }

      # ---- stop the service: always attempt a full cleanup ----
      $wasUp = Test-HarnessUp
      Log 'Hotkey pressed - stopping service.'
      # 1) kill the process tree recorded at launch (cmd -> pnpm -> node).
      #    SAFETY: the recorded pid is only killed if it looks like our own
      #    launcher chain (cmd/pnpm/dsh) - never a random process.
      if (Test-Path $ServicePidFile) {
        $raw = Get-Content $ServicePidFile -Raw -ErrorAction SilentlyContinue
        $spid = 0
        if ($raw) { [int]$spid = $raw.Trim() }
        if ($spid -gt 0) {
          $pi = Get-CimInstance Win32_Process -Filter ("ProcessId = " + $spid) -ErrorAction SilentlyContinue
          if ($pi -and ($pi.Name -eq 'cmd.exe' -or ($pi.CommandLine -match 'pnpm|dsh'))) { & taskkill.exe /PID $spid /T /F 2>&1 | Out-Null }
        }
      }
      # 2) kill leftover dsh node processes (root-scoped + any harness path /
      #    the dsh CLI entry) - unrelated node processes are never touched
      Get-HarnessNodeProcesses | ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
      # 2b) the "cmd /c pnpm dsh web" wrapper itself (survives if the pid file is stale)
      Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'pnpm dsh web' } |
        ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>&1 | Out-Null }
      # 3) close the harness's WebView2 GUI processes - ONLY those that started
      #    at or after the service start time (never other applications' WebView2);
      #    the recorded pid file is only a fallback when the start time is unknown
      $webviewPidFile = Join-Path $LogDir 'harness-webview.pids'
      $svcStart = $null
      $startTimeFile = Join-Path $LogDir 'harness-start-time.txt'
      if (Test-Path $startTimeFile) { try { $svcStart = [datetime]::Parse((Get-Content $startTimeFile -Raw).Trim()) } catch {} }
      $webviewTargets = @(Get-HarnessWebviewTargets -svcStart $svcStart -pidFile $webviewPidFile)
      foreach ($wt in $webviewTargets) { & taskkill.exe /PID $wt /T /F 2>&1 | Out-Null }
      # SOFT stop only - the hotkey is silent; the HARD stop (port-based
      # guaranteed kill) lives in the port dialog's "Hard Stop" button.
      # 4) post-stop audit: node + cmd wrapper must all be gone
      Start-Sleep -Milliseconds 500
      $remaining = @()
      Get-HarnessNodeProcesses | ForEach-Object { $remaining += ('node pid ' + $_.ProcessId) }
      Get-CimInstance Win32_Process -Filter "Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'pnpm dsh web' } |
        ForEach-Object { $remaining += ('cmd pid ' + $_.ProcessId) }
      foreach ($wt in $webviewTargets) {
        if (Get-Process -Id $wt -ErrorAction SilentlyContinue) { $remaining += ('webview2 pid ' + $wt) }
      }
      if ($remaining.Count -gt 0) { Log ("POST-STOP CHECK: leftover -> " + ($remaining -join '; ')) }
      else { Log 'POST-STOP CHECK: clean - no harness processes remain.' }
      Remove-Item $ServicePidFile -Force -ErrorAction SilentlyContinue
      if ($wasUp) { Log 'Service stopped (soft, silent). Listener exiting.' }
      else { Log 'Service stopped (soft, silent; no HTTP response on the configured port). Listener exiting.' }
      # confirmation popup (with "don't ask again" checkbox) unless the user
      # suppressed it - the SAME option as the port dialog checkbox
      if (Get-StopPromptOption) { Show-StopNotice }
      exit 0
    }
  } catch {
    try { Log ('[listener loop error] ' + $_.Exception.Message) } catch {}
  }
}
Log 'Listener message loop exited.'

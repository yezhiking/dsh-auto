Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W2 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
}
"@
$h = [IntPtr]10292094
[void][W2]::ShowWindow($h, 9)
[W2]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[void][W2]::SetForegroundWindow($h)
[W2]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 800
$fg = [W2]::GetForegroundWindow()
$sb = New-Object System.Text.StringBuilder 256
[void][W2]::GetWindowText($fg, $sb, 256)
Write-Output ("前台窗口(强制后): [" + $sb.ToString() + "] hwnd=" + $fg)
if ($fg -eq $h) {
  $ws = New-Object -ComObject WScript.Shell
  $ws.SendKeys("^o")
  Write-Output "已发送 Ctrl+O（Add local repository）"
} else {
  Write-Output "夺前台失败，未发送按键"
}

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W4 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int n);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
$h = [IntPtr]10292094
[void][W4]::ShowWindow($h, 9)
[W4]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
[void][W4]::SetForegroundWindow($h)
[W4]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
Start-Sleep -Milliseconds 700
$ws = New-Object -ComObject WScript.Shell
$ws.SendKeys("^o")
Start-Sleep -Milliseconds 2200
$ws.SendKeys("^v")
Start-Sleep -Milliseconds 500
$ws.SendKeys("{ENTER}")
Write-Output "SEQ-OK"

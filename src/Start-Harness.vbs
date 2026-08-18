' Start-Harness.vbs - launch Start-Harness.ps1 with a hidden console (no window flash).
' Double-click this file (or the 启动DeepSeekHarness.bat shortcut) to start DeepSeek Harness.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\Start-Harness.ps1"""
For Each a In WScript.Arguments
  cmd = cmd & " " & """" & a & """"
Next
sh.Run cmd, 0, False

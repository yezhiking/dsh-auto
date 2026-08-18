@echo off
rem DeepSeek Harness one-click launcher (hidden window version).
rem Launches Start-Harness.vbs, which runs everything with no visible window,
rem opens the browser automatically, and arms a global stop hotkey
rem (see logs\harness-hotkey.log for which hotkey is active).
start "" wscript.exe "%~dp0Start-Harness.vbs" %*

@echo off
rem Cursor hooks name a command, not a script: this is the shim hooks.json points at.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0cursor-hook.ps1"

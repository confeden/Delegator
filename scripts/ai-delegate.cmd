@echo off
rem IDE-facing wrapper around ai-delegate.ps1. WARNING: cmd.exe re-parses %* -- a
rem prompt passed as an argument is truncated at the first newline, %VAR% patterns
rem are expanded, and metacharacters stay live. Multiline prompts or prompts
rem containing % " & must be written to a UTF-8 temp file and passed with
rem -PromptFile <path> (or piped via stdin). This cannot be fixed at the cmd level.
chcp 65001 >nul
rem Attribute usage to IDE agents by default; the Python core and CLI callers set
rem DELEGATOR_CLIENT themselves before invoking the runtime.
if not defined DELEGATOR_CLIENT set "DELEGATOR_CLIENT=ide"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ai-delegate.ps1" %*

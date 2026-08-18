#requires -Version 5.1
<#
.SYNOPSIS
    Cursor `beforeSubmitPrompt` hook: hands Delegator's instructions to the agent
    on every request.

.DESCRIPTION
    Cursor loads a rule automatically only when it sits INSIDE an open project
    (`<ws>\AGENTS.md` or a `.mdc` rule under the project`s own `.cursor` rules).
    in the home profile is never injected, so until 0.6.3 the agent had to grep
    the machine to find out what `-benchmark` means - seven searches before the
    first task, and a different model might not go looking at all. Antigravity
    reads `~/.gemini\GEMINI.md` at session start and needs none of that.

    Hooks are the one machine-wide, file-based surface Cursor does read from the
    home profile. Verified against Cursor 3.16: `beforeSubmitPrompt` is one of
    the events that accept `additionalContext`, the payload is capped at 10 000
    characters, and both the flat and the Claude-style nested shape are parsed.

    The text is NOT duplicated here: it is read from the rule file the app
    maintains, so one edit changes both surfaces, and disabling the hook (which
    empties that file) silently turns this into a no-op.
#>

$ErrorActionPreference = "Stop"

# Cursor sends the event as JSON on stdin. Nothing here needs it, but the stream
# must be drained or the parent can block on a full pipe.
try { [void][Console]::In.ReadToEnd() } catch { }

function Write-Empty {
    # An empty object is a valid "nothing to add" answer. Never fail loudly: a
    # hook that errors is noise in every single prompt.
    [Console]::Out.Write("{}")
    exit 0
}

try {
    $rule = Join-Path $env:USERPROFILE ".cursor\rules\delegator.mdc"
    if (-not (Test-Path -LiteralPath $rule)) { Write-Empty }
    $text = [System.IO.File]::ReadAllText($rule, (New-Object System.Text.UTF8Encoding $false))
    if ([string]::IsNullOrWhiteSpace($text)) { Write-Empty }

    # Strip the YAML header: it is Cursor rule metadata, not instructions.
    $lines = @(($text -replace "`r`n", "`n") -split "`n")
    if ($lines.Count -gt 0 -and $lines[0].Trim() -eq "---") {
        $closing = -1
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq "---") { $closing = $i; break }
        }
        if ($closing -ge 0) { $lines = @($lines[($closing + 1)..($lines.Count - 1)]) }
    }
    $body = ($lines -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { Write-Empty }

    # 10 000 characters is Cursor's own limit; over it the hook is rejected.
    if ($body.Length -gt 9500) { $body = $body.Substring(0, 9500) }

    $payload = [ordered]@{
        additionalContext = $body
        hookSpecificOutput = [ordered]@{
            hookEventName = "beforeSubmitPrompt"
            additionalContext = $body
        }
    }
    [Console]::Out.Write(($payload | ConvertTo-Json -Depth 5 -Compress))
    exit 0
} catch {
    Write-Empty
}

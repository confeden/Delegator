<#
    opencode-delegate.ps1: which failed attempt gets written to usage.jsonl, and
    as what (DEV_CONTRACTS sections 2.1 and 5).

    Before 0.7.2 the try-ladder wrote ONE usage record per run - for the last
    candidate only. A ladder that failed on A and B and answered on C left no
    trace of A and B at all, so Get-ModelHealth never learned they were broken
    and the router picked A first again on the next call. The whole
    "models are picked by measured ability" claim rested on evidence that was
    never written down.
#>

Test-Case "a model that timed out is recorded against that model" {
    Assert-True (Test-AttemptIsModelFailure -ExitCode 124 -ErrorClass "timeout")
}

Test-Case "a 5xx from the provider is recorded" {
    Assert-True (Test-AttemptIsModelFailure -ExitCode 1 -ErrorClass "server")
}

Test-Case "a missing CLI is NOT recorded against any model" {
    # Exit 2 is a LOCAL environment problem: opencode not installed, no keys.
    # Every model in the pool fails identically, so recording it would demote the
    # entire pool at once - and health, unlike a cooldown, has no expiry.
    Assert-False (Test-AttemptIsModelFailure -ExitCode 2 -ErrorClass "unknown")
    Assert-False (Test-AttemptIsModelFailure -ExitCode 2 -ErrorClass "auth")
}

Test-Case "a rate limit is recorded, and classified as one" {
    # It IS written (spend and attribution are facts), but Get-ModelHealth reads
    # the errorClass and refuses to treat it as a quality signal.
    Assert-True (Test-AttemptIsModelFailure -ExitCode 1 -ErrorClass "rate_limit")
}

# ── Get-OpenCodeErrorClass: the classifier those records carry ──

Test-Case "exit 124 is a timeout whatever the text says" {
    Assert-Equal "timeout" (Get-OpenCodeErrorClass -ExitCode 124 -Output "")
}

Test-Case "exit 2 is a local problem, never a model verdict" {
    Assert-Equal "unknown" (Get-OpenCodeErrorClass -ExitCode 2 -Output "429 Too Many Requests")
}

Test-Case "429 and quota wording are rate_limit" {
    Assert-Equal "rate_limit" (Get-OpenCodeErrorClass -ExitCode 1 -Output "HTTP (429) Too Many Requests")
    Assert-Equal "rate_limit" (Get-OpenCodeErrorClass -ExitCode 1 -Output "RESOURCE_EXHAUSTED: quota")
}

Test-Case "401/403 are auth" {
    Assert-Equal "auth" (Get-OpenCodeErrorClass -ExitCode 1 -Output "request failed (401)")
    Assert-Equal "auth" (Get-OpenCodeErrorClass -ExitCode 1 -Output "invalid api key")
}

Test-Case "a 5xx is a server error and outranks the word timeout later in the text" {
    Assert-Equal "server" (Get-OpenCodeErrorClass -ExitCode 1 -Output "(502) bad gateway, connection timed out")
}

Test-Case "an unrecognised failure stays unknown" {
    Assert-Equal "unknown" (Get-OpenCodeErrorClass -ExitCode 1 -Output "something went sideways")
}

# ── Cooldowns stay driven by the class, not by the record ──

Test-Case "auth and rate_limit cool down, unknown does not" {
    Assert-True ((Get-ModelCooldownSeconds -ErrorClass "auth" -RetryAfterSec 0) -gt 0)
    Assert-True ((Get-ModelCooldownSeconds -ErrorClass "rate_limit" -RetryAfterSec 0) -gt 0)
    Assert-Equal 0 (Get-ModelCooldownSeconds -ErrorClass "unknown" -RetryAfterSec 0)
}

Test-Case "an explicit Retry-After wins over the default" {
    Assert-Equal 777 (Get-ModelCooldownSeconds -ErrorClass "rate_limit" -RetryAfterSec 777)
}

# ── The record this script actually appends (DEV_CONTRACTS section 2.1) ──

function Get-LastSandboxUsageRecord {
    $path = Join-Path $env:DELEGATOR_RUNTIME_HOME "usage.jsonl"
    $lines = @([System.IO.File]::ReadAllLines($path) | Where-Object { $_ })
    return ($lines[$lines.Count - 1] | ConvertFrom-Json)
}

Test-Case "a failed call carries its errorClass" {
    Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/rec-fail" `
        -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null `
        -ElapsedMs 4321 -Ok $false -AccountId $null -ErrorClass "timeout"
    $row = Get-LastSandboxUsageRecord
    Assert-Equal "m/rec-fail" $row.model
    Assert-Equal "timeout" $row.errorClass
    Assert-False $row.ok
    Assert-Equal 4321 $row.elapsedMs
}

Test-Case "a successful call carries no errorClass at all" {
    # Not an empty string, not a null field: absent. Get-ModelHealth reads a
    # missing class as "pre-0.7.2, count it", so a stray empty one on a SUCCESS
    # would be harmless today and a trap the moment the rule changes.
    Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/rec-ok" `
        -PromptTokens 10 -CompletionTokens 20 -TotalTokens 30 -Cost 0 `
        -ElapsedMs 900 -Ok $true -AccountId $null
    $row = Get-LastSandboxUsageRecord
    Assert-True $row.ok
    Assert-False (@($row.PSObject.Properties.Name) -contains "errorClass")
}

Test-Case "an older caller that passes no class still writes a valid record" {
    Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/rec-legacy" `
        -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null `
        -ElapsedMs 100 -Ok $false -AccountId $null
    $row = Get-LastSandboxUsageRecord
    Assert-Equal "m/rec-legacy" $row.model
    Assert-False (@($row.PSObject.Properties.Name) -contains "errorClass")
}

Test-Case "a benchmark run is flagged so the counter can drop it" {
    # I11: a benchmark solves twelve tasks twice, so counting it would inflate
    # both "spent" and "saved" with work nobody asked for. The flag is carried by
    # a FILE (§2.1) because each arm runs in its own process.
    $flag = Join-Path $env:DELEGATOR_RUNTIME_HOME "benchmark-active.json"
    Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/bench-off" `
        -PromptTokens 1 -CompletionTokens 1 -TotalTokens 2 -Cost 0 `
        -ElapsedMs 10 -Ok $true -AccountId $null
    Assert-False (Get-LastSandboxUsageRecord).bench

    $payload = '{"runId":"test","startedAt":"' + [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + '"}'
    [System.IO.File]::WriteAllText($flag, $payload, (New-Object System.Text.UTF8Encoding $false))
    try {
        Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/bench-on" `
            -PromptTokens 1 -CompletionTokens 1 -TotalTokens 2 -Cost 0 `
            -ElapsedMs 10 -Ok $true -AccountId $null
        $row = Get-LastSandboxUsageRecord
        Assert-Equal "m/bench-on" $row.model
        Assert-True $row.bench
    } finally {
        Remove-Item -LiteralPath $flag -Force -ErrorAction SilentlyContinue
    }

    Write-DelegateUsageRecord -Mode "ask" -Provider "zen" -ModelId "m/bench-cleared" `
        -PromptTokens 1 -CompletionTokens 1 -TotalTokens 2 -Cost 0 `
        -ElapsedMs 10 -Ok $true -AccountId $null
    Assert-False (Get-LastSandboxUsageRecord).bench
}

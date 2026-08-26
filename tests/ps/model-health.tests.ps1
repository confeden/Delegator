<#
    Get-ModelLatencyStats / Get-ModelHealth / Test-ModelAffordable
    (DEV_CONTRACTS section 9, invariant I10, gotcha G74).

    These read <RT>\usage.jsonl, which the runner has redirected into a sandbox.
    Each case writes its own log and clears the read-once cache first.
#>

function New-UsageLine {
    param(
        [string]$Model,
        [bool]$Ok = $true,
        [int]$ElapsedMs = 1000,
        [string]$ErrorClass = "",
        [string]$Stage = "answer"
    )
    $row = [ordered]@{
        ts          = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        requestId   = "r-test0001"
        client      = "cli"
        stage       = $Stage
        mode        = "ask"
        provider    = "zen"
        model       = $Model
        totalTokens = 100
        elapsedMs   = $ElapsedMs
        ok          = $Ok
    }
    if ($ErrorClass) { $row.errorClass = $ErrorClass }
    return ($row | ConvertTo-Json -Compress -Depth 4)
}

function Set-SandboxUsageLog {
    param([string[]]$Lines)
    $path = Join-Path $env:DELEGATOR_RUNTIME_HOME "usage.jsonl"
    [System.IO.File]::WriteAllLines($path, [string[]]$Lines, (New-Object System.Text.UTF8Encoding $false))
    Clear-ModelLatencyCache
}

Test-Case "no log at all means no samples, and everything is worth trying" {
    $path = Join-Path $env:DELEGATOR_RUNTIME_HOME "usage.jsonl"
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    Clear-ModelLatencyCache
    $health = Get-ModelHealth "opencode/anything-free"
    Assert-Equal 0 $health.samples
    Assert-True (Test-ModelAffordable -ModelId "opencode/anything-free" -BudgetMs 100000)
}

Test-Case "fail rate is counted over the recorded calls" {
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/slow" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/slow" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/slow" -Ok $true -ElapsedMs 5000),
        (New-UsageLine -Model "m/slow" -Ok $true -ElapsedMs 7000)
    )
    $health = Get-ModelHealth "m/slow"
    Assert-Equal 4 $health.samples
    Assert-Equal 0.5 $health.failRate
}

Test-Case "a model failing half its recent calls is not affordable" {
    # Four samples minimum, all of a class that counts: `network` is exempt now,
    # and with three samples Test-ModelAffordable falls through to the p75 rule.
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/bad" -Ok $false -ErrorClass "server"),
        (New-UsageLine -Model "m/bad" -Ok $false -ErrorClass "server"),
        (New-UsageLine -Model "m/bad" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/bad" -Ok $true -ElapsedMs 900)
    )
    $health = Get-ModelHealth "m/bad"
    Assert-Equal 4 $health.samples
    Assert-Equal 0.75 $health.failRate
    Assert-False (Test-ModelAffordable -ModelId "m/bad" -BudgetMs 100000)
}

Test-Case "p75 uses the tail, because the tail is what hits the timeout" {
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/p75" -Ok $true -ElapsedMs 1000),
        (New-UsageLine -Model "m/p75" -Ok $true -ElapsedMs 2000),
        (New-UsageLine -Model "m/p75" -Ok $true -ElapsedMs 3000),
        (New-UsageLine -Model "m/p75" -Ok $true -ElapsedMs 40000)
    )
    $health = Get-ModelHealth "m/p75"
    Assert-Equal 3000 $health.p75Ms
    Assert-False (Test-ModelAffordable -ModelId "m/p75" -BudgetMs 2000)
    Assert-True (Test-ModelAffordable -ModelId "m/p75" -BudgetMs 100000)
}

Test-Case "failed calls do not drag the latency estimate down" {
    # A failure records elapsedMs too. Counting it as a duration would make a
    # model that dies in 200 ms look FASTER than one that answers in 8 s.
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/mix" -Ok $false -ElapsedMs 200 -ErrorClass "server"),
        (New-UsageLine -Model "m/mix" -Ok $true -ElapsedMs 8000)
    )
    Assert-Equal 8000 (Get-ModelHealth "m/mix").p75Ms
}

# ── Quality signal vs. time-bounded account state (G29) ──

Test-Case "a rate-limited call is not evidence about the model" {
    # The free tier runs out every day. cooldowns.json already carries that with
    # an EXPIRY; health has none, it only ages out after 12 newer calls, so
    # counting a quota day here would demote a good model long after it recovered.
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/quota" -Ok $false -ErrorClass "rate_limit"),
        (New-UsageLine -Model "m/quota" -Ok $false -ErrorClass "rate_limit"),
        (New-UsageLine -Model "m/quota" -Ok $false -ErrorClass "rate_limit"),
        (New-UsageLine -Model "m/quota" -Ok $true -ElapsedMs 1500)
    )
    $health = Get-ModelHealth "m/quota"
    Assert-Equal 1 $health.samples
    Assert-Equal 0 $health.failRate
    Assert-True (Test-ModelAffordable -ModelId "m/quota" -BudgetMs 100000)
}

Test-Case "an auth failure is an account state, not a model verdict" {
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/auth" -Ok $false -ErrorClass "auth"),
        (New-UsageLine -Model "m/auth" -Ok $false -ErrorClass "auth")
    )
    Assert-Equal 0 (Get-ModelHealth "m/auth").samples
}

Test-Case "an offline machine does not demote the pool it never reached" {
    # The regression this guards: since 0.7.2 the ladder writes one record per
    # rung, so a single delegation made with the Wi-Fi down marks EVERY enabled
    # model at once. Four such delegations put the whole pool over the 40 % line,
    # Get-StrongEnabledModel finds nothing affordable and falls back to the
    # FASTEST model - the strength floor inverted into a weakness floor, held
    # there until twelve newer calls per model age the outage out.
    $lines = @()
    foreach ($i in 1..5) {
        foreach ($m in @("m/off-strong", "m/off-mid", "m/off-fast")) {
            $lines += (New-UsageLine -Model $m -Ok $false -ErrorClass "network")
        }
    }
    Set-SandboxUsageLog $lines
    foreach ($m in @("m/off-strong", "m/off-mid", "m/off-fast")) {
        Assert-Equal 0 (Get-ModelHealth $m).samples
        Assert-True (Test-ModelAffordable -ModelId $m -BudgetMs 100000)
    }
}

Test-Case "one oversized prompt does not demote the pool either" {
    # context_overflow is a statement about the PROMPT: every model in the ladder
    # rejects the same -ContextFile, and none of them is at fault.
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/big" -Ok $false -ErrorClass "context_overflow"),
        (New-UsageLine -Model "m/big" -Ok $false -ErrorClass "context_overflow"),
        (New-UsageLine -Model "m/big" -Ok $false -ErrorClass "context_overflow"),
        (New-UsageLine -Model "m/big" -Ok $false -ErrorClass "context_overflow")
    )
    Assert-Equal 0 (Get-ModelHealth "m/big").samples
    Assert-True (Test-ModelAffordable -ModelId "m/big" -BudgetMs 100000)
}

Test-Case "one timeout with nothing beside it is an anecdote, not a fail rate" {
    # Measured on a real 23-rung ladder: every model came back samples=1,
    # failRate=1, affordable=False, because the "no p75 yet" branch bypassed the
    # four-sample floor. One provider outage must not demote the pool.
    Set-SandboxUsageLog @((New-UsageLine -Model "m/one" -Ok $false -ErrorClass "timeout"))
    Assert-Equal 1 (Get-ModelHealth "m/one").samples
    Assert-True (Test-ModelAffordable -ModelId "m/one" -BudgetMs 100000)

    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/two" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/two" -Ok $false -ErrorClass "timeout")
    )
    Assert-True (Test-ModelAffordable -ModelId "m/two" -BudgetMs 100000)
}

Test-Case "three failures and no success is enough to stop trying" {
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/three" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/three" -Ok $false -ErrorClass "server"),
        (New-UsageLine -Model "m/three" -Ok $false -ErrorClass "timeout")
    )
    $health = Get-ModelHealth "m/three"
    Assert-Equal 3 $health.samples
    Assert-Null $health.p75Ms
    Assert-False (Test-ModelAffordable -ModelId "m/three" -BudgetMs 100000)
}

Test-Case "a timeout IS evidence about the model" {
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/to" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/to" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/to" -Ok $false -ErrorClass "timeout"),
        (New-UsageLine -Model "m/to" -Ok $false -ErrorClass "timeout")
    )
    $health = Get-ModelHealth "m/to"
    Assert-Equal 4 $health.samples
    Assert-Equal 1 $health.failRate
    Assert-False (Test-ModelAffordable -ModelId "m/to" -BudgetMs 100000)
}

Test-Case "a pre-0.7.2 failure with no errorClass still counts" {
    # Every record written before this release lacks the field. Silently dropping
    # them would erase the router's memory on upgrade.
    Set-SandboxUsageLog @(
        (New-UsageLine -Model "m/old" -Ok $false),
        (New-UsageLine -Model "m/old" -Ok $false),
        (New-UsageLine -Model "m/old" -Ok $false),
        (New-UsageLine -Model "m/old" -Ok $true -ElapsedMs 1200)
    )
    $health = Get-ModelHealth "m/old"
    Assert-Equal 4 $health.samples
    Assert-Equal 0.75 $health.failRate
}

Test-Case "a torn line is skipped, and the lines after it are still read" {
    # The torn line comes FIRST on purpose. With the good record first, a scan
    # that aborted on the bad line would still leave samples=1 and the test would
    # pass while proving nothing - the parse loop's per-line try/catch would be
    # untested. This ordering fails unless the loop really continues.
    $path = Join-Path $env:DELEGATOR_RUNTIME_HOME "usage.jsonl"
    [System.IO.File]::WriteAllLines($path, [string[]]@(
            '{"model":"m/torn","ok":fal',
            (New-UsageLine -Model "m/torn" -Ok $true -ElapsedMs 1100),
            (New-UsageLine -Model "m/torn" -Ok $true -ElapsedMs 1300)
        ), (New-Object System.Text.UTF8Encoding $false))
    Clear-ModelLatencyCache
    $health = Get-ModelHealth "m/torn"
    Assert-Equal 2 $health.samples
    Assert-Equal 1300 $health.p75Ms
}

Test-Case "the window is the last 12 calls of that model" {
    $lines = @()
    foreach ($i in 1..20) { $lines += (New-UsageLine -Model "m/win" -Ok $false -ErrorClass "server") }
    foreach ($i in 1..12) { $lines += (New-UsageLine -Model "m/win" -Ok $true -ElapsedMs 1000) }
    Set-SandboxUsageLog $lines
    $health = Get-ModelHealth "m/win"
    Assert-Equal 12 $health.samples
    Assert-Equal 0 $health.failRate
}

# ── Select-AffordableRankedModels: the same verdict, applied to an ORDER ──
# `-ping` used to spend its whole budget on gemini-flash-latest while Google was
# answering 503 for it. A `server` failure buys only a 60 s cooldown, so the
# model came straight back to the front; health looks at the last 12 calls.

Test-Case "a model its own record says is failing loses its place in the order" {
    $lines = @()
    foreach ($i in 1..6) { $lines += (New-UsageLine -Model "m/sick" -Ok $false -ErrorClass "server") }
    foreach ($i in 1..4) { $lines += (New-UsageLine -Model "m/well" -Ok $true -ElapsedMs 3000) }
    Set-SandboxUsageLog $lines
    $picked = @(Select-AffordableRankedModels @("m/sick", "m/well"))
    Assert-Equal "m/well" $picked[0] "the sick model was first in the order and must not stay there"
}

Test-Case "when every candidate looks bad the order survives untouched" {
    # The caller must always be left with something to try: an empty list here
    # would turn a bad day at the provider into "Delegator has no models".
    $lines = @()
    foreach ($i in 1..6) { $lines += (New-UsageLine -Model "m/bad1" -Ok $false -ErrorClass "server") }
    foreach ($i in 1..6) { $lines += (New-UsageLine -Model "m/bad2" -Ok $false -ErrorClass "server") }
    Set-SandboxUsageLog $lines
    $picked = @(Select-AffordableRankedModels @("m/bad1", "m/bad2"))
    Assert-Equal 2 $picked.Count
    Assert-Equal "m/bad1" $picked[0]
}

Test-Case "a model nobody has called yet keeps its place" {
    Set-SandboxUsageLog @()
    $picked = @(Select-AffordableRankedModels @("m/unknown-a", "m/unknown-b"))
    Assert-Equal "m/unknown-a" $picked[0] "no record means try it, not skip it"
}

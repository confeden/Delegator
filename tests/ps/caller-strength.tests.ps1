<#
    Get-CallerEffortPenalty / Get-CallerDpr (DEV_CONTRACTS §13).

    Why this exists: `model-ratings.json` carries ONE row per model, and the
    longest-substring lookup therefore scores `gemini-3.7-flash-low` exactly like
    `gemini-3.7-flash` — 152, seventh of 196, above claude-opus-4-8. Routed on
    that number, an agent running Flash at low effort gets the ECONOMY path when
    what it needs is amplification. The penalty is the correction, and it applies
    to the CALLER only.
#>

Test-Case "the ratings table really does score Flash near the top" {
    # Not a tautology: it is the fact the whole penalty exists to correct, and if
    # a re-snapshot moves it the thresholds below have to be revisited.
    Assert-Equal 152 (Get-DelegatorModelRating "gemini-3.7-flash")
    Assert-Equal 156 (Get-DelegatorModelRating "claude-opus-5")
}

Test-Case "an effort suffix is only an effort suffix at the END of the id" {
    Assert-Equal 25 (Get-CallerEffortPenalty "gemini-3.7-flash-low")
    Assert-Equal 12 (Get-CallerEffortPenalty "gemini-3.7-flash-medium")
    Assert-Equal 0 (Get-CallerEffortPenalty "gemini-3.7-flash-high")
    Assert-Equal 35 (Get-CallerEffortPenalty "gpt-5.6-sol-minimal")
    Assert-Equal 0 (Get-CallerEffortPenalty "gpt-5.3-codex")
    # A model whose NAME contains one of the words must not be penalised.
    Assert-Equal 0 (Get-CallerEffortPenalty "vendor/low-latency-v2")
    Assert-Equal 0 (Get-CallerEffortPenalty "")
}

Test-Case "the penalty lands the caller where experience says it belongs" {
    $high = Get-CallerDpr "gemini-3.7-flash-high"
    $low = Get-CallerDpr "gemini-3.7-flash-low"
    Assert-Equal 152 $high
    Assert-Equal 127 $low
    Assert-True ($low -lt (Get-DelegatorModelRating "claude-sonnet-5")) "low effort must fall below Sonnet 5"
    Assert-True ($high -gt (Get-DelegatorModelRating "claude-sonnet-5")) "high effort must stay above it"
}

Test-Case "an undeclared or unknown caller scores 0, never a guess" {
    # 0 means "no comparison is possible", and the router routes that exactly as
    # it did before §13. The unrated default (100) would be a MID score and would
    # read as a weak caller, triggering amplification nobody asked for.
    Assert-Equal 0 (Get-CallerDpr "")
    Assert-Equal 0 (Get-CallerDpr "some-model-nobody-rated-v9")
}

Test-Case "the env fallback is used only when the parameter is empty" {
    $previous = $env:DELEGATOR_CALLER_MODEL
    try {
        $env:DELEGATOR_CALLER_MODEL = "claude-opus-5"
        Assert-Equal 156 (Get-CallerDpr "")
        Assert-Equal 127 (Get-CallerDpr "gemini-3.7-flash-low") "an explicit -CallerModel wins"
    } finally {
        if ($null -eq $previous) { Remove-Item Env:\DELEGATOR_CALLER_MODEL -ErrorAction SilentlyContinue }
        else { $env:DELEGATOR_CALLER_MODEL = $previous }
    }
}

Test-Case "the penalty can never drive a caller to zero" {
    # Zero is reserved for "did not say". A real, very weak caller at minimal
    # effort must still compare as a caller.
    $weak = @(Get-DelegatorEnabledModels "enabled_opencode_models") | Select-Object -First 0
    Assert-True ((Get-CallerDpr "claude-3.5-sonnet-minimal") -ge 1)
}

# ── Rating confidence (§13.6) ────────────────────────────────────────────────

Test-Case "a row confirmed by two benchmarks is measured, one source is provisional" {
    # Not cosmetic: §13.3 widens the indifference band for a provisional pair, so
    # this classification is what stops a single-source score from crossing a
    # routing boundary on its own.
    Assert-Equal "measured" (Get-DelegatorRatingConfidence "claude-opus-5")
    Assert-Equal "measured" (Get-DelegatorRatingConfidence "claude-sonnet-5")
    Assert-Equal "provisional" (Get-DelegatorRatingConfidence "gemini-3.7-flash")
}

Test-Case "an unknown id has no confidence at all, which is not the same as low" {
    Assert-Equal "" (Get-DelegatorRatingConfidence "some-model-nobody-rated-v9")
    Assert-Equal "" (Get-DelegatorRatingConfidence "")
}

Test-Case "confidence follows the same row as the score" {
    # The two must never describe different rows: the lookup is longest-substring
    # and an effort suffix must not change which row answers.
    Assert-Equal (Get-DelegatorRatingConfidence "gemini-3.7-flash") (Get-CallerRatingConfidence "gemini-3.7-flash-low")
    Assert-Equal 152 (Get-DelegatorModelRating "gemini-3.7-flash-low")
}

# ── Boost advisor panel (the pipeline §13 `amplify` routes into) ─────────────

Test-Case "advisors come from the enabled list, strongest first" {
    # The live failure: `model-rankings.json` never ships (N6), so the advisor
    # pool was a hardcoded triple - and two of its three ids were not enabled on
    # the owner's machine. The nested `ask -Model X` refuses anything outside the
    # allowlist, so all three boosts this machine ever ran ended
    # `all-advisors-failed`, including one routed there by §13 amplify.
    $enabled = @("opencode/nemotron-3-ultra-free", "aerolink/claude-opus-5", "agentrouter-openai/gpt-5.6-sol")
    $panel = @(Get-BoostAdvisorModels -Count 3 -Enabled $enabled)
    Assert-Equal 3 $panel.Count
    foreach ($m in $panel) { Assert-True ($enabled -contains $m) "advisor $m is not enabled" }
    Assert-Equal "aerolink/claude-opus-5" $panel[0] "the strongest advisor must equal the single pick"
    $scores = @($panel | ForEach-Object { Get-ModelStrengthScore -ModelId $_ -Catalog @{} })
    for ($i = 1; $i -lt $scores.Count; $i++) {
        Assert-True ($scores[$i] -le $scores[$i - 1]) "panel is not ordered by strength"
    }
}

Test-Case "an empty allowlist yields no advisors, never a hardcoded guess" {
    Assert-Equal 0 @(Get-BoostAdvisorModels -Count 3 -Enabled @()).Count
    Assert-Equal 0 @(Get-BoostAdvisorModels -Count 3 -Enabled @("", "  ")).Count
    Assert-Equal 0 @(Get-BoostAdvisorModels -Count 0 -Enabled @("aerolink/claude-opus-5")).Count
}

Test-Case "asking for more advisors than exist returns what exists" {
    $panel = @(Get-BoostAdvisorModels -Count 5 -Enabled @("aerolink/claude-opus-5", "opencode/big-pickle"))
    Assert-Equal 2 $panel.Count
}

Test-Case "an excluded model never joins the panel" {
    $panel = @(Get-BoostAdvisorModels -Count 3 -Enabled @("aerolink/claude-opus-5", "opencode/big-pickle") `
            -Exclude @("aerolink/claude-opus-5"))
    Assert-Equal 1 $panel.Count
    Assert-Equal "opencode/big-pickle" $panel[0]
}

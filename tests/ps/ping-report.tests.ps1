<#
    Format-PingReport — the text `-ping` puts in front of the user.

    The command exists to answer two questions ("did the instructions reach this
    chat" and "can Delegator still answer"), and its one unforgivable failure is
    to report success when nothing answered. That is what these cases pin down;
    the live half is a real delegation and cannot run here.
#>

function Get-SuccessReport {
    return @(Format-PingReport `
        -RuntimeHome "C:\Runtime" `
        -CoreVersion "0.8.1" `
        -GeminiModels 8 `
        -OtherModels 15 `
        -Caller "claude-opus-5" `
        -AnswerModel "opencode/deepseek-v4-flash-free" `
        -Seconds 6.27 `
        -ExitCode 0)
}

function Get-FailureReport {
    return @(Format-PingReport `
        -RuntimeHome "C:\Runtime" `
        -CoreVersion "" `
        -GeminiModels 0 `
        -OtherModels 0 `
        -Caller "" `
        -AnswerModel "" `
        -TriedModels @("gemini-flash-latest", "opencode/deepseek-v4-flash-free") `
        -Seconds 91.4 `
        -ExitCode 1)
}

Test-Case "a working delegation is reported as working, with who answered and how long it took" {
    $text = (Get-SuccessReport) -join "`n"
    Assert-Match "Итог: Delegator подключён и работает\." $text
    Assert-Match "opencode/deepseek-v4-flash-free" $text
    Assert-Match "6,3 с|6\.3 с" $text "the elapsed time is rounded to one decimal"
    Assert-Match "Ядро: отвечает, версия 0\.8\.1" $text
    Assert-Match "Моделей включено: 23" $text
    Assert-Match "Ваша модель: claude-opus-5" $text
}

Test-Case "nothing answered means the report must not say it works" {
    $text = (Get-FailureReport) -join "`n"
    Assert-False ($text -match "подключён и работает") "a failed probe may never read as success"
    Assert-Match "ответить сейчас никто не смог" $text
    Assert-Match "квота" $text "the user needs the usual cause, not just a code"
    Assert-Match "код 1" $text
    # "nobody answered" is unreadable without WHO was asked.
    Assert-Match "Пробовали: gemini-flash-latest, opencode/deepseek-v4-flash-free" $text
    # A ping tries two models; a real task tries the whole ladder. Saying so
    # keeps a red ping from reading as "Delegator is down".
    Assert-Match "длиннее перебор моделей" $text
}

Test-Case "the instructions half is stated in both reports, because it is what the output itself proves" {
    foreach ($report in @((Get-SuccessReport), (Get-FailureReport))) {
        $text = $report -join "`n"
        Assert-Match "инструкции дошли до этого чата" $text
        Assert-Match "-ping" $text
    }
}

Test-Case "a core that does not answer, and a missing -CallerModel, are named as such" {
    $text = (Get-FailureReport) -join "`n"
    Assert-Match "Ядро: не отвечает" $text
    Assert-Match "не передал -CallerModel" $text
    Assert-Match "Моделей включено: 0" $text
}

Test-Case "the verdict is the LAST thing the user reads in the working case" {
    $report = Get-SuccessReport
    Assert-Match "^Итог: " $report[$report.Count - 1]
}

# ── The advice must follow the observed failure, not a fixed list of guesses ──
# The report that prompted this said "квота, ключ или сеть" while Google was
# answering 503 for one model and another Gemini model answered in 3.2 s: all
# three guesses wrong, and all three point the user at their own settings.

Test-Case "an auth failure sends the user to the keys tab and nowhere else" {
    $text = (Get-PingAdvice @("auth")) -join "`n"
    Assert-Match "«API», раздел «Ключи»" $text
    Assert-False ($text -match "квота провайдера, отсутствующий ключ или нет сети") "the blanket guess must not survive a KNOWN cause"
}

Test-Case "a network failure names the proxy, because a dead proxy looks exactly like dead models" {
    # G98: the owner's proxy answered 504 to CONNECT and every OpenCode model
    # timed out. Nothing in the report hinted that egress, not the models, was
    # the problem.
    $text = (Get-PingAdvice @("network")) -join "`n"
    Assert-Match "Прокси" $text
}

Test-Case "a provider-side failure does not send the user to fix settings that are fine" {
    $text = (Get-PingAdvice @("server", "timeout")) -join "`n"
    Assert-Match "временные неполадки у провайдера" $text
    Assert-False ($text -match "«Ключи»") "nothing of the user's is broken when the provider 503s"
}

Test-Case "with nothing recorded the report still guesses out loud" {
    $text = (Get-PingAdvice @()) -join "`n"
    Assert-Match "квота" $text "an honest guess beats silence when there is no evidence"
}

Test-Case "the advice names only tabs that exist" {
    # G114: 0.8.4 folded «API-ключи», «Модели Gemini» and «Модели OpenCode»
    # into one «API» tab, and this advice kept sending users to the old ones.
    foreach ($class in @("", "auth", "rate_limit", "network", "server")) {
        $classes = if ($class) { @($class) } else { @() }
        $text = (Get-PingAdvice $classes) -join "`n"
        Assert-False ($text -match "API-ключи|вкладк\w* «Модели") "a tab that no longer exists, for [$class]: $text"
    }
}

Test-Case "each model that refused is listed with its own reason" {
    $text = (@(Format-PingReport `
        -CoreVersion "0.8.2" `
        -TriedModels @("gemini-flash-latest", "opencode/big-pickle") `
        -TriedReasons @("провайдер вернул ошибку (503): This model is currently experiencing high demand", "") `
        -FailureClasses @("server") `
        -Seconds 42.3 -ExitCode 1)) -join "`n"
    Assert-Match "experiencing high demand" $text "the provider's own sentence is the useful half"
    Assert-Match "gemini-flash-latest - провайдер вернул ошибку \(503\)" $text
    # The one with no record still has to appear: "nobody answered" is
    # unreadable without WHO was asked.
    Assert-Match "opencode/big-pickle" $text
}

Test-Case "the reason is read back from the record the provider already wrote" {
    $runs = Join-Path $env:DELEGATOR_RUNTIME_HOME "runs.jsonl"
    $old = (Get-Date).AddHours(-2).ToString("o")
    $fresh = (Get-Date).AddSeconds(-5).ToString("o")
    # One line per variable on purpose: `,` binds TIGHTER than `+` in PS 5.1, so
    # writing these two as `'a' + $x + 'b', 'c' + $y + 'd'` silently produces a
    # single mangled string and the test passes on nothing.
    $staleLine = '{"event":"attempt_failed","model":"gemini-flash-latest","errorClass":"auth","statusCode":401,"errorPreview":"stale, from an older run","timestamp":"' + $old + '"}'
    $freshLine = '{"event":"attempt_failed","model":"gemini-flash-latest","errorClass":"server","statusCode":503,"errorPreview":"This model is currently experiencing high demand.","timestamp":"' + $fresh + '"}'
    Set-Content -LiteralPath $runs -Encoding UTF8 -Value @($staleLine, $freshLine)
    try {
        $failure = Get-PingFailureReason -ModelName "gemini-flash-latest" -Since (Get-Date).AddMinutes(-1)
        Assert-Equal "server" $failure.class
        Assert-Match "503" $failure.reason
        Assert-Match "experiencing high demand" $failure.reason
        Assert-False ($failure.reason -match "older run") "a record from before the probe is not this probe's failure"

        $none = Get-PingFailureReason -ModelName "opencode/big-pickle" -Since (Get-Date).AddMinutes(-1)
        Assert-Equal "" $none.reason "a model with no record reports nothing, it does not invent a cause"
    } finally {
        Remove-Item -LiteralPath $runs -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "a raw JSON envelope is not shown to the user as an explanation" {
    $runs = Join-Path $env:DELEGATOR_RUNTIME_HOME "runs.jsonl"
    $fresh = (Get-Date).AddSeconds(-5).ToString("o")
    Set-Content -LiteralPath $runs -Encoding UTF8 -Value @(
        '{"event":"attempt_failed","model":"aerolink/claude-opus-5","errorClass":"auth","errorPreview":"{\"type\":\"error\",\"data\":{\"message\":\"Unauthorized\"}}","timestamp":"' + $fresh + '"}'
    )
    try {
        $failure = Get-PingFailureReason -ModelName "aerolink/claude-opus-5" -Since (Get-Date).AddMinutes(-1)
        Assert-Match "ключ не принят" $failure.reason
        Assert-False ($failure.reason -match '\{') "the CLI's error envelope is noise, not an explanation"
    } finally {
        Remove-Item -LiteralPath $runs -Force -ErrorAction SilentlyContinue
    }
}

# ── N6's residue: the no-rankings branch is the ONLY branch on a real install ──

Test-Case "the fallback pick never names a model the user did not enable" {
    # The exact shape of the reported bug: `-ping` probed
    # opencode/deepseek-v4-flash-free on a machine whose list holds the
    # orcarouter one and not that.
    $enabled = @("orcarouter/deepseek/deepseek-v4-flash-free", "opencode/big-pickle")
    $pick = Get-BackendFallbackModel -BackendName "opencode" -Enabled $enabled
    Assert-True ($enabled -contains $pick) "picked [$pick], which is not in the enabled list"
}

Test-Case "the fallback still prefers the cheap default when it IS enabled" {
    $enabled = @("opencode/big-pickle", "opencode/deepseek-v4-flash-free")
    Assert-Equal "opencode/deepseek-v4-flash-free" (Get-BackendFallbackModel -BackendName "opencode" -Enabled $enabled)
}

Test-Case "an empty enabled list falls back to the literal, not to nothing" {
    Assert-Equal "opencode/deepseek-v4-flash-free" (Get-BackendFallbackModel -BackendName "opencode" -Enabled @())
    Assert-Equal "" (Get-BackendFallbackModel -BackendName "gemini" -Enabled @())
}

Test-Case "the fallback reaches for a quick model, not the strongest one" {
    # N4 calls this function the backend CORRECTION - the one that overwrites a
    # strong pick with a flash one. Ordering by raw strength here would send a
    # one-word probe to a 156-point reasoner.
    $enabled = @("agentrouter/claude-opus-5", "opencode/nemotron-3.5-lightning-free")
    Assert-Equal "opencode/nemotron-3.5-lightning-free" (Get-BackendFallbackModel -BackendName "opencode" -Enabled $enabled)
}

Test-Case "a model skipped for cooldown says when the cooldown ends, not that it failed" {
    $text = (@(Format-PingReport -RuntimeHome "C:\Runtime" -CoreVersion "0.9.37" -GeminiModels 4 -OtherModels 108 -Caller "" -AnswerModel "" -TriedModels @("gemini-flash-latest") -TriedReasons @("в cooldown до 20:19 (server), не вызывался") -Seconds 0.4 -ExitCode 1) -join "`n")
    Assert-Match "в cooldown до 20:19 \(server\), не вызывался" $text
}

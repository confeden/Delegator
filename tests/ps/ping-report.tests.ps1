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

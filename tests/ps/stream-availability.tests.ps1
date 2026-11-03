Test-Case "a reasoning or text event counts as the model being alive" {
    $line = '{"type":"reasoning","part":{"text":"thinking"}}'
    Assert-True (Test-StreamEventLine $line)
    Assert-True (Test-StreamEventLine '{"type":"text","part":{"text":"hi"}}')
}

Test-Case "plain text and blank lines are not evidence of life" {
    Assert-False (Test-StreamEventLine "")
    Assert-False (Test-StreamEventLine "Error: something")
    Assert-False (Test-StreamEventLine '{"type":"tool_use"}')
}

Test-Case "Get-StreamEventCount counts only the stream events" {
    $text = "junk`n" + '{"type":"step_start"}' + "`n" + '{"type":"reasoning"}' + "`n" + '{"type":"tool"}'
    Assert-Equal (Get-StreamEventCount $text) 2
    Assert-Equal (Get-StreamEventCount "") 0
}

Test-Case "a stalled call is not recorded as a model failure" {
    Assert-False (Test-AttemptIsModelFailure -ExitCode 124 -ErrorClass "stalled")
}

Test-Case "a stalled call writes nothing to model-availability.json" {
    if (Test-Path -LiteralPath $ModelAvailabilityFile) { Remove-Item -LiteralPath $ModelAvailabilityFile -Force }
    Update-ModelAvailability -ModelId "test/stalled-model" -Ok $false -ErrorClass "stalled"
    Assert-False (Test-Path -LiteralPath $ModelAvailabilityFile)
}

Test-Case "a model that failed last is sorted behind the others" {
    if (Test-Path -LiteralPath $ModelAvailabilityFile) { Remove-Item -LiteralPath $ModelAvailabilityFile -Force }
    Update-ModelAvailability -ModelId "test/a" -Ok $false -ErrorClass "server"
    $order = @(Sort-ByAvailability -Candidates @("test/a", "test/b", "test/c"))
    Assert-Equal ($order -join ",") "test/b,test/c,test/a"
}

Test-Case "a success after a failure lifts the model back" {
    Update-ModelAvailability -ModelId "test/a" -Ok $true -ElapsedMs 900
    $order = @(Sort-ByAvailability -Candidates @("test/a", "test/b"))
    Assert-Equal ($order -join ",") "test/a,test/b"
}

Test-Case "a failure older than six hours no longer demotes" {
    $old = (Get-Date).ToUniversalTime().AddHours(-7).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $state = [pscustomobject]@{ version = 1; models = [pscustomobject]@{
        "test/old" = [pscustomobject]@{ okCount = 0; failCount = 1; lastOk = ""; lastFail = $old; lastErrorClass = "server"; lastMs = 0 }
    } }
    Write-Utf8NoBom -Path $ModelAvailabilityFile -Text ($state | ConvertTo-Json -Depth 8)
    $order = @(Sort-ByAvailability -Candidates @("test/old", "test/b"))
    Assert-Equal ($order -join ",") "test/old,test/b"
}

Test-Case "the availability record survives a reload from disk" {
    if (Test-Path -LiteralPath $ModelAvailabilityFile) { Remove-Item -LiteralPath $ModelAvailabilityFile -Force }
    Update-ModelAvailability -ModelId "test/persist" -Ok $true -ElapsedMs 123
    $state = Read-ModelAvailability
    Assert-Equal ([int]$state.models."test/persist".okCount) 1
    Assert-Equal ([int]$state.models."test/persist".lastMs) 123
}

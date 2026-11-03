Test-Case "a short plain question is a light web task" {
    Assert-True (Test-LightWebTask "Why does TCP stay in TIME_WAIT after close?")
}

Test-Case "code or a long text is not a light web task" {
    Assert-False (Test-LightWebTask ("x" * 1500))
    Assert-False (Test-LightWebTask "Review this: ``````python`nprint(1)`n``````")
    Assert-False (Test-LightWebTask "def foo(): return 1")
}

Test-Case "-ping names each enabled door and what is in its way" {
    $state = [pscustomobject]@{
        connected = $true
        doors = @(
            [pscustomobject]@{ label = "Gemini"; enabled = $true; auth = "signed_in"; resting_sec = 0 }
            [pscustomobject]@{ label = "Kimi"; enabled = $true; auth = "signed_out"; resting_sec = 0 }
            [pscustomobject]@{ label = "Qwen"; enabled = $true; auth = "signed_in"; resting_sec = 61 }
            [pscustomobject]@{ label = "Rudder"; enabled = $false; auth = "signed_in"; resting_sec = 0 }
        )
    }
    $line = Format-WebDoorsLine $state
    Assert-Match "Gemini: готов" $line
    Assert-Match "Kimi: нужен вход" $line
    Assert-Match "Qwen: пауза 2 мин" $line
    Assert-False ($line -match "Rudder")
}

Test-Case "-ping says so when the extension is gone, whatever the doors last reported" {
    $state = [pscustomobject]@{
        connected = $false
        doors = @([pscustomobject]@{ label = "Gemini"; enabled = $true; auth = "signed_in"; resting_sec = 0 })
    }
    Assert-Match "нет расширения" (Format-WebDoorsLine $state)
}

Test-Case "no enabled door and no core mean no line at all" {
    Assert-Equal (Format-WebDoorsLine $null) ""
    $off = [pscustomobject]@{ connected = $true; doors = @([pscustomobject]@{ label = "Gemini"; enabled = $false; auth = "unknown"; resting_sec = 0 }) }
    Assert-Equal (Format-WebDoorsLine $off) ""
}

Test-Case "a cached answer is found by its own file and a Cyrillic answer survives" {
    $script:DelegateCacheDir = Join-Path $env:TEMP ("dg-cache-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Add-CachedResponse -PromptHash "abc" -Response "Ответ с кириллицей" -Model "m" -Domain "d"
        Assert-Equal (Find-CachedResponse -PromptHash "abc" -Domain "d") "Ответ с кириллицей"
        Assert-Null (Find-CachedResponse -PromptHash "other" -Domain "d")
    } finally {
        Remove-Item -LiteralPath $script:DelegateCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "an answer past the entry size is not cached, so one huge reply cannot slow the rest" {
    $script:DelegateCacheDir = Join-Path $env:TEMP ("dg-cache-test-" + [guid]::NewGuid().ToString("N"))
    try {
        Add-CachedResponse -PromptHash "big" -Response ("x" * ($script:CacheMaxEntryChars + 1)) -Model "m" -Domain "d"
        Assert-Null (Find-CachedResponse -PromptHash "big" -Domain "d")
    } finally {
        Remove-Item -LiteralPath $script:DelegateCacheDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case "the daily trim removes expired answers and the old single file" {
    $script:DelegateCacheDir = Join-Path $env:TEMP ("dg-cache-test-" + [guid]::NewGuid().ToString("N"))
    $script:DelegateLegacyCacheFile = Join-Path $env:TEMP ("dg-legacy-" + [guid]::NewGuid().ToString("N") + ".json")
    try {
        Set-Content -LiteralPath $script:DelegateLegacyCacheFile -Value "[]"
        Add-CachedResponse -PromptHash "fresh" -Response "ok" -Model "m" -Domain "d"
        Add-CachedResponse -PromptHash "stale" -Response "ok" -Model "m" -Domain "d"
        (Get-Item -LiteralPath (Get-CachedResponsePath "stale")).LastWriteTime = (Get-Date).AddHours(-($script:CacheTTLHours + 1))
        Invoke-ResponseCacheTrim
        Assert-False (Test-Path -LiteralPath $script:DelegateLegacyCacheFile)
        Assert-True (Test-Path -LiteralPath (Get-CachedResponsePath "fresh"))
        Assert-False (Test-Path -LiteralPath (Get-CachedResponsePath "stale"))
    } finally {
        Remove-Item -LiteralPath $script:DelegateCacheDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:DelegateLegacyCacheFile -Force -ErrorAction SilentlyContinue
    }
}

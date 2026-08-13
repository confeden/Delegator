param(
    [Parameter(Position = 0)]
    [ValidateSet("ask", "status", "health", "reset", "profiles", "update", "refresh")]
    [string]$Command = "ask",

    [Parameter(Position = 1)]
    [string]$Prompt,

    [string]$Profile,
    [string]$Model,
    [ValidateSet("auto", "fast", "normal", "deep")]
    [string]$Complexity = "auto",
    [switch]$NoVerifyFlash,
    [int]$TimeoutSec = 180,
    [int]$DailyQuota = 1500,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$DelegateHome = if ($env:DELEGATOR_RUNTIME_HOME) {
    $env:DELEGATOR_RUNTIME_HOME
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime"
} else {
    Join-Path $env:APPDATA "DelegatorWin\runtime"
}
$RunsFile = Join-Path $DelegateHome "runs.jsonl"
$UsageFile = Join-Path $DelegateHome "google-api-usage.json"
$UsageLogFile = Join-Path $DelegateHome "usage.jsonl"
$CooldownsFile = Join-Path $DelegateHome "cooldowns.json"
$AppConfigFile = Join-Path $env:APPDATA "Delegator\DelegatorWin\config\config.json"
$Today = Get-Date -Format "yyyy-MM-dd"

$ProPreference = @("gemini-pro-latest")
$FlashPreference = @("gemini-flash-latest")
$LitePreference = @("gemini-flash-lite-latest")

function Ensure-DelegateDirectory {
    New-Item -ItemType Directory -Force -Path $DelegateHome | Out-Null
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Invoke-UsageLocked {
    param([scriptblock]$Body)
    $mutex = [Threading.Mutex]::new($false, "Global\DelegatorGoogleApiUsage")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for Google API usage lock." }
        & $Body
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-RunsLocked {
    param([scriptblock]$Body)
    $mutex = [Threading.Mutex]::new($false, "Global\CodexGeminiDelegateRuns")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for Gemini run log lock." }
        & $Body
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-PromptSummary {
    param([string]$Text)
    $summary = ($Text -replace "\s+", " ").Trim()
    if ($summary.Length -gt 160) { return $summary.Substring(0, 157) + "..." }
    return $summary
}

function Write-RunEvent {
    param($Event)
    Ensure-DelegateDirectory
    if (-not $Event.PSObject.Properties["timestamp"]) {
        $Event | Add-Member -NotePropertyName timestamp -NotePropertyValue (Get-Date).ToString("o")
    }
    try {
        Invoke-RunsLocked {
            [IO.File]::AppendAllText(
                $RunsFile,
                ($Event | ConvertTo-Json -Depth 20 -Compress) + [Environment]::NewLine,
                $Utf8NoBom
            )
        }
    } catch {}
}

function Invoke-UsageLogLocked {
    param([scriptblock]$Body)
    $mutex = [Threading.Mutex]::new($false, "Global\DelegatorUsageLog")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for the usage log lock." }
        & $Body
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Write-DelegateUsageRecord {
    # DEV_CONTRACTS section 2.1/2.2: one compact JSON line per completed provider call.
    param(
        [string]$Mode,
        [string]$Provider,
        [string]$ModelId,
        [object]$PromptTokens,
        [object]$CompletionTokens,
        [object]$TotalTokens,
        [object]$Cost,
        [long]$ElapsedMs,
        [bool]$Ok,
        [object]$AccountId
    )
    $requestId = [string]$env:DELEGATOR_REQUEST_ID
    if ([string]::IsNullOrWhiteSpace($requestId)) {
        $requestId = "r-" + [Guid]::NewGuid().ToString("n").Substring(0, 8)
    }
    $client = if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_CLIENT)) { "cli" } else { [string]$env:DELEGATOR_CLIENT }
    $stage = if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_STAGE)) { "answer" } else { [string]$env:DELEGATOR_USAGE_STAGE }
    $record = [pscustomobject]@{
        ts = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        requestId = $requestId
        client = $client
        stage = $stage
        mode = $Mode
        provider = $Provider
        model = $ModelId
        promptTokens = $PromptTokens
        completionTokens = $CompletionTokens
        totalTokens = $TotalTokens
        cost = $Cost
        elapsedMs = $ElapsedMs
        ok = $Ok
        accountId = $AccountId
    }
    $line = ($record | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine
    try {
        Ensure-DelegateDirectory
        Invoke-UsageLogLocked {
            [IO.File]::AppendAllText($UsageLogFile, $line, $Utf8NoBom)
        }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_FILE)) {
        try {
            Invoke-UsageLogLocked {
                [IO.File]::AppendAllText([string]$env:DELEGATOR_USAGE_FILE, $line, $Utf8NoBom)
            }
        } catch {}
    }
}

function Invoke-CooldownsLocked {
    param([scriptblock]$Body)
    $mutex = [Threading.Mutex]::new($false, "Global\DelegatorCooldowns")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for the cooldowns lock." }
        & $Body
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-ModelCooldowns {
    if (-not (Test-Path -LiteralPath $CooldownsFile)) {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    try {
        $state = Get-Content -LiteralPath $CooldownsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    if (-not $state -or -not $state.PSObject.Properties["models"] -or -not $state.models) {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    return $state
}

function Test-ModelCoolingDown {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $false }
    try {
        $state = Read-ModelCooldowns
        if (-not $state.models.PSObject.Properties[$ModelId]) { return $false }
        $entry = $state.models.PSObject.Properties[$ModelId].Value
        if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.until)) { return $false }
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
        $until = [DateTime]::Parse([string]$entry.until, [Globalization.CultureInfo]::InvariantCulture, $styles)
        return ($until -gt [DateTime]::UtcNow)
    } catch {
        return $false
    }
}

function Set-ModelCooldown {
    # DEV_CONTRACTS section 5: per-MODEL cooldowns in cooldowns.json (complements per-account state).
    param(
        [string]$ModelId,
        [string]$Reason,
        [int]$Seconds,
        [int]$StatusCode,
        [object]$UntilUtc
    )
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return }
    if ($Seconds -le 0 -and -not $UntilUtc) { return }
    try {
        Ensure-DelegateDirectory
        Invoke-CooldownsLocked {
            $state = Read-ModelCooldowns
            $failCount = 1
            if ($state.models.PSObject.Properties[$ModelId]) {
                try { $failCount = [int]$state.models.PSObject.Properties[$ModelId].Value.failCount + 1 } catch { $failCount = 1 }
            }
            $until = if ($UntilUtc) { [DateTime]$UntilUtc } else { [DateTime]::UtcNow.AddSeconds($Seconds) }
            $entry = [pscustomobject]@{
                until = $until.ToString("yyyy-MM-ddTHH:mm:ssZ")
                reason = $Reason
                failCount = $failCount
                lastStatus = $StatusCode
            }
            $state.models | Add-Member -Force -NotePropertyName $ModelId -NotePropertyValue $entry
            Write-Utf8NoBom -Path $CooldownsFile -Text ($state | ConvertTo-Json -Depth 8)
        }
    } catch {}
}

function Clear-ModelCooldown {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return }
    try {
        if (-not (Test-Path -LiteralPath $CooldownsFile)) { return }
        Invoke-CooldownsLocked {
            $state = Read-ModelCooldowns
            if (-not $state.models.PSObject.Properties[$ModelId]) { return }
            $state.models.PSObject.Properties.Remove($ModelId)
            Write-Utf8NoBom -Path $CooldownsFile -Text ($state | ConvertTo-Json -Depth 8)
        }
    } catch {}
}

function Get-ModelCooldownSeconds {
    # DEV_CONTRACTS section 5 policy: rate_limit honors Retry-After (default 120s),
    # auth/not_found 6h, content_policy 10min; transient classes get short cooldowns.
    param([string]$ErrorClass, [int]$RetryAfterSec)
    if ($ErrorClass -eq "rate_limit") {
        if ($RetryAfterSec -gt 0) { return $RetryAfterSec }
        return 120
    }
    if ($ErrorClass -eq "auth" -or $ErrorClass -eq "not_found") { return 21600 }
    if ($ErrorClass -eq "content_policy") { return 600 }
    if ($ErrorClass -eq "server" -or $ErrorClass -eq "timeout") { return 60 }
    if ($ErrorClass -eq "network") { return 30 }
    return 0
}

function Get-NextPacificMidnightUtc {
    # Gemini free-tier daily quotas reset at midnight America/Los_Angeles.
    try {
        $tz = [TimeZoneInfo]::FindSystemTimeZoneById("Pacific Standard Time")
        $nowPacific = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
        $midnightPacific = [DateTime]::SpecifyKind($nowPacific.Date.AddDays(1), [DateTimeKind]::Unspecified)
        return [TimeZoneInfo]::ConvertTimeToUtc($midnightPacific, $tz)
    } catch {
        return [DateTime]::UtcNow.Date.AddDays(1)
    }
}

function Read-DelegatorConfig {
    if (-not (Test-Path -LiteralPath $AppConfigFile)) {
        throw "Delegator config not found. Add Google accounts in the Delegator GUI first: $AppConfigFile"
    }
    try {
        return Get-Content -LiteralPath $AppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Delegator config is invalid or unreadable."
    }
}

function Unprotect-DelegatorSecret {
    param([string]$EncryptedBase64)
    if ([string]::IsNullOrWhiteSpace($EncryptedBase64)) { return "" }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $encrypted = [Convert]::FromBase64String($EncryptedBase64)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted,
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {
        throw "A Delegator Google key could not be decrypted with Windows DPAPI."
    }
}

function Get-GoogleAccountSummaries {
    $config = Read-DelegatorConfig
    $rows = @()
    foreach ($account in @($config.google_accounts)) {
        if (-not $account -or [string]::IsNullOrWhiteSpace([string]$account.id)) { continue }
        $rows += [pscustomobject]@{
            id = [string]$account.id
            label = [string]$account.label
            enabled = if ($null -eq $account.enabled) { $true } else { [bool]$account.enabled }
            encrypted = [string]$account.api_key_enc
        }
    }
    return $rows
}

function Get-EnabledGoogleAccounts {
    $rows = @()
    foreach ($account in @(Get-GoogleAccountSummaries)) {
        if (-not $account.enabled) { continue }
        if (-not [string]::IsNullOrWhiteSpace($Profile) -and
            $account.id -ne $Profile -and $account.label -ne $Profile) {
            continue
        }
        $key = Unprotect-DelegatorSecret $account.encrypted
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        $rows += [pscustomobject]@{
            id = $account.id
            label = $account.label
            key = $key
        }
    }
    return $rows
}

function Get-EnabledGeminiModels {
    $config = Read-DelegatorConfig
    return @($config.enabled_gemini_models | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function New-UsageState {
    return [pscustomobject]@{
        version = 1
        usedDate = $Today
        accounts = [pscustomobject]@{}
    }
}

function Read-UsageState {
    Ensure-DelegateDirectory
    if (Test-Path -LiteralPath $UsageFile) {
        try { $state = Get-Content -LiteralPath $UsageFile -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $state = New-UsageState }
    } else {
        $state = New-UsageState
    }
    if (-not $state.PSObject.Properties["accounts"] -or -not $state.accounts) {
        $state | Add-Member -Force -NotePropertyName accounts -NotePropertyValue ([pscustomobject]@{})
    }
    if ($state.usedDate -ne $Today) {
        $state = New-UsageState
    }
    return $state
}

function Save-UsageState {
    param($State)
    Ensure-DelegateDirectory
    Write-Utf8NoBom -Path $UsageFile -Text ($State | ConvertTo-Json -Depth 20)
}

function Ensure-UsageAccount {
    param($State, $Account)
    if (-not $State.accounts.PSObject.Properties[$Account.id]) {
        $State.accounts | Add-Member -NotePropertyName $Account.id -NotePropertyValue ([pscustomobject]@{
            label = $Account.label
            requestsToday = 0
            tokensToday = 0
            successes = 0
            failures = 0
            cooldownUntil = $null
            lastStatus = "new"
            lastModel = $null
            lastUsedAt = $null
        })
    }
    $entry = $State.accounts.PSObject.Properties[$Account.id].Value
    $entry.label = $Account.label
    return $entry
}

function Reserve-GoogleAccount {
    param([object[]]$Accounts, [string[]]$ExcludedIds)
    $script:ReservedAccountId = $null
    Invoke-UsageLocked {
        $state = Read-UsageState
        $now = Get-Date
        $candidates = foreach ($account in $Accounts) {
            if ($ExcludedIds -contains $account.id) { continue }
            $entry = Ensure-UsageAccount -State $state -Account $account
            $cooling = $false
            if ($entry.cooldownUntil) {
                try { $cooling = ([datetime]$entry.cooldownUntil) -gt $now } catch {}
            }
            if ($cooling) { continue }
            $requestsToday = 0
            try { $requestsToday = [long]$entry.requestsToday } catch {}
            if ($DailyQuota -gt 0 -and $requestsToday -ge $DailyQuota) { continue }
            [pscustomobject]@{
                id = $account.id
                tokens = [long]$entry.tokensToday
                requests = [long]$entry.requestsToday
                lastUsed = if ($entry.lastUsedAt) { [datetime]$entry.lastUsedAt } else { [datetime]::MinValue }
            }
        }
        $picked = @($candidates | Sort-Object tokens, requests, lastUsed, id | Select-Object -First 1)
        if ($picked.Count -gt 0) {
            $account = $Accounts | Where-Object id -eq $picked[0].id | Select-Object -First 1
            $entry = Ensure-UsageAccount -State $state -Account $account
            $entry.requestsToday = [long]$entry.requestsToday + 1
            $entry.lastUsedAt = (Get-Date).ToString("o")
            $entry.lastStatus = "reserved"
            Save-UsageState $state
            $script:ReservedAccountId = $account.id
        }
    }
    if (-not $script:ReservedAccountId) { return $null }
    return $Accounts | Where-Object id -eq $script:ReservedAccountId | Select-Object -First 1
}

function Complete-GoogleAttempt {
    param(
        $Account,
        [string]$ModelId,
        [bool]$Success,
        [long]$Tokens,
        [string]$Status,
        [int]$CooldownSeconds = 0,
        [switch]$CountRequest
    )
    Invoke-UsageLocked {
        $state = Read-UsageState
        $entry = Ensure-UsageAccount -State $state -Account $Account
        $entry.lastModel = $ModelId
        $entry.lastStatus = $Status
        $entry.lastUsedAt = (Get-Date).ToString("o")
        if ($CountRequest) {
            $entry.requestsToday = [long]$entry.requestsToday + 1
        }
        if ($Success) {
            $entry.successes = [long]$entry.successes + 1
            $entry.tokensToday = [long]$entry.tokensToday + [Math]::Max(0, $Tokens)
            $entry.cooldownUntil = $null
        } else {
            $entry.failures = [long]$entry.failures + 1
            if ($CooldownSeconds -gt 0) {
                $entry.cooldownUntil = (Get-Date).AddSeconds($CooldownSeconds).ToString("o")
            }
        }
        Save-UsageState $state
    }
}

function Select-DelegateModel {
    param([string]$Text, [string[]]$EnabledModels)
    if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -ne "auto") {
        if ($EnabledModels -notcontains $Model) {
            throw "Gemini model '$Model' is not enabled in the Delegator GUI."
        }
        return $Model
    }

    $preferred = if ($Complexity -eq "deep") {
        @($ProPreference + $FlashPreference + $LitePreference)
    } elseif ($Complexity -eq "fast") {
        @($LitePreference + $FlashPreference + $ProPreference)
    } elseif ($Complexity -eq "normal") {
        @($FlashPreference + $ProPreference + $LitePreference)
    } elseif ($Text.Length -gt 6000 -or $Text -match "architecture|security|crypt|auth|database|migration|race|concurrency|refactor|debug|root cause|production|critical") {
        @($ProPreference + $FlashPreference + $LitePreference)
    } else {
        @($FlashPreference + $LitePreference + $ProPreference)
    }
    $selected = $preferred | Where-Object { $EnabledModels -contains $_ } | Select-Object -First 1
    if (-not $selected) { $selected = $EnabledModels | Select-Object -First 1 }
    if (-not $selected) { throw "No Gemini models are enabled in the Delegator GUI." }
    return [string]$selected
}

function Get-ModelAttempts {
    param([string]$SelectedModel, [string[]]$EnabledModels)
    if (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -ne "auto") {
        return @($SelectedModel)
    }
    return @($SelectedModel) + @($ProPreference + $FlashPreference + $LitePreference |
        Where-Object { $EnabledModels -contains $_ -and $_ -ne $SelectedModel } |
        Select-Object -Unique)
}

function Get-DelegateProxy {
    param([string]$Provider)
    # DEV_CONTRACTS section 7a: effective outbound proxy for MODEL traffic, or $null.
    # Precedence: env DELEGATOR_PROXY ("off" disables, any other non-empty value
    # forces that proxy) > <RT>\proxy.json {"enabled":true,"url":...}.
    $override = [string]$env:DELEGATOR_PROXY
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        if ($override.Trim() -ieq "off") { return $null }
        return $override.Trim()
    }
    # GUI-managed proxies (config.json "proxies", DEV_CONTRACTS 7a) are authoritative
    # when the key exists; the legacy <RT>\proxy.json below is only a pre-v8 fallback.
    try {
        $guiConfigPath = Join-Path $env:APPDATA "Delegator\DelegatorWin\config\config.json"
        if (Test-Path -LiteralPath $guiConfigPath) {
            $guiConfig = Get-Content -LiteralPath $guiConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($guiConfig -and $guiConfig.PSObject.Properties["proxies"]) {
                foreach ($entry in @($guiConfig.proxies)) {
                    if (-not $entry) { continue }
                    if ($entry.PSObject.Properties["enabled"] -and -not [bool]$entry.enabled) { continue }
                    if (-not $entry.PSObject.Properties["url"] -or [string]::IsNullOrWhiteSpace([string]$entry.url)) { continue }
                    if (-not [string]::IsNullOrWhiteSpace($Provider)) {
                        $flagName = "use_for_" + $Provider
                        if ($entry.PSObject.Properties[$flagName] -and -not [bool]$entry.$flagName) { continue }
                    }
                    return ([string]$entry.url).Trim()
                }
                return $null
            }
        }
    } catch {}
    $proxyFile = Join-Path $DelegateHome "proxy.json"
    if (-not (Test-Path -LiteralPath $proxyFile)) { return $null }
    try {
        $config = Get-Content -LiteralPath $proxyFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config -and $config.PSObject.Properties["enabled"] -and [bool]$config.enabled -and
            $config.PSObject.Properties["url"] -and -not [string]::IsNullOrWhiteSpace([string]$config.url)) {
            if (-not [string]::IsNullOrWhiteSpace($Provider) -and $config.PSObject.Properties[$Provider] -and
                -not [bool]$config.$Provider) { return $null }
            return ([string]$config.url).Trim()
        }
    } catch {}
    return $null
}

function Invoke-CurlJsonRequest {
    # DEV_CONTRACTS section 7a: PS 5.1/.NET cannot speak SOCKS, so socks5/socks5h
    # proxied calls route through curl.exe from System32 (native SOCKS support).
    # Returns: ok, statusCode, body (parsed JSON), rawBody, error. Never throws.
    # The error text keeps "(NNN)" status markers so the existing classifiers work.
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [int]$TimeoutSec,
        [string]$ProxyUrl
    )
    $curlExe = Join-Path $env:SystemRoot "System32\curl.exe"
    if (-not (Test-Path -LiteralPath $curlExe)) {
        return [pscustomobject]@{ ok = $false; statusCode = 0; body = $null; rawBody = ""; error = "curl.exe is missing from System32; it is required for SOCKS proxying via $ProxyUrl." }
    }
    $tempTag = [Guid]::NewGuid().ToString("n")
    $tempDir = [IO.Path]::GetTempPath()
    $bodyFile = Join-Path $tempDir ("delegator-curl-body-" + $tempTag + ".bin")
    $respFile = Join-Path $tempDir ("delegator-curl-resp-" + $tempTag + ".bin")
    $errFile = Join-Path $tempDir ("delegator-curl-err-" + $tempTag + ".txt")
    $wroteBody = $false
    try {
        $curlArgs = @(
            "--silent", "--show-error", "--stderr", $errFile,
            "--max-time", [string]([Math]::Max(1, $TimeoutSec)),
            "--proxy", $ProxyUrl,
            "--request", $Method,
            "--output", $respFile,
            "--write-out", "%{http_code}"
        )
        foreach ($name in @($Headers.Keys)) {
            $curlArgs += @("--header", ("{0}: {1}" -f $name, [string]$Headers[$name]))
        }
        if ($null -ne $BodyBytes -and $BodyBytes.Length -gt 0) {
            [IO.File]::WriteAllBytes($bodyFile, $BodyBytes)
            $wroteBody = $true
            $curlArgs += @("--data-binary", ("@" + $bodyFile))
        }
        $curlArgs += $Uri
        $stdout = ((& $curlExe @curlArgs) -join "").Trim()
        $exitCode = $LASTEXITCODE
        $rawBody = ""
        if (Test-Path -LiteralPath $respFile) {
            try { $rawBody = [IO.File]::ReadAllText($respFile, [Text.UTF8Encoding]::new($false)) } catch {}
        }
        $curlError = ""
        if (Test-Path -LiteralPath $errFile) {
            try { $curlError = ([IO.File]::ReadAllText($errFile, [Text.UTF8Encoding]::new($false))).Trim() } catch {}
        }
        $statusCode = 0
        if ($stdout -match '(\d{3})\s*$') { $statusCode = [int]$Matches[1] }
        if ($exitCode -ne 0) {
            if ([string]::IsNullOrWhiteSpace($curlError)) { $curlError = "curl exit code $exitCode" }
            return [pscustomobject]@{ ok = $false; statusCode = 0; body = $null; rawBody = $rawBody; error = "Proxy connection failed via ${ProxyUrl}: $curlError" }
        }
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            return [pscustomobject]@{ ok = $false; statusCode = $statusCode; body = $null; rawBody = $rawBody; error = "The remote server returned an error: ($statusCode) via proxy ${ProxyUrl}." }
        }
        $parsedBody = $null
        try { $parsedBody = $rawBody | ConvertFrom-Json } catch {
            return [pscustomobject]@{ ok = $false; statusCode = $statusCode; body = $null; rawBody = $rawBody; error = "Response via proxy ${ProxyUrl} was not valid JSON." }
        }
        return [pscustomobject]@{ ok = $true; statusCode = $statusCode; body = $parsedBody; rawBody = $rawBody; error = "" }
    } finally {
        if ($wroteBody) { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $respFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-GoogleGenerateContent {
    param($Account, [string]$ModelId, [string]$Text, [int]$Seconds)
    $cleanModel = $ModelId -replace '^models/', ''
    $uri = "https://generativelanguage.googleapis.com/v1beta/models/${cleanModel}:generateContent"
    $headers = @{
        "x-goog-api-key" = $Account.key
        "Content-Type" = "application/json; charset=utf-8"
    }
    $body = @{
        contents = @(@{
            role = "user"
            parts = @(@{ text = $Text })
        })
    } | ConvertTo-Json -Depth 12 -Compress
    # DEV_CONTRACTS section 4: PS 5.1 encodes string bodies as ISO-8859-1 and turns
    # non-ASCII (Cyrillic) into '?', so the JSON body must be sent as UTF-8 bytes.
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
    # DEV_CONTRACTS section 7a: all model traffic honors the optional outbound proxy.
    $proxyUrl = Get-DelegateProxy -Provider 'gemini'
    try {
        if (-not [string]::IsNullOrWhiteSpace($proxyUrl) -and $proxyUrl -match '^(?i)socks5h?://') {
            $curl = Invoke-CurlJsonRequest -Method "POST" -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $proxyUrl
            if (-not $curl.ok) {
                $message = [string]$curl.error
                $retryAfterSec = 0
                try {
                    if (-not [string]::IsNullOrWhiteSpace($curl.rawBody)) {
                        if ($curl.rawBody -match '"retryDelay"\s*:\s*"(\d+)') { $retryAfterSec = [int]$Matches[1] }
                        $errorObject = $curl.rawBody | ConvertFrom-Json
                        if ($errorObject.error.message) { $message = [string]$errorObject.error.message }
                    }
                } catch {}
                return [pscustomobject]@{ ok = $false; statusCode = [int]$curl.statusCode; answer = ""; tokens = 0; promptTokens = $null; completionTokens = $null; usage = $null; error = $message; retryAfterSec = $retryAfterSec }
            }
            $response = $curl.body
        } elseif (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            # Invoke-WebRequest + explicit UTF-8 decode: PS 5.1 Invoke-RestMethod decodes
            # JSON bodies as Latin-1 when the response lacks a charset, turning Cyrillic
            # answers into mojibake. Raw bytes are always UTF-8 for the Gemini API.
            $webResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Headers $headers -Body $bodyBytes -TimeoutSec $Seconds -Proxy $proxyUrl
            $response = [System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray()) | ConvertFrom-Json
        } else {
            $webResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri $uri -Headers $headers -Body $bodyBytes -TimeoutSec $Seconds
            $response = [System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray()) | ConvertFrom-Json
        }
        $answer = (@($response.candidates[0].content.parts | ForEach-Object { [string]$_.text }) -join "").Trim()
        $tokens = 0
        try { $tokens = [long]$response.usageMetadata.totalTokenCount } catch {}
        $promptTokens = $null
        $completionTokens = $null
        try { if ($null -ne $response.usageMetadata.promptTokenCount) { $promptTokens = [long]$response.usageMetadata.promptTokenCount } } catch {}
        try { if ($null -ne $response.usageMetadata.candidatesTokenCount) { $completionTokens = [long]$response.usageMetadata.candidatesTokenCount } } catch {}
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return [pscustomobject]@{ ok = $false; statusCode = 200; answer = ""; tokens = $tokens; promptTokens = $promptTokens; completionTokens = $completionTokens; usage = $response.usageMetadata; error = "Google response contained no text."; retryAfterSec = 0 }
        }
        return [pscustomobject]@{ ok = $true; statusCode = 200; answer = $answer; tokens = $tokens; promptTokens = $promptTokens; completionTokens = $completionTokens; usage = $response.usageMetadata; error = ""; retryAfterSec = 0 }
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        $retryAfterSec = 0
        try {
            $retryHeader = [string]$_.Exception.Response.Headers["Retry-After"]
            if ($retryHeader -match '^\d+$') { $retryAfterSec = [int]$retryHeader }
        } catch {}
        $message = "Google API request failed"
        $errorBody = ""
        try { if ($_.ErrorDetails.Message) { $errorBody = [string]$_.ErrorDetails.Message } } catch {}
        if ([string]::IsNullOrWhiteSpace($errorBody)) {
            # PS 5.1 does not always populate ErrorDetails (e.g. chunked bodies), which
            # hid real Google errors behind a generic message. Read the response stream.
            try {
                $respStream = $_.Exception.Response.GetResponseStream()
                if ($respStream) {
                    $reader = New-Object IO.StreamReader($respStream)
                    $errorBody = $reader.ReadToEnd()
                }
            } catch {}
        }
        try {
            if (-not [string]::IsNullOrWhiteSpace($errorBody)) {
                if ($errorBody -match '"retryDelay"\s*:\s*"(\d+)') {
                    $retryAfterSec = [Math]::Max($retryAfterSec, [int]$Matches[1])
                }
                $errorObject = $errorBody | ConvertFrom-Json
                if ($errorObject.error.message) { $message = [string]$errorObject.error.message }
            }
        } catch {}
        # DEV_CONTRACTS section 7a: when the proxy itself is unreachable (statusCode 0,
        # connection refused/timeout) surface a clear error naming the proxy url.
        # statusCode stays 0 so Get-FailurePolicy classifies it as network/timeout, not auth.
        if ($statusCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($proxyUrl)) {
            $message = "Proxy or network connection failed via proxy ${proxyUrl}: " + [string]$_.Exception.Message
        }
        return [pscustomobject]@{ ok = $false; statusCode = $statusCode; answer = ""; tokens = 0; promptTokens = $null; completionTokens = $null; usage = $null; error = $message; retryAfterSec = $retryAfterSec }
    }
}

function Get-FailurePolicy {
    # status/cooldown drive the existing per-ACCOUNT state (google-api-usage.json, unchanged);
    # errorClass is the DEV_CONTRACTS section 5 normalized class used for per-MODEL cooldowns.
    param($Result)
    if ($Result.statusCode -eq 429 -or $Result.error -match "(?i)quota|resource_exhausted|rate limit") {
        $daily = [bool]($Result.error -match "(?i)per\s*day|daily")
        return [pscustomobject]@{ status = "quota_or_rate_limited"; cooldown = 300; tryNextAccount = $true; errorClass = "rate_limit"; dailyQuota = $daily }
    }
    if ($Result.statusCode -eq 401) {
        return [pscustomobject]@{ status = "invalid_key"; cooldown = 1800; tryNextAccount = $true; errorClass = "auth"; dailyQuota = $false }
    }
    if ($Result.statusCode -eq 403) {
        return [pscustomobject]@{ status = "permission_or_location_denied"; cooldown = 900; tryNextAccount = $true; errorClass = "auth"; dailyQuota = $false }
    }
    if ($Result.statusCode -eq 404) {
        return [pscustomobject]@{ status = "model_or_request_error"; cooldown = 0; tryNextAccount = $false; errorClass = "not_found"; dailyQuota = $false }
    }
    if (($Result.statusCode -eq 400 -or $Result.statusCode -eq 200) -and $Result.error -match "(?i)safety|blocked|content policy|prohibited") {
        return [pscustomobject]@{ status = "model_or_request_error"; cooldown = 0; tryNextAccount = $false; errorClass = "content_policy"; dailyQuota = $false }
    }
    if (($Result.statusCode -eq 400 -or $Result.statusCode -eq 200) -and $Result.error -match "(?i)context|token limit|input token count|too (long|large)|exceeds the maximum") {
        return [pscustomobject]@{ status = "model_or_request_error"; cooldown = 0; tryNextAccount = $false; errorClass = "context_overflow"; dailyQuota = $false }
    }
    if ($Result.statusCode -ge 500) {
        return [pscustomobject]@{ status = "provider_error"; cooldown = 60; tryNextAccount = $true; errorClass = "server"; dailyQuota = $false }
    }
    if ($Result.statusCode -eq 0) {
        if ($Result.error -match "(?i)timed?\s*out|timeout") {
            return [pscustomobject]@{ status = "provider_error"; cooldown = 60; tryNextAccount = $true; errorClass = "timeout"; dailyQuota = $false }
        }
        return [pscustomobject]@{ status = "provider_error"; cooldown = 60; tryNextAccount = $true; errorClass = "network"; dailyQuota = $false }
    }
    return [pscustomobject]@{ status = "model_or_request_error"; cooldown = 0; tryNextAccount = $false; errorClass = "unknown"; dailyQuota = $false }
}

function Run-Ask {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    $accounts = @(Get-EnabledGoogleAccounts)
    if ($accounts.Count -eq 0) { throw "No enabled Google API accounts in the Delegator GUI." }
    $enabledModels = @(Get-EnabledGeminiModels)
    $selectedModel = Select-DelegateModel -Text $Prompt -EnabledModels $enabledModels
    $modelAttempts = @(Get-ModelAttempts -SelectedModel $selectedModel -EnabledModels $enabledModels)
    # DEV_CONTRACTS section 5: skip models with an active cooldown unless nothing else is left.
    $activeModels = @($modelAttempts | Where-Object { -not (Test-ModelCoolingDown $_) })
    if ($activeModels.Count -gt 0) { $modelAttempts = $activeModels }
    $runId = [Guid]::NewGuid().ToString("n")
    $started = Get-Date
    $promptSummary = Get-PromptSummary $Prompt
    $attempts = @()
    Write-RunEvent ([pscustomobject]@{ runId = $runId; event = "started"; status = "running"; promptSummary = $promptSummary; selectedModel = $selectedModel; accountSource = "delegator-dpapi" })

    foreach ($currentModel in $modelAttempts) {
        $excluded = @()
        $modelPolicy = $null
        $modelStatusCode = 0
        $modelRetryAfter = 0
        while ($excluded.Count -lt $accounts.Count) {
            $account = Reserve-GoogleAccount -Accounts $accounts -ExcludedIds $excluded
            if (-not $account) { break }
            $excluded += $account.id
            Write-RunEvent ([pscustomobject]@{ runId = $runId; event = "attempt_started"; status = "running"; accountId = $account.id; accountLabel = $account.label; model = $currentModel })
            $result = Invoke-GoogleGenerateContent -Account $account -ModelId $currentModel -Text $Prompt -Seconds $TimeoutSec
            if ($result.ok) {
                Complete-GoogleAttempt -Account $account -ModelId $currentModel -Success $true -Tokens $result.tokens -Status "ok"
                $attempts += [pscustomobject]@{ accountId = $account.id; accountLabel = $account.label; model = $currentModel; status = "ok" }
                $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
                Write-RunEvent ([pscustomobject]@{ runId = $runId; event = "completed"; status = "ok"; accountId = $account.id; accountLabel = $account.label; model = $currentModel; tokens = $result.tokens; elapsedMs = $elapsedMs })
                Write-DelegateUsageRecord -Mode $Command -Provider "gemini" -ModelId $currentModel -PromptTokens $result.promptTokens -CompletionTokens $result.completionTokens -TotalTokens $result.tokens -Cost 0.0 -ElapsedMs $elapsedMs -Ok $true -AccountId $account.id
                Clear-ModelCooldown $currentModel
                if ($Json) {
                    [pscustomobject]@{ profile = $account.id; account = $account.label; model = $currentModel; output = $result.answer; stats = $result.usage; promptTokens = $result.promptTokens; completionTokens = $result.completionTokens; totalTokens = $result.tokens; cost = 0.0; attempts = $attempts } | ConvertTo-Json -Depth 10
                } else {
                    Write-Output $result.answer
                }
                return
            }

            $policy = Get-FailurePolicy $result
            $modelPolicy = $policy
            $modelStatusCode = $result.statusCode
            $modelRetryAfter = [int]$result.retryAfterSec
            Complete-GoogleAttempt -Account $account -ModelId $currentModel -Success $false -Tokens 0 -Status $policy.status -CooldownSeconds $policy.cooldown
            $attempts += [pscustomobject]@{ accountId = $account.id; accountLabel = $account.label; model = $currentModel; status = $policy.status; statusCode = $result.statusCode }
            Write-RunEvent ([pscustomobject]@{ runId = $runId; event = "attempt_failed"; status = $policy.status; errorClass = $policy.errorClass; accountId = $account.id; accountLabel = $account.label; model = $currentModel; statusCode = $result.statusCode; errorPreview = (Get-PromptSummary $result.error) })
            if (-not $policy.tryNextAccount) { break }
        }
        # The model failed for every account we could try: put the MODEL on cooldown
        # (per-account cooldowns were already applied by Complete-GoogleAttempt above).
        if ($modelPolicy) {
            if ($modelPolicy.dailyQuota) {
                Set-ModelCooldown -ModelId $currentModel -Reason $modelPolicy.errorClass -Seconds 0 -StatusCode $modelStatusCode -UntilUtc (Get-NextPacificMidnightUtc)
            } else {
                $cooldownSec = Get-ModelCooldownSeconds -ErrorClass $modelPolicy.errorClass -RetryAfterSec $modelRetryAfter
                if ($cooldownSec -gt 0) {
                    Set-ModelCooldown -ModelId $currentModel -Reason $modelPolicy.errorClass -Seconds $cooldownSec -StatusCode $modelStatusCode
                }
            }
        }
    }

    $elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
    Write-RunEvent ([pscustomobject]@{ runId = $runId; event = "completed"; status = "failed"; attempts = $attempts.Count; elapsedMs = $elapsedMs })
    $failedModel = if ($attempts.Count -gt 0) { [string]$attempts[$attempts.Count - 1].model } else { $selectedModel }
    $failedAccountId = if ($attempts.Count -gt 0) { [string]$attempts[$attempts.Count - 1].accountId } else { $null }
    Write-DelegateUsageRecord -Mode $Command -Provider "gemini" -ModelId $failedModel -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null -ElapsedMs $elapsedMs -Ok $false -AccountId $failedAccountId
    throw "All enabled Delegator Google accounts/models failed. Run gemini-delegate status."
}

function Show-Status {
    $summaries = @(Get-GoogleAccountSummaries)
    $state = Read-UsageState
    $rows = foreach ($account in $summaries) {
        $entry = $state.accounts.PSObject.Properties[$account.id]
        $usage = if ($entry) { $entry.Value } else { $null }
        [pscustomobject]@{
            id = $account.id
            account = $account.label
            enabled = $account.enabled
            requestsToday = if ($usage) { $usage.requestsToday } else { 0 }
            tokensToday = if ($usage) { $usage.tokensToday } else { 0 }
            lastStatus = if ($usage) { $usage.lastStatus } else { "new" }
            lastModel = if ($usage) { $usage.lastModel } else { $null }
            cooldownUntil = if ($usage) { $usage.cooldownUntil } else { $null }
        }
    }
    if ($Json) { $rows | ConvertTo-Json -Depth 8 } else { $rows | Format-Table -AutoSize }
}

function Run-Health {
    $accounts = @(Get-EnabledGoogleAccounts)
    $models = @(Get-EnabledGeminiModels)
    if ($accounts.Count -eq 0 -or $models.Count -eq 0) { throw "No enabled Google accounts or Gemini models in Delegator." }
    $healthModel = if ($Model -and $models -contains $Model) { $Model } else { @($FlashPreference + $LitePreference + $ProPreference | Where-Object { $models -contains $_ } | Select-Object -First 1)[0] }
    foreach ($account in $accounts) {
        $result = Invoke-GoogleGenerateContent -Account $account -ModelId $healthModel -Text "Reply with exactly OK" -Seconds $TimeoutSec
        if ($result.ok) {
            Complete-GoogleAttempt -Account $account -ModelId $healthModel -Success $true -Tokens $result.tokens -Status "ok" -CountRequest
            Write-Output "$($account.label): ok"
        } else {
            $policy = Get-FailurePolicy $result
            Complete-GoogleAttempt -Account $account -ModelId $healthModel -Success $false -Tokens 0 -Status $policy.status -CooldownSeconds $policy.cooldown -CountRequest
            Write-Output "$($account.label): $($policy.status) [$($policy.errorClass)] $(Get-PromptSummary $result.error)"
        }
    }
}

function Reset-Usage {
    Invoke-UsageLocked { Save-UsageState (New-UsageState) }
    Write-Output "Reset Delegator Google API usage counters for $Today."
}

if ($MyInvocation.InvocationName -ne ".") {
    switch ($Command) {
        # See opencode-delegate.ps1: an in-process caller reads $LASTEXITCODE,
        # which a plain `return` never sets.
        "ask" { Run-Ask; exit 0 }
        "status" { Show-Status }
        "profiles" { Get-GoogleAccountSummaries | ForEach-Object { "$($_.id): $($_.label)" } }
        "health" { Run-Health }
        "reset" { Reset-Usage }
        "update" { Write-Output "Gemini CLI is not used; Delegator calls the native Google generateContent API." }
        "refresh" { Show-Status }
    }
}

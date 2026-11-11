param(
    [Parameter(Position = 0)]
    [ValidateSet("ask", "models", "stats")]
    [string]$Command = "ask",

    [Parameter(Position = 1)]
    [string]$Prompt,

    [string]$Model,
    [string]$Domain,
    [ValidateSet("auto", "fast", "normal", "deep")]
    [string]$Complexity = "auto",
    [int]$TimeoutSec = 180,
    [switch]$Json
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "platform.ps1")

$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$DelegateHome = (Get-DelegatorRuntimeHome)
$RunsFile = Join-Path $DelegateHome "runs.jsonl"
$UsageLogFile = Join-Path $DelegateHome "usage.jsonl"
$CooldownsFile = Join-Path $DelegateHome "cooldowns.json"
$ModelAvailabilityFile = Join-Path $DelegateHome "model-availability.json"
$ZenCatalogFile = Join-Path $DelegateHome "opencode-zen-catalog.json"
$OpenCodeExtraModelsFile = Join-Path $DelegateHome "opencode-extra-models.json"
$ModelSettingsFile = Join-Path $DelegateHome "delegate-model-settings.json"
$OpenCodeConfigDir = Join-Path $DelegateHome "opencode-config"
$OpenCodeWorkDir = Join-Path $DelegateHome "opencode-workdir"
$OpenCodeGuiModelStateFile = Join-Path $script:DelegatorUserHome ".local/state/opencode/model.json"

# ── Benchmark isolation ───────────────────────────────────────────────────────
# A benchmark run must never reach the usage numbers: it burns tokens on tasks
# the user never asked for, so counting it inflates both "spent" and "saved".
# benchmark.ps1 holds <RT>\benchmark-active.json between `start` and
# `finish`/`cancel`; a stale flag is ignored so a dead agent cannot switch
# accounting off forever. ONE OF THREE COPIES - see delegator-common.ps1.
$BenchmarkFlagFile = Join-Path $DelegateHome "benchmark-active.json"
$BenchmarkStaleHours = 6

function Test-DelegatorBenchmarkActive {
    try {
        if (-not (Test-Path -LiteralPath $BenchmarkFlagFile)) { return $false }
        $age = [DateTime]::UtcNow - ([IO.File]::GetLastWriteTimeUtc($BenchmarkFlagFile))
        return ($age.TotalHours -lt $BenchmarkStaleHours)
    } catch { return $false }
}
$DelegatorAppConfigFile = $script:DelegatorConfigFile
$OpenCodeBigPickleModel = if ($env:CODEX_OPENCODE_BIG_PICKLE_MODEL) { $env:CODEX_OPENCODE_BIG_PICKLE_MODEL } else { "opencode/big-pickle" }
$OpenCodeNemotronModel = if ($env:CODEX_OPENCODE_NEMOTRON_MODEL) { $env:CODEX_OPENCODE_NEMOTRON_MODEL } else { "opencode/nemotron-3-ultra-free" }
$OpenCodeLagunaModel = if ($env:CODEX_OPENCODE_LAGUNA_MODEL) { $env:CODEX_OPENCODE_LAGUNA_MODEL } else { "opencode/laguna-s-2.1-free" }
$OpenCodeLingModel = if ($env:CODEX_OPENCODE_LING_MODEL) { $env:CODEX_OPENCODE_LING_MODEL } elseif ($env:CODEX_OPENCODE_RING_MODEL) { $env:CODEX_OPENCODE_RING_MODEL } else { "opencode/ling-3.0-flash-free" }
$OpenCodeMimoModel = if ($env:CODEX_OPENCODE_MIMO_MODEL) { $env:CODEX_OPENCODE_MIMO_MODEL } else { "opencode/mimo-v2.5-free" }
$OpenCodeDeepSeekFlashModel = if ($env:CODEX_OPENCODE_DEEPSEEK_FLASH_MODEL) { $env:CODEX_OPENCODE_DEEPSEEK_FLASH_MODEL } else { "opencode/deepseek-v4-flash-free" }
$OpenCodeNorthModel = if ($env:CODEX_OPENCODE_NORTH_MODEL) { $env:CODEX_OPENCODE_NORTH_MODEL } else { "opencode/north-mini-code-free" }
$OpenCodeFastModels   = @($OpenCodeDeepSeekFlashModel, $OpenCodeLingModel, $OpenCodeMimoModel, $OpenCodeBigPickleModel)
$OpenCodeNormalModels = @($OpenCodeDeepSeekFlashModel, $OpenCodeNemotronModel, $OpenCodeLagunaModel, $OpenCodeLingModel, $OpenCodeMimoModel, $OpenCodeNorthModel, $OpenCodeBigPickleModel)
$OpenCodeDeepModels   = @($OpenCodeDeepSeekFlashModel, $OpenCodeNemotronModel, $OpenCodeNorthModel, $OpenCodeLagunaModel, $OpenCodeMimoModel, $OpenCodeLingModel, $OpenCodeBigPickleModel)

# Per-model idle timeout: heavy/slow models get 150s, fast models get 90s.
#
# These are NOT arbitrary. Measured on this machine (usage.jsonl, 2026-08-12):
# deepseek-v4-flash answers a real question in 34s p50 with a 45.8s max, and
# nemotron-3-ultra needs 71.6s on an 8k prompt. With the old 45/90 budget the
# strongest model's answer was thrown away right before it arrived - twice in a
# row on a 250-character Python question - and the caller silently got a
# gemini-flash fallback instead. The dispatcher's own budget is 180s, so 150
# still leaves room for the ladder to try one more model.
$OpenCodeHeavyModels = @($OpenCodeNemotronModel, $OpenCodeLagunaModel, $OpenCodeNorthModel, $OpenCodeBigPickleModel)

function Get-OpenCodeIdleTimeout {
    param([string]$OpenCodeModel)
    if ($env:CODEX_OPENCODE_IDLE_TIMEOUT_SEC) { return [int]$env:CODEX_OPENCODE_IDLE_TIMEOUT_SEC }
    $configured = Get-ModelSetting $OpenCodeModel "idleTimeoutSec"
    if (-not [string]::IsNullOrWhiteSpace($configured)) { return [int]$configured }
    if ($OpenCodeHeavyModels -contains $OpenCodeModel) { return 150 }
    return 90
}

function Clean-OpenCodeOutput {
    param([string]$Text)
    return (($Text -split "\r?\n" | Where-Object {
        $_ -notmatch "Cannot read [^\s]+\.(?:png|jpg|jpeg|webp|gif|bmp) \(this model does not support image input\)"
    }) -join [Environment]::NewLine).Trim()
}

function Get-ExtraOpenCodeModels {
    param([string]$Pool)
    if (-not (Test-Path -LiteralPath $OpenCodeExtraModelsFile)) { return @() }
    try {
        $cfg = Get-Content -LiteralPath $OpenCodeExtraModelsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return @()
    }
    if ($cfg.PSObject.Properties["enabled"] -and -not [bool]$cfg.enabled) { return @() }
    if (-not $cfg.PSObject.Properties[$Pool]) { return @() }

    $models = @()
    foreach ($entry in @($cfg.$Pool)) {
        if ($entry -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($entry)) { $models += $entry }
            continue
        }
        $enabled = if ($entry.PSObject.Properties["enabled"]) { [bool]$entry.enabled } else { $true }
        if ($enabled -and $entry.PSObject.Properties["model"] -and -not [string]::IsNullOrWhiteSpace([string]$entry.model)) {
            $models += [string]$entry.model
        }
    }
    return @($models | Select-Object -Unique)
}

# NOTE: the lists above are only the no-catalog fallback. Pool finalization
# (Zen catalog tiers, extras merge, mandatory GUI intersection) happens in the
# "Dynamic Zen catalog" section further down, after the helpers it needs.
$OpenCodeIdleTimeoutSec = if ($env:CODEX_OPENCODE_IDLE_TIMEOUT_SEC) { [int]$env:CODEX_OPENCODE_IDLE_TIMEOUT_SEC } else { 90 }
$script:OpenCodeInstalledModels = $null
$script:DelegatorCustomProviders = $null
$script:DelegatorProviderVerdicts = $null

function Get-OpenCodeCommandPath {
    if (-not $script:DelegatorIsWindows) {
        $command = Get-Command opencode -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return [string]$command.Source }
        return ""
    }
    $exe = Get-Command "opencode.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe -and -not [string]::IsNullOrWhiteSpace([string]$exe.Source)) {
        return [string]$exe.Source
    }
    $shim = Get-Command "opencode.cmd" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($shim -and -not [string]::IsNullOrWhiteSpace([string]$shim.Source)) {
        $nativeExe = Join-Path (Split-Path ([string]$shim.Source) -Parent) "node_modules\opencode-ai\bin\opencode.exe"
        if (Test-Path -LiteralPath $nativeExe) { return $nativeExe }
        return [string]$shim.Source
    }
    return ""
}

function Read-OpenCodeGuiModelState {
    if (-not (Test-Path -LiteralPath $OpenCodeGuiModelStateFile)) { return $null }
    try { return Get-Content -LiteralPath $OpenCodeGuiModelStateFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-InstalledOpenCodeModels {
    if ($null -ne $script:OpenCodeInstalledModels) { return $script:OpenCodeInstalledModels }
    try {
        $command = Get-OpenCodeCommandPath
        if ([string]::IsNullOrWhiteSpace($command)) {
            $script:OpenCodeInstalledModels = @()
            return $script:OpenCodeInstalledModels
        }
        $lines = @(Invoke-WithOpenCodeProxyEnv { & $command models 2>$null } | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $script:OpenCodeInstalledModels = $lines
    } catch {
        $script:OpenCodeInstalledModels = @()
    }
    return $script:OpenCodeInstalledModels
}

function Test-ModelAvailableInOpenCode {
    param([string]$OpenCodeModel)
    if ([string]::IsNullOrWhiteSpace($OpenCodeModel)) { return $false }
    return @(Get-InstalledOpenCodeModels) -contains $OpenCodeModel
}

function Unprotect-DelegatorOpenRouterKey {
    param([string]$Encrypted)
    if ([string]::IsNullOrWhiteSpace($Encrypted)) { return "" }
    if (-not $script:DelegatorIsWindows) { return Get-DelegatorKeychainSecret $Encrypted }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            [Convert]::FromBase64String($Encrypted),
            $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return [Text.Encoding]::UTF8.GetString($plain)
    } catch {}
    return ""
}

function Get-DelegatorOpenRouterAccounts {
    if (-not (Test-Path -LiteralPath $DelegatorAppConfigFile)) { return @() }
    try {
        $config = Get-Content -LiteralPath $DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $rows = @()
        foreach ($account in @($config.opencode_accounts)) {
            if (-not $account -or ($null -ne $account.enabled -and -not [bool]$account.enabled)) { continue }
            $key = Unprotect-DelegatorOpenRouterKey ([string]$account.api_key_enc)
            if ([string]::IsNullOrWhiteSpace($key)) { continue }
            $rows += [pscustomobject]@{
                id = [string]$account.id
                label = [string]$account.label
                key = $key
            }
        }
        if ($rows.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$config.opencode_api_key_enc)) {
            $legacyKey = Unprotect-DelegatorOpenRouterKey ([string]$config.opencode_api_key_enc)
            if (-not [string]::IsNullOrWhiteSpace($legacyKey)) {
                $rows += [pscustomobject]@{ id = "legacy"; label = "OpenCode account 1"; key = $legacyKey }
            }
        }
        return @($rows)
    } catch {}
    return @()
}

function Get-DelegatorCustomProviders {
    # config.json `custom_providers` (config v13): user-added OpenAI-compatible
    # backends. Cached per process - every candidate in a ladder would otherwise
    # re-read and re-DPAPI-decrypt the same file.
    #
    # A provider with no usable key is dropped here rather than later: an id in
    # the pool that can only ever answer 401 costs a whole rung of the ladder.
    if ($null -ne $script:DelegatorCustomProviders) { return $script:DelegatorCustomProviders }
    $script:DelegatorCustomProviders = @()
    if (-not (Test-Path -LiteralPath $DelegatorAppConfigFile)) { return $script:DelegatorCustomProviders }
    try {
        $config = Get-Content -LiteralPath $DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $providers = @()
        foreach ($entry in @($config.custom_providers)) {
            if (-not $entry) { continue }
            if ($null -ne $entry.enabled -and -not [bool]$entry.enabled) { continue }
            $id = ([string]$entry.id).Trim().ToLowerInvariant()
            $baseUrl = ([string]$entry.base_url).Trim().TrimEnd([char]47)
            if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($baseUrl)) { continue }
            $accounts = @()
            foreach ($account in @($entry.accounts)) {
                if (-not $account) { continue }
                if ($null -ne $account.enabled -and -not [bool]$account.enabled) { continue }
                $key = Unprotect-DelegatorOpenRouterKey ([string]$account.api_key_enc)
                if ([string]::IsNullOrWhiteSpace($key)) { continue }
                $accounts += [pscustomobject]@{
                    id = [string]$account.id
                    label = [string]$account.label
                    key = $key
                }
            }
            if ($accounts.Count -eq 0) { continue }
            $models = @($entry.enabled_models | ForEach-Object { ([string]$_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            $providers += [pscustomobject]@{
                id = $id
                label = [string]$entry.label
                baseUrl = $baseUrl
                accounts = @($accounts)
                models = @($models)
            }
        }
        $script:DelegatorCustomProviders = @($providers)
    } catch {}
    return $script:DelegatorCustomProviders
}

function Get-ProviderVerdicts {
    # <RT>\provider-verdicts.json, written by the GUI's daily refresh
    # (DEV_CONTRACTS section 12a). Maps "<provider>/<model>" -> verdict string
    # for verdicts that have not expired.
    #
    # A missing, unreadable or empty file yields an EMPTY map, and an empty map
    # removes nothing. That asymmetry is the whole safety property: a verdict may
    # only ever take a model out of the pool, never put one in, and never on the
    # strength of a file that failed to load.
    if ($null -ne $script:DelegatorProviderVerdicts) { return $script:DelegatorProviderVerdicts }
    $map = @{}
    $script:DelegatorProviderVerdicts = $map
    $verdictFile = Join-Path $DelegateHome "provider-verdicts.json"
    if (-not (Test-Path -LiteralPath $verdictFile)) { return $map }
    try {
        $raw = Get-Content -LiteralPath $verdictFile -Raw -Encoding UTF8
        if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
        $parsed = $raw | ConvertFrom-Json
        if (-not $parsed -or -not $parsed.PSObject.Properties["providers"]) { return $map }
        $nowUnix = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        foreach ($providerProperty in @($parsed.providers.PSObject.Properties)) {
            $providerId = [string]$providerProperty.Name
            foreach ($modelProperty in @($providerProperty.Value.PSObject.Properties)) {
                $entry = $modelProperty.Value
                if (-not $entry -or -not $entry.PSObject.Properties["verdict"]) { continue }
                if ($entry.PSObject.Properties["expires_at"] -and $null -ne $entry.expires_at) {
                    if ([int64]$entry.expires_at -le $nowUnix) { continue }
                }
                $map[($providerId + "/" + [string]$modelProperty.Name)] = [string]$entry.verdict
            }
        }
    } catch {}
    $script:DelegatorProviderVerdicts = $map
    return $map
}

function Test-ModelRefusedByProvider {
    # True only when the provider ITSELF said it will not serve this model on
    # this key. No verdict is not a refusal: a probe that timed out, a 401 or a
    # 429 never becomes one (see provider_verdicts.rs classify_probe), because
    # each of those is about the key, the quota or the wire.
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $false }
    $verdicts = Get-ProviderVerdicts
    if (-not $verdicts.ContainsKey($ModelId)) { return $false }
    return ([string]$verdicts[$ModelId] -ne "free")
}

function Get-CustomProviderModelIds {
    # Every enabled model of every usable provider, prefixed `<provider>/<model>`
    # - the same shape as `openrouter/*`, so the pool needs no per-provider case.
    $ids = @()
    foreach ($provider in (Get-DelegatorCustomProviders)) {
        foreach ($model in @($provider.models)) { $ids += ($provider.id + "/" + $model) }
    }
    return @($ids)
}

function Get-CustomProviderForModel {
    # Splits on the FIRST slash only: a model id may itself contain slashes
    # (tokenrouter/z-ai/glm-5.3-free), and the remainder is what the upstream is
    # asked for verbatim.
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $null }
    $separator = $ModelId.IndexOf([char]47)
    if ($separator -lt 1 -or $separator -ge ($ModelId.Length - 1)) { return $null }
    $prefix = $ModelId.Substring(0, $separator).ToLowerInvariant()
    foreach ($provider in (Get-DelegatorCustomProviders)) {
        if ($provider.id -eq $prefix) { return $provider }
    }
    return $null
}

function Invoke-OpenAICompatModel {
    <#
      One POST to <baseUrl>/chat/completions on any OpenAI-compatible backend.
      Generalised from Invoke-OpenRouterDirectModel, which is now a caller: the
      proxy precedence, the UTF-8 body (section 4), the SOCKS-via-curl detour
      (section 7a), the account rotation and the single 429 retry are the same
      rules for every provider, and a second copy of them would drift.
    #>
    param(
        [string]$Text,
        [string]$BaseUrl,
        [string]$ModelId,
        $Accounts,
        [hashtable]$ExtraHeaders,
        [int]$Seconds,
        [string]$ProxyProvider = "opencode"
    )

    $accountList = @($Accounts)
    if ($accountList.Count -eq 0) {
        return [pscustomobject]@{ exitCode = 2; output = "No enabled API keys for this provider in Delegator. Add one on the API tab." }
    }
    if ([string]::IsNullOrWhiteSpace($BaseUrl) -or [string]::IsNullOrWhiteSpace($ModelId)) {
        return [pscustomobject]@{ exitCode = 2; output = "Provider is missing a base URL or a model id." }
    }

    $body = @{
        model = $ModelId
        messages = @(@{ role = "user"; content = $Text })
    }
    # DEV_CONTRACTS section 4: PS 5.1 encodes string bodies as ISO-8859-1 and turns
    # non-ASCII (Cyrillic) into '?', so the JSON body must be sent as UTF-8 bytes.
    $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 12))
    $uri = $BaseUrl.TrimEnd([char]47) + "/chat/completions"
    # DEV_CONTRACTS section 7a: the Delegator proxy (env/proxy.json) takes
    # precedence over the legacy system proxy detection.
    $delegateProxy = Get-DelegateProxy -Provider $ProxyProvider
    $useSocksProxy = (-not [string]::IsNullOrWhiteSpace($delegateProxy) -and $delegateProxy -match '^(?i)socks5h?://')
    $proxyUrl = ""
    if ([string]::IsNullOrWhiteSpace($delegateProxy)) { $proxyUrl = Get-SystemProxyForUrl $uri }
    $startIndex = [int]([DateTime]::UtcNow.Ticks % $accountList.Count)
    $orderedAccounts = @($accountList[$startIndex..($accountList.Count - 1)])
    if ($startIndex -gt 0) { $orderedAccounts += @($accountList[0..($startIndex - 1)]) }
    $lastError = "The request exhausted all enabled accounts."
    foreach ($account in $orderedAccounts) {
        $headers = @{
            Authorization = "Bearer $($account.key)"
            "Content-Type" = "application/json; charset=utf-8"
            # Groq (Cloudflare) answers 403 «error code: 1010» to a library User-Agent.
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Delegator"
        }
        if ($ExtraHeaders) {
            foreach ($name in $ExtraHeaders.Keys) { $headers[$name] = [string]$ExtraHeaders[$name] }
        }
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            try {
                if ($useSocksProxy) {
                    $curl = Invoke-CurlJsonRequest -Method "POST" -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $delegateProxy
                    if (-not $curl.ok) { throw (([string]$curl.error + " " + [string]$curl.rawBody).Trim()) }
                    $response = $curl.body
                } elseif (-not [string]::IsNullOrWhiteSpace($delegateProxy)) {
                    $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $delegateProxy
                } elseif (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
                    $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $proxyUrl -ProxyUseDefaultCredentials
                } else {
                    $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds
                }
                $parsed = Parse-OpenRouterDirectOutput $response
                if ([string]::IsNullOrWhiteSpace($parsed.answer)) {
                    $lastError = "The provider response contained no answer text."
                    break
                }
                return [pscustomobject]@{
                    exitCode = 0
                    output = ($response | ConvertTo-Json -Depth 20 -Compress)
                    parsed = $parsed
                    accountId = $account.id
                }
            } catch {
                $extra = ""
                try { if ($_.ErrorDetails.Message) { $extra = " " + [string]$_.ErrorDetails.Message } } catch {}
                $lastError = ($_.Exception.Message + $extra).Trim()
                # DEV_CONTRACTS section 7a: name the proxy when the transport failed before
                # an HTTP status arrived so the failure classifies as network, not auth.
                if (-not [string]::IsNullOrWhiteSpace($delegateProxy) -and $lastError -notmatch 'via proxy' -and $lastError -match '(?i)unable to connect|timed?\s*out|timeout|could not resolve') {
                    $lastError = $lastError + " (via proxy $delegateProxy)"
                }
                if ($lastError -match '\(429\)|Too Many Requests' -and $attempt -lt 2) {
                    Start-Sleep -Seconds (2 * $attempt)
                    continue
                }
                break
            }
        }
    }
    return [pscustomobject]@{ exitCode = 1; output = $lastError }
}

function Invoke-CustomProviderModel {
    param([string]$Text, [string]$OpenCodeModel, [int]$Seconds)
    $provider = Get-CustomProviderForModel $OpenCodeModel
    if ($null -eq $provider) {
        return [pscustomobject]@{ exitCode = 2; output = "Model '$OpenCodeModel' does not belong to a configured provider." }
    }
    $modelId = $OpenCodeModel.Substring($provider.id.Length + 1)
    # Own egress, not the OpenCode proxy: a custom provider has its own key and
    # was verified direct (ROADMAP S14). A dead Opera proxy on 127.0.0.1:1371 made
    # every B.AI request fail, the listing included.
    return (Invoke-OpenAICompatModel -Text $Text -BaseUrl $provider.baseUrl -ModelId $modelId -Accounts $provider.accounts -Seconds $Seconds -ProxyProvider "custom")
}

function Get-OpenRouterModelId {
    param([string]$OpenCodeModel)
    if ([string]::IsNullOrWhiteSpace($OpenCodeModel)) { return "" }
    if ($OpenCodeModel.StartsWith("openrouter/", [StringComparison]::OrdinalIgnoreCase)) {
        return $OpenCodeModel.Substring("openrouter/".Length)
    }
    return ""
}

function Get-ZenModelId {
    param([string]$OpenCodeModel)
    if ([string]::IsNullOrWhiteSpace($OpenCodeModel)) { return "" }
    # Zen direct ids are always the opencode/ alias without the prefix, so NEW
    # free models route without code changes; non-Zen ids return "" (not mapped).
    if ($OpenCodeModel -match '^opencode/([0-9A-Za-z._-]+)$') { return $Matches[1] }
    return ""
}

function Invoke-Utf8JsonPost {
    # Invoke-WebRequest + explicit UTF-8 decode: PS 5.1 Invoke-RestMethod decodes JSON
    # bodies as Latin-1 when the response lacks a charset, corrupting Cyrillic answers.
    param(
        [string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [int]$TimeoutSec,
        [string]$ProxyUrl,
        [switch]$ProxyUseDefaultCredentials
    )
    $params = @{ UseBasicParsing = $true; Method = "Post"; Uri = $Uri; Headers = $Headers; Body = $BodyBytes; TimeoutSec = $TimeoutSec }
    if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
        $params["Proxy"] = $ProxyUrl
        if ($ProxyUseDefaultCredentials) { $params["ProxyUseDefaultCredentials"] = $true }
    }
    $webResponse = Invoke-WebRequest @params
    return ([System.Text.Encoding]::UTF8.GetString($webResponse.RawContentStream.ToArray()) | ConvertFrom-Json)
}

function Get-SystemProxyForUrl {
    param([string]$Url)
    try {
        if ([string]::IsNullOrWhiteSpace($Url)) { return "" }
        $uri = [Uri]$Url
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        if ($null -eq $proxy) { return "" }
        $proxyUri = $proxy.GetProxy($uri)
        if ($null -eq $proxyUri) { return "" }
        if ($proxyUri.AbsoluteUri -eq $uri.AbsoluteUri) { return "" }
        return $proxyUri.AbsoluteUri
    } catch {
        return ""
    }
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
    # Custom (API-key) providers never take a GUI proxy row: see Invoke-CustomProviderModel.
    if ($Provider -eq "custom") { return $null }
    # GUI-managed proxies (config.json "proxies", DEV_CONTRACTS 7a) are authoritative
    # when the key exists; the legacy <RT>\proxy.json below is only a pre-v8 fallback.
    try {
        $guiConfigPath = $script:DelegatorConfigFile
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
    # The error text keeps "(NNN)" status markers so Get-OpenCodeErrorClass and the
    # retry/cooldown logic keep working unchanged.
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [byte[]]$BodyBytes,
        [int]$TimeoutSec,
        [string]$ProxyUrl
    )
    $curlExe = Get-DelegatorCurl
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
            try { $rawBody = [System.IO.File]::ReadAllText($respFile, [System.Text.UTF8Encoding]::new($false)) } catch {}
        }
        $curlError = ""
        if (Test-Path -LiteralPath $errFile) {
            try { $curlError = ([System.IO.File]::ReadAllText($errFile, [System.Text.UTF8Encoding]::new($false))).Trim() } catch {}
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

function Invoke-WithOpenCodeProxyEnv {
    # DEV_CONTRACTS section 7a: direct `& opencode ...` invocations inherit the
    # process environment, so set HTTP(S)_PROXY only around the child launch and
    # always restore afterwards - the proxy must not leak into the PS session.
    param([scriptblock]$Body)
    $proxy = Get-DelegateProxy -Provider 'opencode'
    if ([string]::IsNullOrWhiteSpace($proxy)) { return (& $Body) }
    $savedHttp = $env:HTTP_PROXY
    $savedHttps = $env:HTTPS_PROXY
    $savedNoProxy = $env:NO_PROXY
    try {
        $env:HTTP_PROXY = $proxy
        $env:HTTPS_PROXY = $proxy
        $env:NO_PROXY = "127.0.0.1,localhost"
        return (& $Body)
    } finally {
        $env:HTTP_PROXY = $savedHttp
        $env:HTTPS_PROXY = $savedHttps
        $env:NO_PROXY = $savedNoProxy
    }
}

function Read-ModelSettings {
    if (-not (Test-Path -LiteralPath $ModelSettingsFile)) { return $null }
    try { return Get-Content -LiteralPath $ModelSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-ModelSetting {
    param([string]$OpenCodeModel, [string]$Key)
    $settings = Read-ModelSettings
    if (-not $settings -or -not $settings.models) { return "" }
    if (-not $settings.models.PSObject.Properties[$OpenCodeModel]) { return "" }
    $row = $settings.models.PSObject.Properties[$OpenCodeModel].Value
    if (-not $row -or -not $row.PSObject.Properties[$Key]) { return "" }
    return [string]$row.PSObject.Properties[$Key].Value
}

function Test-ModelDisabled {
    param([string]$OpenCodeModel)
    $value = Get-ModelSetting $OpenCodeModel "disabled"
    if ([string]::IsNullOrWhiteSpace($value)) { return $false }
    try { return [bool]::Parse($value) } catch {}
    return ($value -match '^(?i:true|1|yes)$')
}

function Get-PreferredExecutionPath {
    param([string]$OpenCodeModel)
    $value = Get-ModelSetting $OpenCodeModel "executionPath"
    if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
    return ""
}

function Get-ExtraOpenCodeVariant {
    param([string]$OpenCodeModel)
    if (-not (Test-Path -LiteralPath $OpenCodeExtraModelsFile)) { return "" }
    try {
        $cfg = Get-Content -LiteralPath $OpenCodeExtraModelsFile -Raw | ConvertFrom-Json
    } catch {
        return ""
    }
    foreach ($pool in @("fast", "normal", "deep")) {
        if (-not $cfg.PSObject.Properties[$pool]) { continue }
        foreach ($entry in @($cfg.$pool)) {
            if ($entry -is [string]) { continue }
            if ([string]$entry.model -eq $OpenCodeModel -and $entry.PSObject.Properties["variant"]) {
                return [string]$entry.variant
            }
        }
    }
    return ""
}

function Get-ExtraOpenCodeAgent {
    param([string]$OpenCodeModel)
    if (-not (Test-Path -LiteralPath $OpenCodeExtraModelsFile)) { return "" }
    try {
        $cfg = Get-Content -LiteralPath $OpenCodeExtraModelsFile -Raw | ConvertFrom-Json
    } catch {
        return ""
    }
    foreach ($pool in @("fast", "normal", "deep")) {
        if (-not $cfg.PSObject.Properties[$pool]) { continue }
        foreach ($entry in @($cfg.$pool)) {
            if ($entry -is [string]) { continue }
            if ([string]$entry.model -eq $OpenCodeModel -and $entry.PSObject.Properties["agent"]) {
                return [string]$entry.agent
            }
        }
    }
    return ""
}

function Get-OpenCodeMaxVariant {
    param([string]$OpenCodeModel)
    if ($env:CODEX_OPENCODE_VARIANT) { return $env:CODEX_OPENCODE_VARIANT }
    $configuredVariant = Get-ModelSetting $OpenCodeModel "variant"
    if (-not [string]::IsNullOrWhiteSpace($configuredVariant)) { return $configuredVariant }
    $extraVariant = Get-ExtraOpenCodeVariant $OpenCodeModel
    if (-not [string]::IsNullOrWhiteSpace($extraVariant)) { return $extraVariant }
    $guiState = Read-OpenCodeGuiModelState
    if ($guiState -and $guiState.variant -and $guiState.variant.PSObject.Properties[$OpenCodeModel]) {
        $guiVariant = [string]$guiState.variant.PSObject.Properties[$OpenCodeModel].Value
        if (-not [string]::IsNullOrWhiteSpace($guiVariant) -and $guiVariant -ne "default") { return $guiVariant }
    }
    if ($OpenCodeModel -match "gpt-5-nano") { return "high" }
    if ($OpenCodeModel -match "hy3-preview") { return "high" }
    if ($OpenCodeModel -match "nemotron") { return "high" }
    if ($OpenCodeModel -match "gemma-4-31b") { return "high" }
    if ($OpenCodeModel -match "big-pickle") { return "high" }
    if ($OpenCodeModel -match "deepseek-v4-flash") { return "high" }
    if ($OpenCodeModel -match "ling-3\.0-flash") { return "high" }
    return ""
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Ensure-DelegateDirs {
    New-Item -ItemType Directory -Force -Path $DelegateHome, $OpenCodeConfigDir, $OpenCodeWorkDir | Out-Null
    $agentInstructions = @"
You are the Delegator text execution engine.
Execute the TASK from the user message immediately and return only its requested result.
Never delegate again, describe policies, announce readiness, or ask the caller to restate the task.
Do not use tools or inspect local files unless the TASK explicitly requires it.
"@
    Write-Utf8NoBom -Path (Join-Path $OpenCodeConfigDir "AGENTS.md") -Text $agentInstructions
}

# ── Dynamic Zen catalog (strength-aware routing) ──────────────────────────────
# <RT>\opencode-zen-catalog.json mirrors the CURRENT `opencode models` free set:
# {"version":1,"updatedAt":"<utc iso>","models":[{"id":"opencode/...","strength":<int>}]}.
# update-free-models.ps1 writes it; this script refreshes it inline when it is
# missing or older than 24h (helpers duplicated per the no-dot-source convention).
# The GUI config remains the mandatory allowlist - the catalog can only narrow
# routing to aliases that still exist upstream, never enable anything new.

$ZenCatalogMaxAgeHours = 24

function Get-ZenModelStrength {
    # DPR of a Zen alias, for the inline catalog refresh below.
    #
    # This used to be a SECOND copy of the alias-name heuristic, and leaving it
    # here after the table landed was a real defect, not a tidiness issue: the
    # inline refresh rewrites the catalog, so every regeneration silently put the
    # old numbers back. Measured right after the 0.7 install — the cache was
    # correctly invalidated, immediately rebuilt, and `nemotron-3-ultra` came
    # back as 93 (deep tier) instead of the 99 the table gives it.
    #
    # Unrated aliases (stealth names like big-pickle, x-preview-f) get the
    # neutral normal-tier score so they stay reachable without being trusted.
    param([string]$ModelId)
    $rating = Get-DelegatorModelRating $ModelId
    if ($null -ne $rating) { return [int]$rating }
    return [int]$script:DelegateUnratedDpr
}

function Read-ZenCatalog {
    # Returns a map: zen model id -> strength. Empty map when the catalog is
    # missing/corrupt - callers then fall back to the ratings table directly.
    #
    # A catalog whose `ratingsVersion` does not match the shipped table is
    # REJECTED, not used. The catalog is a cache of model-ratings.json, and it is
    # only rewritten when it ages past 24 h - so without this check an upgrade
    # that changes the ratings would keep routing on yesterday's numbers for a
    # whole day. Measured on the 0.7 upgrade: the catalog still scored
    # `nemotron-3-ultra` 93 (top of the deep tier) hours after the table that
    # scores it 99/fast had shipped.
    $map = @{}
    if (-not (Test-Path -LiteralPath $ZenCatalogFile)) { return $map }
    try {
        $catalog = Get-Content -LiteralPath $ZenCatalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$catalog.ratingsVersion -ne (Get-DelegatorRatingsVersion)) { return @{} }
        foreach ($row in @($catalog.models)) {
            $id = ([string]$row.id).Trim()
            if ($id -match '^opencode/[0-9A-Za-z._-]+$') { $map[$id] = [int]$row.strength }
        }
    } catch {}
    return $map
}

# ── Model ratings (DPR) ───────────────────────────────────────────────────────
# DPR = Delegator Programming Rating from the SHIPPED model-ratings.json next to
# this script. 0 means "cannot program at all" (whisper, orpheus, prompt-guard,
# embeddings) and the scale has NO upper bound; the 2026-08 snapshot tops at 156.
# A row matches by the LONGEST substring of the lowercased id, so one row serves
# every provider prefix and glm-5.2 beats glm-5. Unknown id -> $null, never 0.
#
# ONE OF FOUR COPIES - delegator-common.ps1, opencode-delegate.ps1 (here),
# update-free-models.ps1 and src\gui\opencode_setup.rs. Change them together.
$script:DelegateModelRatingsFile = Join-Path $PSScriptRoot "model-ratings.json"
$script:DelegateDprDeep = 130
$script:DelegateDprNormal = 100
$script:DelegateUnratedDpr = 100
$script:DelegateRatingRows = $null
$script:DelegateRatingsVersion = $null

# `version` of the shipped table. The Zen catalog stamps it, so a table that
# changed invalidates every cached score instead of waiting out the 24 h TTL.
# BUMP IT whenever a dpr value changes, or the cache will not notice.
function Get-DelegatorRatingsVersion {
    if ($null -ne $script:DelegateRatingsVersion) { return $script:DelegateRatingsVersion }
    $null = Get-DelegatorRatingRows
    return $script:DelegateRatingsVersion
}

function Get-DelegatorRatingRows {
    if ($null -ne $script:DelegateRatingRows) { return $script:DelegateRatingRows }
    $rows = @()
    $script:DelegateRatingsVersion = 0
    try {
        if (Test-Path -LiteralPath $script:DelegateModelRatingsFile) {
            $raw = Get-Content -LiteralPath $script:DelegateModelRatingsFile -Raw -Encoding UTF8
            if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
            $parsed = $raw | ConvertFrom-Json
            $script:DelegateRatingsVersion = [int]$parsed.version
            foreach ($entry in @($parsed.models)) {
                if (-not $entry -or [string]::IsNullOrWhiteSpace([string]$entry.match)) { continue }
                # An `unrated` row (dpr null) is KEPT, and that is the point: it is a
                # statement that THIS id is unknown, so it must shadow a shorter rated
                # substring of itself. Dropping it here let `glm-5.3-flash` inherit the
                # 150 of `glm-5.3`, and a 100-DPR model was handed deep work.
                $unrated = ($null -eq $entry.dpr)
                $rows += [pscustomobject]@{
                    match   = ([string]$entry.match).ToLowerInvariant()
                    dpr     = $(if ($unrated) { $null } else { [int]$entry.dpr })
                    unrated = $unrated
                }
            }
        }
    } catch { $rows = @() }
    $script:DelegateRatingRows = @($rows | Sort-Object @{ Expression = { $_.match.Length }; Descending = $true })
    return $script:DelegateRatingRows
}

function Get-DelegatorModelRating {
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $null }
    $name = ([string]$ModelId).ToLowerInvariant().Replace("_", "-").Replace(" ", "-")
    foreach ($row in (Get-DelegatorRatingRows)) {
        if (-not $name.Contains($row.match)) { continue }
        # The FIRST hit is the most specific one (rows are sorted longest-first).
        # When it is an `unrated` row the answer is "no number", never the number
        # of some shorter row that happens to be a substring of it.
        if ($row.unrated) { return $null }
        return [int]$row.dpr
    }
    return $null
}

function Get-ModelStrength {
    # DPR for try-sequence ordering. The Zen catalog wins when it carries the id
    # (it is generated from the same table); everything else - and that is every
    # non-Zen provider, including the user's strongest models - resolves through
    # the ratings table. Unknown ids get DelegateUnratedDpr, not 0: an unmeasured
    # model must stay reachable, it just must not be trusted with hard work.
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return [int]$script:DelegateUnratedDpr }
    if ($script:ZenStrengthMap -and $script:ZenStrengthMap.ContainsKey($ModelId)) {
        return [int]$script:ZenStrengthMap[$ModelId]
    }
    $rating = Get-DelegatorModelRating $ModelId
    if ($null -ne $rating) { return [int]$rating }
    return [int]$script:DelegateUnratedDpr
}

function Update-ZenCatalogIfStale {
    # Inline refresh: only when the file is missing or older than 24h AND the
    # OpenCode CLI is available. Serialized across processes by a named mutex.
    # A refresh failure must never break a request: swallow everything and keep
    # routing on the stale/absent file.
    try {
        # A catalog built from a DIFFERENT ratings table is stale no matter how
        # young it is: Read-ZenCatalog already refuses it, and leaving it in
        # place would keep the router on the fallback for 24 h after an upgrade.
        if ((Test-Path -LiteralPath $ZenCatalogFile) -and (Read-ZenCatalog).Count -gt 0) {
            $ageHours = ([DateTime]::UtcNow - (Get-Item -LiteralPath $ZenCatalogFile).LastWriteTimeUtc).TotalHours
            if ($ageHours -lt $ZenCatalogMaxAgeHours) { return }
        }
        $command = Get-OpenCodeCommandPath
        if ([string]::IsNullOrWhiteSpace($command)) { return }
        $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorZenCatalog")
        $locked = $false
        try {
            $locked = $mutex.WaitOne(5000)
            if (-not $locked) { return }
            if ((Test-Path -LiteralPath $ZenCatalogFile) -and (Read-ZenCatalog).Count -gt 0) {
                # Another process may have refreshed while this one waited.
                $ageHours = ([DateTime]::UtcNow - (Get-Item -LiteralPath $ZenCatalogFile).LastWriteTimeUtc).TotalHours
                if ($ageHours -lt $ZenCatalogMaxAgeHours) { return }
            }
            $lines = @(Invoke-WithOpenCodeProxyEnv { & $command models 2>$null } | ForEach-Object { ([string]$_).Trim() })
            $zenIds = @($lines | Where-Object { $_ -match '^opencode/[0-9A-Za-z._-]+$' } | Select-Object -Unique)
            if ($zenIds.Count -eq 0) { return }
            $models = @($zenIds | ForEach-Object {
                [pscustomobject]@{ id = $_; strength = (Get-ZenModelStrength $_) }
            } | Sort-Object @{ Expression = { -[int]$_.strength } }, @{ Expression = { [string]$_.id } })
            $catalog = [pscustomobject]@{
                version = 1
                ratingsVersion = (Get-DelegatorRatingsVersion)
                updatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
                models = $models
            }
            Ensure-DelegateDirs
            Write-Utf8NoBom -Path $ZenCatalogFile -Text ($catalog | ConvertTo-Json -Depth 5)
        } finally {
            if ($locked) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    } catch {}
}

function Sort-ModelsByPreference {
    # Try-sequence order: (a) models NOT cooling down first (cooling ones sort
    # last instead of being dropped, so the only remaining candidate still works),
    # (b) strength DESC from the catalog (absent -> 50) - ASC with -WeakestFirst
    # for deliberately cheap picks, (c) equal strength -> least-used-today first,
    # (d) stable by id.
    param([string[]]$Pool, [switch]$WeakestFirst)
    $candidates = @(@($Pool) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and -not (Test-ModelDisabled $_) } |
        Select-Object -Unique)
    if ($candidates.Count -le 1) { return $candidates }
    $counts = Get-ModelUseCountsToday
    return @($candidates | Sort-Object `
        @{ Expression = { if (Test-ModelCoolingDown $_) { 1 } else { 0 } } }, `
        @{ Expression = { $s = Get-ModelStrength ([string]$_); if ($WeakestFirst) { $s } else { -$s } } }, `
        @{ Expression = { if ($counts.ContainsKey($_)) { [int]$counts[$_] } else { 0 } } }, `
        @{ Expression = { [string]$_ } })
}

# ── Pool finalization ─────────────────────────────────────────────────────────
# Refresh + read the catalog. The refresh is skipped when dot-sourced (unit
# tests must never spawn the CLI); it is best-effort for real invocations only.
if ($MyInvocation.InvocationName -ne ".") { Update-ZenCatalogIfStale }
$script:ZenStrengthMap = Read-ZenCatalog

if ($script:ZenStrengthMap.Count -gt 0) {
    # Pool membership derives from DPR tiers of the LIVE catalog instead of the
    # hardcoded id lists above (kept only as the no-catalog fallback):
    # deep = strong tier (>=DelegateDprDeep), normal = strong+mid
    # (>=DelegateDprNormal), fast = weak tier (below it, the cheap aliases).
    # An empty tier widens to the next one / the whole set.
    $zenCatalogIds = @($script:ZenStrengthMap.Keys | Sort-Object)
    $zenStrong = @($zenCatalogIds | Where-Object { [int]$script:ZenStrengthMap[$_] -ge $script:DelegateDprDeep })
    $zenMid = @($zenCatalogIds | Where-Object { [int]$script:ZenStrengthMap[$_] -ge $script:DelegateDprNormal -and [int]$script:ZenStrengthMap[$_] -lt $script:DelegateDprDeep })
    $zenWeak = @($zenCatalogIds | Where-Object { [int]$script:ZenStrengthMap[$_] -lt $script:DelegateDprNormal })
    $OpenCodeDeepModels = if ($zenStrong.Count -gt 0) { @($zenStrong) } else { @($zenCatalogIds) }
    $OpenCodeNormalModels = if (($zenStrong.Count + $zenMid.Count) -gt 0) { @($zenStrong + $zenMid) } else { @($zenCatalogIds) }
    $OpenCodeFastModels = if ($zenWeak.Count -gt 0) { @($zenWeak) } elseif ($zenMid.Count -gt 0) { @($zenMid) } else { @($zenCatalogIds) }
}

$OpenCodeFastModels = @($OpenCodeFastModels + (Get-ExtraOpenCodeModels "fast")) | Select-Object -Unique
$OpenCodeNormalModels = @($OpenCodeNormalModels + (Get-ExtraOpenCodeModels "normal")) | Select-Object -Unique
$OpenCodeDeepModels = @($OpenCodeDeepModels + (Get-ExtraOpenCodeModels "deep")) | Select-Object -Unique
$OpenCodeAllModels = @($OpenCodeFastModels + $OpenCodeNormalModels + $OpenCodeDeepModels) | Select-Object -Unique

# The GUI selection is authoritative: it is re-synced from `opencode models` on
# every GUI start, so it already reflects the live Zen lineup. The catalog file
# is only a strength/tier source and may be up to 24h stale - never use it to
# drop an enabled model, or a brand-new free model would sit unused until the
# next catalog refresh. Legacy ranking/extra files may tune selected models but
# cannot silently re-enable a model removed from the Delegator pool.
try {
    $appConfig = Get-Content -LiteralPath $DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $selectedModels = @($appConfig.enabled_opencode_models | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
} catch {
    $selectedModels = @()
}
if ($selectedModels.Count -gt 0) {
    $eligibleModels = @($selectedModels)
    $OpenCodeFastModels = @($OpenCodeFastModels | Where-Object { $eligibleModels -contains $_ })
    $OpenCodeNormalModels = @($OpenCodeNormalModels | Where-Object { $eligibleModels -contains $_ })
    $OpenCodeDeepModels = @($OpenCodeDeepModels | Where-Object { $eligibleModels -contains $_ })
    if ($OpenCodeFastModels.Count -eq 0) { $OpenCodeFastModels = @($eligibleModels[0]) }
    if ($OpenCodeNormalModels.Count -eq 0) { $OpenCodeNormalModels = @($eligibleModels) }
    if ($OpenCodeDeepModels.Count -eq 0) { $OpenCodeDeepModels = @($eligibleModels) }
    $OpenCodeAllModels = @($eligibleModels)
}

# Custom providers (config v13) join the pools by DPR, exactly the way the Zen
# catalog tiers do. Deliberately AFTER the GUI intersection above: that
# allowlist is `enabled_opencode_models`, which is the Zen/OpenRouter list and
# has never heard of these ids, so intersecting would drop every one of them.
# Their own allowlist is `custom_providers[].enabled_models`, already applied by
# Get-DelegatorCustomProviders, and I8 still holds - nothing here can enable a
# model the GUI did not.
$customProviderIds = @(Get-CustomProviderModelIds | Where-Object { -not (Test-ModelRefusedByProvider $_) })
if ($customProviderIds.Count -gt 0) {
    foreach ($customId in $customProviderIds) {
        $customStrength = Get-ModelStrength $customId
        if ($customStrength -ge $script:DelegateDprDeep) {
            $OpenCodeDeepModels = @($OpenCodeDeepModels + $customId)
        }
        if ($customStrength -ge $script:DelegateDprNormal) {
            $OpenCodeNormalModels = @($OpenCodeNormalModels + $customId)
        } else {
            $OpenCodeFastModels = @($OpenCodeFastModels + $customId)
        }
    }
    $OpenCodeFastModels = @($OpenCodeFastModels | Select-Object -Unique)
    $OpenCodeNormalModels = @($OpenCodeNormalModels | Select-Object -Unique)
    $OpenCodeDeepModels = @($OpenCodeDeepModels | Select-Object -Unique)
    $OpenCodeAllModels = @(@($OpenCodeAllModels + $customProviderIds) | Select-Object -Unique)
}

function Invoke-RunsLocked {
    param([scriptblock]$Body)
    $mutex = [System.Threading.Mutex]::new($false, "Global\CodexGeminiDelegateRuns")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for runs lock." }
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
    Ensure-DelegateDirs
    if (-not $Event.PSObject.Properties["timestamp"]) {
        $Event | Add-Member -NotePropertyName "timestamp" -NotePropertyValue (Get-Date).ToString("o")
    }
    try {
        Invoke-RunsLocked {
            $line = $Event | ConvertTo-Json -Depth 20 -Compress
            $encoding = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::AppendAllText($RunsFile, $line + [Environment]::NewLine, $encoding)
        }
    } catch {
        # Запись в лог необязательна — не роняем делегацию если мьютекс занят
    }
}

function Invoke-UsageLogLocked {
    param([scriptblock]$Body)
    $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorUsageLog")
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
        [object]$AccountId,
        # DEV_CONTRACTS section 5 class of a FAILED call. Omitted on success and
        # on older callers; Get-ModelHealth reads it to tell a model that cannot
        # answer from an account that is merely out of quota today.
        [string]$ErrorClass
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
        bench = (Test-DelegatorBenchmarkActive)
    }
    if (-not $Ok -and -not [string]::IsNullOrWhiteSpace($ErrorClass)) {
        Add-Member -InputObject $record -NotePropertyName "errorClass" -NotePropertyValue ([string]$ErrorClass) -Force
    }
    $line = ($record | ConvertTo-Json -Depth 6 -Compress) + [Environment]::NewLine
    try {
        Ensure-DelegateDirs
        Invoke-UsageLogLocked {
            [System.IO.File]::AppendAllText($UsageLogFile, $line, $Utf8NoBom)
        }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_FILE)) {
        try {
            Invoke-UsageLogLocked {
                [System.IO.File]::AppendAllText([string]$env:DELEGATOR_USAGE_FILE, $line, $Utf8NoBom)
            }
        } catch {}
    }
}

function Invoke-CooldownsLocked {
    param([scriptblock]$Body)
    $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorCooldowns")
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
        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        $until = [DateTime]::Parse([string]$entry.until, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
        return ($until -gt [DateTime]::UtcNow)
    } catch {
        return $false
    }
}

function Set-ModelCooldown {
    # DEV_CONTRACTS section 5: per-MODEL cooldowns in cooldowns.json.
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
        Ensure-DelegateDirs
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

function Invoke-AvailabilityLocked {
    param([scriptblock]$Body)
    $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorModelAvailability")
    $locked = $false
    try {
        $locked = $mutex.WaitOne(30000)
        if (-not $locked) { throw "Timed out waiting for the availability lock." }
        & $Body
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-ModelAvailability {
    # <RT>\model-availability.json: one record per model, kept across Delegator restarts,
    # so the ladder starts from what the last sessions measured instead of from zero.
    if (-not (Test-Path -LiteralPath $ModelAvailabilityFile)) {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    try {
        $state = Get-Content -LiteralPath $ModelAvailabilityFile -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    if (-not $state -or -not $state.PSObject.Properties["models"] -or -not $state.models) {
        return [pscustomobject]@{ version = 1; models = [pscustomobject]@{} }
    }
    return $state
}

function Update-ModelAvailability {
    # Records the outcome of ONE real call. A stalled call is not an outcome: the model
    # was working, so it neither earns a success nor takes a failure.
    param([string]$ModelId, [bool]$Ok, [string]$ErrorClass = "", [int]$ElapsedMs = 0)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return }
    if ((-not $Ok) -and $ErrorClass -eq "stalled") { return }
    try {
        Ensure-DelegateDirs
        Invoke-AvailabilityLocked {
            $state = Read-ModelAvailability
            $entry = [pscustomobject]@{ okCount = 0; failCount = 0; lastOk = ""; lastFail = ""; lastErrorClass = ""; lastMs = 0 }
            if ($state.models.PSObject.Properties[$ModelId]) { $entry = $state.models.PSObject.Properties[$ModelId].Value }
            $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            if ($Ok) {
                $entry.okCount = [int]$entry.okCount + 1
                $entry.lastOk = $now
                $entry.lastMs = $ElapsedMs
            } else {
                $entry.failCount = [int]$entry.failCount + 1
                $entry.lastFail = $now
                $entry.lastErrorClass = $ErrorClass
            }
            $state.models | Add-Member -Force -NotePropertyName $ModelId -NotePropertyValue $entry
            Write-Utf8NoBom -Path $ModelAvailabilityFile -Text ($state | ConvertTo-Json -Depth 8)
        }
    } catch {}
}

function Sort-ByAvailability {
    # Moves a model whose LAST outcome was a failure (within the last 6 h) behind the
    # others. Models with no record, or whose last outcome was a success, keep their
    # order. Nothing is removed: a demoted model is still the last resort.
    param([string[]]$Candidates)
    $list = @($Candidates)
    if ($list.Count -le 1) { return $list }
    $state = Read-ModelAvailability
    $horizon = (Get-Date).ToUniversalTime().AddHours(-6).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $keyed = @()
    for ($i = 0; $i -lt $list.Count; $i++) {
        $penalty = 0
        $id = [string]$list[$i]
        if ($state.models.PSObject.Properties[$id]) {
            $rec = $state.models.PSObject.Properties[$id].Value
            $lastFail = ConvertTo-DelegatorTimestamp $rec.lastFail
            $lastOk = ConvertTo-DelegatorTimestamp $rec.lastOk
            if ($lastFail -and $lastFail -gt $horizon -and $lastFail -gt $lastOk) { $penalty = 1 }
        }
        $keyed += [pscustomobject]@{ id = $id; penalty = $penalty; index = $i }
    }
    return @($keyed | Sort-Object penalty, index | ForEach-Object { $_.id })
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
    # A 5xx from the upstream lasted minutes in the live probe, not seconds: 60 s put the
    # same dead model back on the ladder at the next call.
    if ($ErrorClass -eq "server") { return 300 }
    if ($ErrorClass -eq "timeout") { return 60 }
    if ($ErrorClass -eq "network") { return 30 }
    return 0
}

function Test-AttemptIsModelFailure {
    <#
      Should this failed attempt be written to usage.jsonl against the model?

      Everything except a LOCAL environment problem. Exit code 2 means the CLI is
      missing or there are no keys: every candidate in the ladder fails the same
      way, so attributing it would demote the whole pool in one run, and health
      (unlike a cooldown) has no expiry to undo that.

      A rate limit IS written - the attempt happened and the attribution is a
      fact - but it carries its errorClass, and Get-ModelHealth refuses to read
      that class as a statement about the model (DEV_CONTRACTS section 9).
    #>
    param([int]$ExitCode, [string]$ErrorClass)
    if ($ExitCode -eq 2) { return $false }
    if ($ErrorClass -eq "stalled") { return $false }
    return $true
}

function Get-OpenCodeErrorClass {
    # DEV_CONTRACTS section 5 classifier for all three execution paths (CLI text output,
    # OpenRouter direct, Zen direct). Exit code 2 means a local environment problem
    # (CLI missing / no keys), which is not a model failure -> unknown, no cooldown.
    param([int]$ExitCode, [string]$Output)
    $text = [string]$Output
    if ($ExitCode -eq 124) { return "timeout" }
    if ($ExitCode -eq 2) { return "unknown" }
    if ($text -match '(?i)\(429\)|Too Many Requests|rate.?limit|quota|resource_exhausted') { return "rate_limit" }
    if ($text -match '(?i)\(401\)|\(403\)|unauthorized|forbidden|invalid[_ ]?(api[_ ]?)?key|authentication') { return "auth" }
    if ($text -match '(?i)\bENOTFOUND\b|\bEAI_AGAIN\b|getaddrinfo') { return "network" }
    if ($text -match '(?i)\(404\)|\bnot[ _-]?found\b|no such model|unknown model|not mapped') { return "not_found" }
    if ($text -match '(?i)content.?policy|safety|moderation|flagged|prohibited') { return "content_policy" }
    if ($text -match '(?i)context.?length|maximum context|too many tokens|token limit|exceeds.*context') { return "context_overflow" }
    if ($text -match '(?i)\(5\d\d\)|server error|internal error|bad gateway|service unavailable|overloaded') { return "server" }
    if ($text -match '(?i)timed?.?out|timeout') { return "timeout" }
    if ($text -match '(?i)unable to connect|could not resolve|connection|network|dns|socket') { return "network" }
    return "unknown"
}

function Get-TaskDomain {
    param([string]$Text)
    $t = $Text.ToLowerInvariant()
    if ($t -match "security|auth|tenant|leak|xss|csrf|sql injection|crypt|permission|vulnerability|root cause") { return "security" }
    if ($t -match "architecture|design|outbox|queue|event|audit|tradeoff|system design|migration") { return "architecture" }
    if ($t -match "consistency|transaction|idempot|saga|oversell|race|concurrency|retry|recovery") { return "data_consistency" }
    if ($t -match "edge case|edge-case|boundary|corner case|off-by-one|regression") { return "code_edge_cases" }
    if ($t -match "refactor|rewrite|cleanup|simplify|maintainability") { return "refactoring" }
    if ($t -match "debug|bug|stack trace|exception|test failed|failing test|fix|function|class|typescript|javascript|python|powershell|c#|\.js|\.ts|\.py|code") { return "code_debug" }
    if ($t -match "long context|large file|many files|context analysis|trace through|analyze logs|logs") { return "context_analysis" }
    if ($t -match "math|algorithm|calculate|proof|logic|probability|equation|number|sum|ratio|percent|constraint") { return "math_algo" }
    if ($t -match "reason|reasoning|deduce|infer|puzzle|logic") { return "reasoning" }
    if ($t -match "summarize|summary|extract|tl;dr|recap|compress|brief|notes") { return "summarization" }
    return "universal"
}

function Select-OpenCodeModel {
    # Strength-first routing: user-facing answers go to the strongest available
    # pool. `auto` never deliberately picks the weak tier - the cheap aliases
    # stay as the final fallback rungs in Get-ModelAttempts. An explicit
    # -Complexity fast is the deliberate cheap pick and uses the weak-tier pool.
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { return $Model }
    if ($Complexity -eq "fast") { return Select-LeastUsedModel $OpenCodeFastModels }
    if ($Complexity -eq "deep") { return Select-LeastUsedModel $OpenCodeDeepModels }
    if ($Complexity -eq "normal") { return Select-LeastUsedModel $OpenCodeNormalModels }
    if ($Text.Length -gt 4000 -or $Text -match "architecture|security|debug|root cause|refactor|database|migration") {
        return Select-LeastUsedModel $OpenCodeDeepModels
    }
    return Select-LeastUsedModel $OpenCodeNormalModels
}

function Get-ModelUseCountsToday {
    $counts = @{}
    foreach ($m in $OpenCodeAllModels) { $counts[$m] = 0 }
    if (-not (Test-Path -LiteralPath $RunsFile)) { return $counts }
    $today = (Get-Date).ToString("yyyy-MM-dd")
    foreach ($line in (Get-Content -LiteralPath $RunsFile -Tail 1500)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json } catch { continue }
        if ($event.delegate -ne "opencode" -or $event.event -ne "completed" -or $event.status -ne "ok") { continue }
        if (-not $event.timestamp -or -not ([string]$event.timestamp).StartsWith($today)) { continue }
        $m = [string]$event.model
        if ($counts.ContainsKey($m)) { $counts[$m] = [int]$counts[$m] + 1 }
    }
    return $counts
}

function Select-LeastUsedModel {
    # Successor of the pure least-used pick: cooldown -> strength DESC ->
    # least-used-today -> id. Cooling models sort last instead of being filtered
    # so the only remaining candidate still works (DEV_CONTRACTS section 5).
    param([string[]]$Pool)
    $ordered = @(Sort-ModelsByPreference -Pool $Pool)
    if ($ordered.Count -eq 0) { return $null }
    return [string]$ordered[0]
}

function Get-ModelAttempts {
    # Try-sequence: the selected model, the rest of its own tier pool, then the
    # remaining pools (tier retry first, then DOWN/across the strength ladder),
    # every segment ordered by Sort-ModelsByPreference. The trailing AllModels
    # segment keeps allowlisted models outside every tier pool (e.g. openrouter/*
    # ids without an extras entry) reachable as the last resort.
    param([string]$SelectedModel, [string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { return @($SelectedModel) }
    if ($OpenCodeFastModels -contains $SelectedModel) {
        $poolOrder = @(,@($OpenCodeFastModels)) + @(,@($OpenCodeNormalModels)) + @(,@($OpenCodeDeepModels))
    } elseif ($OpenCodeNormalModels -contains $SelectedModel) {
        $poolOrder = @(,@($OpenCodeNormalModels)) + @(,@($OpenCodeDeepModels)) + @(,@($OpenCodeFastModels))
    } else {
        $poolOrder = @(,@($OpenCodeDeepModels)) + @(,@($OpenCodeNormalModels)) + @(,@($OpenCodeFastModels))
    }
    $poolOrder += ,@($OpenCodeAllModels)
    $ordered = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SelectedModel)) { $ordered.Add([string]$SelectedModel) }
    foreach ($pool in $poolOrder) {
        foreach ($candidate in @(Sort-ModelsByPreference -Pool $pool)) {
            if (-not $ordered.Contains([string]$candidate)) { $ordered.Add([string]$candidate) }
        }
    }
    return @($ordered)
}

function Parse-OpenCodeOutput {
    param([string]$Text)
    $answerParts = @()
    $tokens = [long]0
    $promptTokens = [long]0
    $completionTokens = [long]0
    $cost = [double]0
    $sawUsage = $false
    foreach ($line in ($Text -split "\r?\n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $event = $line | ConvertFrom-Json
            if ($event.type -eq "text" -and $event.part.text) {
                $answerParts += [string]$event.part.text
            }
            if (($event.type -eq "step_finish" -or $event.type -eq "step-finish") -and $event.part.tokens) {
                # DEV_CONTRACTS section 2.4: SUM across ALL step_finish events
                # (last-write-wins under-reported multi-step runs) and keep the in/out split.
                $sawUsage = $true
                try { $tokens += [long]$event.part.tokens.total } catch {}
                try { if ($null -ne $event.part.tokens.input) { $promptTokens += [long]$event.part.tokens.input } } catch {}
                try { if ($null -ne $event.part.tokens.output) { $completionTokens += [long]$event.part.tokens.output } } catch {}
                try { if ($null -ne $event.part.cost) { $cost += [double]$event.part.cost } } catch {}
            }
        } catch {
        }
    }
    $finalPromptTokens = $null
    $finalCompletionTokens = $null
    if ($sawUsage) {
        $finalPromptTokens = $promptTokens
        $finalCompletionTokens = $completionTokens
    }
    return [pscustomobject]@{
        answer = ($answerParts -join "").Trim()
        tokens = $tokens
        promptTokens = $finalPromptTokens
        completionTokens = $finalCompletionTokens
        cost = $cost
    }
}

function Test-UnhelpfulDelegateAnswer {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
    $normalized = ($Text -replace '\s+', ' ').Trim()
    return (
        $normalized -match "(?i)^I'd be happy to help you!? However, I don't see a specific request" -or
        $normalized -match "(?i)^I don't see a specific request(?: to solve)?\b" -or
        $normalized -match "(?i)^Could you please (provide|share) what you'd like me to solve" -or
        $normalized -match "(?i)^Once you provide the details, I'll be happy to assist you\.?$"
    )
}

function Get-ExpectedExactReply {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $match = [regex]::Match($Text, '^\s*Reply exactly:\s*(.+?)\s*$', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { return "" }
    return [string]$match.Groups[1].Value
}

function Parse-OpenRouterDirectOutput {
    param($ResponseObject)
    $answer = ""
    $tokens = 0
    $promptTokens = $null
    $completionTokens = $null
    $cost = 0
    # Cline's gateway wraps the completion as {"data": {...}}; the standard shape has choices at the top.
    if (-not $ResponseObject.choices -and $ResponseObject.data -and $ResponseObject.data.choices) {
        $ResponseObject = $ResponseObject.data
    }
    try {
        if ($ResponseObject.choices -and @($ResponseObject.choices).Count -gt 0) {
            $answer = [string]$ResponseObject.choices[0].message.content
        }
    } catch {}
    try { $tokens = [int]$ResponseObject.usage.total_tokens } catch {}
    try { if ($null -ne $ResponseObject.usage.prompt_tokens) { $promptTokens = [long]$ResponseObject.usage.prompt_tokens } } catch {}
    try { if ($null -ne $ResponseObject.usage.completion_tokens) { $completionTokens = [long]$ResponseObject.usage.completion_tokens } } catch {}
    try { $cost = [double]$ResponseObject.usage.cost } catch {}
    return [pscustomobject]@{
        answer = $answer.Trim()
        tokens = $tokens
        promptTokens = $promptTokens
        completionTokens = $completionTokens
        cost = $cost
    }
}

function Parse-ZenDirectOutput {
    param($ResponseObject)
    $answer = ""
    $tokens = 0
    $promptTokens = $null
    $completionTokens = $null
    $cost = 0
    try {
        if ($ResponseObject.choices -and @($ResponseObject.choices).Count -gt 0) {
            $answer = [string]$ResponseObject.choices[0].message.content
        }
    } catch {}
    try { $tokens = [int]$ResponseObject.usage.total_tokens } catch {}
    try { if ($null -ne $ResponseObject.usage.prompt_tokens) { $promptTokens = [long]$ResponseObject.usage.prompt_tokens } } catch {}
    try { if ($null -ne $ResponseObject.usage.completion_tokens) { $completionTokens = [long]$ResponseObject.usage.completion_tokens } } catch {}
    try {
        if ($ResponseObject.PSObject.Properties["cost"]) {
            $cost = [double]$ResponseObject.cost
        } elseif ($ResponseObject.usage -and $ResponseObject.usage.PSObject.Properties["cost"]) {
            $cost = [double]$ResponseObject.usage.cost
        }
    } catch {}
    return [pscustomobject]@{
        answer = ($answer.Trim())
        tokens = $tokens
        promptTokens = $promptTokens
        completionTokens = $completionTokens
        cost = $cost
    }
}

function Invoke-ZenDirectModel {
    param([string]$Text, [string]$OpenCodeModel, [int]$Seconds)
    $modelId = Get-ZenModelId $OpenCodeModel
    if ([string]::IsNullOrWhiteSpace($modelId)) {
        return [pscustomobject]@{ exitCode = 1; output = "Model is not mapped to a Zen direct id." }
    }
    try {
        $headers = @{ "Content-Type" = "application/json; charset=utf-8" }
        $body = @{
            model = $modelId
            messages = @(@{ role = "user"; content = $Text })
        }
        # DEV_CONTRACTS section 4: PS 5.1 encodes string bodies as ISO-8859-1 and turns
        # non-ASCII (Cyrillic) into '?', so the JSON body must be sent as UTF-8 bytes.
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 12))
        $uri = "https://opencode.ai/zen/v1/chat/completions"
        # DEV_CONTRACTS section 7a: the Delegator proxy (env/proxy.json) takes
        # precedence over the legacy system proxy detection.
        $delegateProxy = Get-DelegateProxy -Provider 'opencode'
        if (-not [string]::IsNullOrWhiteSpace($delegateProxy) -and $delegateProxy -match '^(?i)socks5h?://') {
            $curl = Invoke-CurlJsonRequest -Method "POST" -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $delegateProxy
            if (-not $curl.ok) { throw (([string]$curl.error + " " + [string]$curl.rawBody).Trim()) }
            $response = $curl.body
        } elseif (-not [string]::IsNullOrWhiteSpace($delegateProxy)) {
            $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $delegateProxy
        } else {
            $proxyUrl = Get-SystemProxyForUrl $uri
            if (-not [string]::IsNullOrWhiteSpace($proxyUrl)) {
                $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds -ProxyUrl $proxyUrl -ProxyUseDefaultCredentials
            } else {
                $response = Invoke-Utf8JsonPost -Uri $uri -Headers $headers -BodyBytes $bodyBytes -TimeoutSec $Seconds
            }
        }
        $parsed = Parse-ZenDirectOutput $response
        if ([string]::IsNullOrWhiteSpace($parsed.answer)) {
            return [pscustomobject]@{ exitCode = 1; output = "Zen response contained no answer text." }
        }
        return [pscustomobject]@{
            exitCode = 0
            output = ($response | ConvertTo-Json -Depth 20 -Compress)
            parsed = $parsed
        }
    } catch {
        $extra = ""
        try { if ($_.ErrorDetails.Message) { $extra = " " + $_.ErrorDetails.Message } } catch {}
        $failText = ($_.Exception.Message + $extra).Trim()
        # DEV_CONTRACTS section 7a: name the proxy when the transport failed before an
        # HTTP status arrived so the failure classifies as network, not auth.
        if (-not [string]::IsNullOrWhiteSpace($delegateProxy) -and $failText -notmatch 'via proxy' -and $failText -match '(?i)unable to connect|timed?\s*out|timeout|could not resolve') {
            $failText = $failText + " (via proxy $delegateProxy)"
        }
        return [pscustomobject]@{ exitCode = 1; output = $failText }
    }
}

function Get-FilesActivitySignature {
    param([string[]]$Paths)
    $parts = @()
    foreach ($path in $Paths) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
            if ($item) { $parts += "$($item.Length):$($item.LastWriteTimeUtc.Ticks)" }
        } else {
            $parts += "missing"
        }
    }
    return ($parts -join "|")
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    try {
        if ($script:DelegatorIsWindows) { & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null }
        else { [Diagnostics.Process]::GetProcessById($ProcessId).Kill($true) }
    } catch {}
}

function Test-StreamEventLine {
    # One line of `opencode run --format json` that shows the model is working:
    # a reasoning ("thinking") part, a text part, or a step boundary. Anything else
    # (blank lines, tool noise, plain text) is not evidence of life.
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    try { $event = $Line | ConvertFrom-Json } catch { return $false }
    $type = [string]$event.type
    return ($type -in @("text", "reasoning", "thinking", "step_start", "step-start", "step_finish", "step-finish"))
}

function Get-StreamEventCount {
    param([string]$Text)
    $count = 0
    foreach ($line in (([string]$Text) -split "\r?\n")) {
        if (Test-StreamEventLine $line) { $count++ }
    }
    return $count
}

function Wait-ProcessWithActivity {
    # Idle kill: no byte written to stdout/stderr for IdleSeconds. Hard cap: MaxSeconds,
    # extended ONCE by another MaxSeconds when the stdout already carries stream events -
    # a model that is thinking out loud is working, and cutting it at the cap throws away
    # everything it produced so far.
    param(
        [System.Diagnostics.Process]$Process,
        [int]$MaxSeconds,
        [int]$IdleSeconds,
        [string[]]$ActivityFiles,
        [string]$StreamPath
    )

    $started = Get-Date
    $lastActivity = Get-Date
    $lastSignature = Get-FilesActivitySignature $ActivityFiles
    $capSeconds = $MaxSeconds
    $extended = $false
    while (-not $Process.HasExited) {
        if ($Process.WaitForExit(500)) { return [pscustomobject]@{ exited = $true; reason = "completed" } }
        $now = Get-Date
        if (($now - $started).TotalSeconds -ge $capSeconds) {
            $streaming = $false
            if (-not $extended -and $StreamPath -and (Test-Path -LiteralPath $StreamPath)) {
                $streaming = ((Get-StreamEventCount (Get-Content -LiteralPath $StreamPath -Raw -Encoding UTF8)) -gt 0)
            }
            if ($streaming) {
                $extended = $true
                $capSeconds = $MaxSeconds * 2
            } else {
                Stop-ProcessTree $Process.Id
                return [pscustomobject]@{ exited = $false; reason = "Timed out after $capSeconds seconds." }
            }
        }
        $signature = Get-FilesActivitySignature $ActivityFiles
        if ($signature -ne $lastSignature) {
            $lastSignature = $signature
            $lastActivity = $now
        } elseif (($now - $lastActivity).TotalSeconds -ge $IdleSeconds) {
            Stop-ProcessTree $Process.Id
            return [pscustomobject]@{ exited = $false; reason = "No output activity for $IdleSeconds seconds." }
        }
    }
    return [pscustomobject]@{ exited = $true; reason = "completed" }
}

function Invoke-OpenCodeModel {
    param(
        [string]$Text,
        [string]$OpenCodeModel,
        [int]$Seconds,
        [string]$AgentOverride
    )

    $openCodeCommand = Get-OpenCodeCommandPath
    if ([string]::IsNullOrWhiteSpace($openCodeCommand)) {
        return [pscustomobject]@{
            exitCode = 2
            output = "OpenCode CLI is required for opencode/* models. Install it with: npm install -g opencode-ai"
        }
    }

    Ensure-DelegateDirs
    $stdoutPath = Join-Path $DelegateHome ("opencode-stdout-" + [Guid]::NewGuid().ToString("n") + ".log")
    $stderrPath = Join-Path $DelegateHome ("opencode-stderr-" + [Guid]::NewGuid().ToString("n") + ".log")
    $cmdPath = Join-Path $DelegateHome ("opencode-run-" + [Guid]::NewGuid().ToString("n") + ".cmd")
    $scriptPath = Join-Path $DelegateHome ("opencode-run-" + [Guid]::NewGuid().ToString("n") + ".ps1")
    $promptPath = Join-Path $DelegateHome ("opencode-prompt-" + [Guid]::NewGuid().ToString("n") + ".txt")
    Write-Utf8NoBom -Path $promptPath -Text $Text

    function Quote-Arg {
        param([string]$Value)
        if ($Value -notmatch '[\s"]') { return $Value }
        $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
        return '"' + $escaped + '"'
    }

    $variant = Get-OpenCodeMaxVariant $OpenCodeModel
    if ($PSBoundParameters.ContainsKey("AgentOverride")) {
        $agent = $AgentOverride
    } else {
        $agent = if ($env:CODEX_OPENCODE_AGENT) { $env:CODEX_OPENCODE_AGENT } else { Get-ModelSetting $OpenCodeModel "agent" }
        if ([string]::IsNullOrWhiteSpace($agent)) { $agent = Get-ExtraOpenCodeAgent $OpenCodeModel }
        if ([string]::IsNullOrWhiteSpace($agent)) { $agent = "delegate-text" }
    }
    $escapedPromptPath = $promptPath.Replace("'", "''")
    $escapedModel = $OpenCodeModel.Replace("'", "''")
    $escapedVariant = $variant.Replace("'", "''")
    $escapedAgent = $agent.Replace("'", "''")
    $escapedOpenCodeCommand = $openCodeCommand.Replace("'", "''")
    $escapedConfigDir = $OpenCodeConfigDir.Replace("'", "''")
    $escapedWorkDir = $OpenCodeWorkDir.Replace("'", "''")
    $inlineConfig = @{
        default_agent = "delegate-text"
        agent = @{
            "delegate-text" = @{
                description = "Delegator isolated text engine"
                mode = "primary"
                prompt = "Execute the user's TASK immediately. Never delegate, describe policy, announce readiness, or ask for the task again. Return only the requested result."
                temperature = 0.1
                permission = @{ "*" = "deny" }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress
    $escapedInlineConfig = $inlineConfig.Replace("'", "''")
    $scriptText = @"
`$ErrorActionPreference = 'Stop'
`$Utf8NoBom = [System.Text.UTF8Encoding]::new(`$false)
[Console]::InputEncoding = `$Utf8NoBom
[Console]::OutputEncoding = `$Utf8NoBom
`$OutputEncoding = `$Utf8NoBom
`$env:PYTHONIOENCODING = 'utf-8'
`$env:PYTHONUTF8 = '1'
`$env:OPENCODE_CONFIG_DIR = '$escapedConfigDir'
`$env:OPENCODE_CONFIG_CONTENT = '$escapedInlineConfig'
`$prompt = [System.IO.File]::ReadAllText('$escapedPromptPath', [System.Text.UTF8Encoding]::new(`$false))
`$args = @('run', '-m', '$escapedModel')
if (-not [string]::IsNullOrWhiteSpace('$escapedAgent')) { `$args += @('--agent', '$escapedAgent') }
if (-not [string]::IsNullOrWhiteSpace('$escapedVariant')) { `$args += @('--variant', '$escapedVariant') }
`$args += @('--dir', '$escapedWorkDir', '--format', 'json', '--title', 'codex-opencode-delegate', `$prompt)
& '$escapedOpenCodeCommand' @args
exit `$LASTEXITCODE
"@
    if (-not $script:DelegatorIsWindows) {
        # Redirect inside the child; its output files remain live for the idle
        # watchdog, and no shell reparses the prompt or application paths.
        $redirect = "& '$escapedOpenCodeCommand' @args 1> '$($stdoutPath.Replace("'","''"))' 2> '$($stderrPath.Replace("'","''"))'"
        $scriptText = $scriptText.Replace("& '$escapedOpenCodeCommand' @args", $redirect)
    }
    Write-Utf8NoBom -Path $scriptPath -Text $scriptText
    $commandLine = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File " + (Quote-Arg $scriptPath)
    Write-Utf8NoBom -Path $cmdPath -Text ("@echo off`r`nchcp 65001 >nul`r`nset PYTHONIOENCODING=utf-8`r`nset PYTHONUTF8=1`r`n" + $commandLine + " > " + (Quote-Arg $stdoutPath) + " 2> " + (Quote-Arg $stderrPath) + "`r`n")

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/d /s /c " + (Quote-Arg $cmdPath)
    if (-not $script:DelegatorIsWindows) {
        $psi.FileName = Get-DelegatorPowerShell
        $psi.Arguments = ""
        foreach ($arg in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $scriptPath)) { $psi.ArgumentList.Add($arg) }
    }
    $psi.WorkingDirectory = $OpenCodeWorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $false
    $psi.RedirectStandardError = $false
    $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables["NO_COLOR"] = "1"
    # DEV_CONTRACTS section 7a: the Node-based OpenCode CLI honors HTTP(S)_PROXY.
    # Set them on the child ProcessStartInfo only - never process-wide for this
    # PS session - and keep loopback traffic off the proxy via NO_PROXY.
    $childProxy = Get-DelegateProxy -Provider 'opencode'
    if (-not [string]::IsNullOrWhiteSpace($childProxy)) {
        $psi.EnvironmentVariables["HTTP_PROXY"] = $childProxy
        $psi.EnvironmentVariables["HTTPS_PROXY"] = $childProxy
        $psi.EnvironmentVariables["NO_PROXY"] = "127.0.0.1,localhost"
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $psi
    [void]$process.Start()

    $idleTimeout = Get-OpenCodeIdleTimeout $OpenCodeModel
    $wait = Wait-ProcessWithActivity -Process $process -MaxSeconds $Seconds -IdleSeconds $idleTimeout -ActivityFiles @($stdoutPath, $stderrPath) -StreamPath $stdoutPath
    $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { "" }
    Remove-Item -LiteralPath $cmdPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $promptPath -Force -ErrorAction SilentlyContinue
    $streamEvents = Get-StreamEventCount $stdout
    if (-not $wait.exited) {
        return [pscustomobject]@{ exitCode = 124; output = $wait.reason; streamEvents = $streamEvents }
    }
    $cleanStdout = Clean-OpenCodeOutput $stdout
    $cleanStderr = Clean-OpenCodeOutput $stderr
    return [pscustomobject]@{ exitCode = $process.ExitCode; output = (($cleanStdout + [Environment]::NewLine + $cleanStderr).Trim()); streamEvents = $streamEvents }
}

function Invoke-OpenRouterDirectModel {
    # OpenRouter is an ordinary OpenAI-compatible backend plus two attribution
    # headers, so it routes through the shared caller. The keys still come from
    # `opencode_accounts`: that same key also authorises the OpenCode CLI, which
    # is why it never moved into `custom_providers` (config v13).
    param(
        [string]$Text,
        [string]$OpenCodeModel,
        [int]$Seconds
    )

    $accounts = @(Get-DelegatorOpenRouterAccounts)
    $modelId = Get-OpenRouterModelId $OpenCodeModel
    if ($accounts.Count -eq 0) {
        return [pscustomobject]@{ exitCode = 2; output = "No enabled OpenCode/OpenRouter API keys in Delegator. Add one on the API keys tab." }
    }
    if ([string]::IsNullOrWhiteSpace($modelId)) {
        return [pscustomobject]@{ exitCode = 2; output = "Direct OpenRouter fallback supports only openrouter/* models." }
    }

    return (Invoke-OpenAICompatModel -Text $Text -BaseUrl "https://openrouter.ai/api/v1" -ModelId $modelId -Accounts $accounts -Seconds $Seconds -ExtraHeaders @{ "HTTP-Referer" = "https://local-delegator"; "X-Title" = "Delegator" })
}

function Get-PrimaryDelegateSkillPolicy {
    return @"
PRIMARY DELEGATE SKILL:
Role: Principal Software Engineer and Vibe-Coder.
Objective: production-ready code with strict token efficiency.
Rules: no greetings, pleasantries, apologies, moralizing, filler, basic concept explanations, or prompt restatement.
Simple tasks: output only the final code, command, or answer.
Complex debugging/architecture: use short dense bullets for root cause and fix before code.
Bug format: Root Cause, Fix formulation, Code snippet.
"@
}

function Add-PrimaryDelegateSkillPolicy {
    param([string]$Text, [string]$ExpectedExact)
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExact)) { return $Text }
    $primarySkill = Get-PrimaryDelegateSkillPolicy
    return @"
$primarySkill

TASK:
$Text
"@
}

function Run-Ask {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and (Test-ModelDisabled $Model)) {
        throw "Requested model '$Model' is disabled in Delegator because the upstream provider currently reports it as unsupported."
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and $OpenCodeAllModels -notcontains $Model) {
        throw "Requested model '$Model' is not enabled in the Delegator GUI."
    }

    $expectedExact = Get-ExpectedExactReply $Prompt
    $effectivePrompt = Add-PrimaryDelegateSkillPolicy -Text $Prompt -ExpectedExact $expectedExact
    $runId   = [Guid]::NewGuid().ToString("n")
    $started = Get-Date
    $summary = Get-PromptSummary $Prompt
    $domain  = if ([string]::IsNullOrWhiteSpace($Domain)) { Get-TaskDomain $Prompt } else { $Domain }
    $selected = Select-OpenCodeModel -Text $Prompt
    Write-RunEvent ([pscustomobject]@{
        runId = $runId; delegate = "opencode"; event = "started"; status = "running"
        promptSummary = $summary; domain = $domain; complexity = $Complexity
        selectedModel = $selected; requestedModel = $Model
    })

    $script:_runCompleted = $false
    $lastCandidate = $selected
    $lastProvider = "opencode-cli"
    $recordedFailures = New-Object System.Collections.Generic.HashSet[string]
    $suppressedFailures = New-Object System.Collections.Generic.HashSet[string]
    try {
        $attempts = @()
        $candidateModels = @(Get-ModelAttempts -SelectedModel $selected -Text $Prompt)
        # Recently failed models go to the back; the record survives restarts (model-availability.json).
        $candidateModels = @(Sort-ByAvailability -Candidates $candidateModels)
        # DEV_CONTRACTS section 5: skip models with an active cooldown unless nothing else is left.
        $activeCandidates = @($candidateModels | Where-Object { -not (Test-ModelCoolingDown $_) })
        if ($activeCandidates.Count -gt 0) { $candidateModels = $activeCandidates }
        foreach ($candidate in $candidateModels) {
            Write-RunEvent ([pscustomobject]@{
                runId = $runId; delegate = "opencode"; event = "attempt_started"; status = "running"
                promptSummary = $summary; domain = $domain; model = $candidate
                variant = Get-OpenCodeMaxVariant $candidate; attempts = $attempts.Count + 1
            })
            # THIS attempt's own duration. usage.jsonl elapsedMs is per CALL
            # (section 2.1) and Get-ModelHealth turns it into a p75 latency; timing
            # from the start of the run instead made every rung of the ladder wear
            # the cost of the rungs before it, so the model that finally answered
            # looked like the slow one.
            $attemptSw = [System.Diagnostics.Stopwatch]::StartNew()
            $usedDirectOpenRouter = $false
            $preferredExecutionPath = Get-PreferredExecutionPath $candidate
            # A custom provider owns its prefix, so it is decided before the
            # OpenCode CLI is ever consulted: the CLI has never heard of it and
            # `Test-ModelAvailableInOpenCode` would send it down the CLI branch.
            $customProvider = Get-CustomProviderForModel $candidate
            $executionPath = "opencode-cli"
            $providerName = "opencode-cli"
            if ($null -ne $customProvider) {
                $usedDirectOpenRouter = $false
                $usedZenDirect = $false
                $executionPath = "openai-compat-direct"
                $providerName = [string]$customProvider.id
                $result = Invoke-CustomProviderModel -Text $effectivePrompt -OpenCodeModel $candidate -Seconds $TimeoutSec
                $parsed = if ($result.PSObject.Properties["parsed"]) { $result.parsed } else { [pscustomobject]@{ answer = ""; tokens = 0; promptTokens = $null; completionTokens = $null; cost = 0 } }
            } elseif ($preferredExecutionPath -eq "zen-direct") {
                $usedDirectOpenRouter = $false
                $usedZenDirect = $true
                $executionPath = "zen-direct"
                $providerName = "zen"
                $result = Invoke-ZenDirectModel -Text $effectivePrompt -OpenCodeModel $candidate -Seconds $TimeoutSec
                $parsed = if ($result.PSObject.Properties["parsed"]) { $result.parsed } else { [pscustomobject]@{ answer = ""; tokens = 0; promptTokens = $null; completionTokens = $null; cost = 0 } }
            } elseif ($candidate -like "openrouter/*" -and ($preferredExecutionPath -eq "openrouter-direct" -or -not (Test-ModelAvailableInOpenCode $candidate))) {
                $usedDirectOpenRouter = $true
                $usedZenDirect = $false
                $executionPath = "openrouter-direct"
                $providerName = "openrouter"
                $result = Invoke-OpenRouterDirectModel -Text $effectivePrompt -OpenCodeModel $candidate -Seconds $TimeoutSec
                $parsed = if ($result.PSObject.Properties["parsed"]) { $result.parsed } else { [pscustomobject]@{ answer = ""; tokens = 0; promptTokens = $null; completionTokens = $null; cost = 0 } }
            } else {
                $usedZenDirect = $false
                $result = Invoke-OpenCodeModel -Text $effectivePrompt -OpenCodeModel $candidate -Seconds $TimeoutSec
                $parsed = Parse-OpenCodeOutput $result.output
                if ($result.exitCode -eq 0 -and (Test-UnhelpfulDelegateAnswer $parsed.answer)) {
                    # A CLI can finish after tool calls without producing any text.
                    # Never retry through the unrestricted build agent or count a
                    # canned readiness reply as an answer; let the model ladder run.
                    $result.exitCode = 1
                    $result.output = "OpenCode returned no useful answer text.`n" + [string]$result.output
                }
            }
            $lastCandidate = $candidate
            $lastProvider = $providerName
            $attempts += [pscustomobject]@{ model = $candidate; exitCode = $result.exitCode }
            if ($result.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($expectedExact) -and $parsed.answer.Trim() -ne $expectedExact.Trim()) {
                $result = [pscustomobject]@{
                    exitCode = 1
                    output = ("Exact reply mismatch. Expected '{0}', got '{1}'." -f $expectedExact.Trim(), $parsed.answer.Trim())
                }
            }
            if ($result.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($parsed.answer)) {
                $attemptSw.Stop()
                $elapsed = [int]((Get-Date) - $started).TotalMilliseconds
                Write-RunEvent ([pscustomobject]@{
                    runId = $runId; delegate = "opencode"; event = "completed"; status = "ok"
                    promptSummary = $summary; domain = $domain; model = $candidate
                    variant = Get-OpenCodeMaxVariant $candidate
                    executionPath = $executionPath
                    tokens = $parsed.tokens; cost = $parsed.cost; elapsedMs = $elapsed
                    outputPreview = (Get-PromptSummary $parsed.answer)
                })
                $accountId = $null
                if ($result.PSObject.Properties["accountId"]) { $accountId = [string]$result.accountId }
                # The RUN took $elapsed; THIS CALL took $attemptSw. The run event
                # keeps the run number (that is the timeline), the usage record
                # keeps the call number (that is what p75 latency is made of).
                Write-DelegateUsageRecord -Mode $Command -Provider $providerName -ModelId $candidate -PromptTokens $parsed.promptTokens -CompletionTokens $parsed.completionTokens -TotalTokens $parsed.tokens -Cost $parsed.cost -ElapsedMs ([long]$attemptSw.ElapsedMilliseconds) -Ok $true -AccountId $accountId
                Clear-ModelCooldown $candidate
                Update-ModelAvailability -ModelId $candidate -Ok $true -ElapsedMs ([int]$attemptSw.ElapsedMilliseconds)
                $script:_runCompleted = $true
                if ($Json) {
                    [pscustomobject]@{ delegate = "opencode"; model = $candidate; output = $parsed.answer; tokens = $parsed.tokens; promptTokens = $parsed.promptTokens; completionTokens = $parsed.completionTokens; totalTokens = $parsed.tokens; cost = $parsed.cost; executionPath = $executionPath; attempts = $attempts } | ConvertTo-Json -Depth 8
                } else {
                    Write-Output $parsed.answer
                }
                return
            }
            $attemptSw.Stop()
            $errorClass = Get-OpenCodeErrorClass -ExitCode $result.exitCode -Output $result.output
            # A call that hit its cap while the model was still streaming is alive, not
            # broken: no cooldown, no health penalty, and the ladder moves on.
            if ($result.exitCode -eq 124 -and $result.PSObject.Properties["streamEvents"] -and [int]$result.streamEvents -gt 0) {
                $errorClass = "stalled"
            }
            $retryAfterSec = 0
            if ([string]$result.output -match '(?i)retry[-_ ]?(after|delay)\D{0,10}(\d+)') { $retryAfterSec = [int]$Matches[2] }
            $failStatusCode = [int]$result.exitCode
            if ([string]$result.output -match '\((\d{3})\)') { $failStatusCode = [int]$Matches[1] }
            $cooldownSec = Get-ModelCooldownSeconds -ErrorClass $errorClass -RetryAfterSec $retryAfterSec
            if ($cooldownSec -gt 0) {
                Set-ModelCooldown -ModelId $candidate -Reason $errorClass -Seconds $cooldownSec -StatusCode $failStatusCode
            }
            Write-RunEvent ([pscustomobject]@{
                runId = $runId; delegate = "opencode"; event = "attempt_failed"; status = "error"
                promptSummary = $summary; domain = $domain; model = $candidate
                executionPath = $executionPath
                exitCode = $result.exitCode; errorClass = $errorClass; elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
                errorPreview = (Get-PromptSummary $result.output)
            })
            # EVERY failed rung, not just the last one. The ladder used to write a
            # single record per run, so a run that failed on A and B and answered
            # on C left no trace of A and B in usage.jsonl at all: Get-ModelHealth
            # never learned they were broken and the router picked A first again
            # on the very next call. The evidence the routing claims to use has to
            # exist before it can be used.
            $failedAccountId = $null
            if ($result.PSObject.Properties["accountId"]) { $failedAccountId = [string]$result.accountId }
            if (Test-AttemptIsModelFailure -ExitCode $result.exitCode -ErrorClass $errorClass) {
                Write-DelegateUsageRecord -Mode $Command -Provider $providerName -ModelId $candidate -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null -ElapsedMs ([long]$attemptSw.ElapsedMilliseconds) -Ok $false -AccountId $failedAccountId -ErrorClass $errorClass
                Update-ModelAvailability -ModelId $candidate -Ok $false -ErrorClass $errorClass
                [void]$recordedFailures.Add([string]$candidate)
            } else {
                # "Deliberately NOT recorded" is a different state from "already
                # recorded", and the finally path must respect both. Membership of
                # $recordedFailures alone would let a crash on the next rung write
                # an unclassified failure for the exit-2 rung this branch just
                # refused to blame - and a record with no errorClass reads as a
                # pre-0.7.2 one, i.e. a full quality signal.
                [void]$suppressedFailures.Add([string]$candidate)
            }
        }

        Write-RunEvent ([pscustomobject]@{
            runId = $runId; delegate = "opencode"; event = "completed"; status = "failed"
            promptSummary = $summary; domain = $domain
            elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds; attempts = $attempts.Count
        })
        $script:_runCompleted = $true
        # The loop now records each rung, so the old blanket record here would
        # double-count the last candidate - the very model the router is deciding
        # about. It survives only for the case where no rung ran at all.
        #
        # A ladder in which every rung failed with exit 2 deliberately writes
        # NOTHING: no provider call was made (the CLI is missing or unconfigured),
        # nothing was spent, and attributing it would demote the whole pool for a
        # problem no model caused.
        if ($recordedFailures.Count -eq 0 -and $attempts.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$lastCandidate)) {
            Write-DelegateUsageRecord -Mode $Command -Provider $lastProvider -ModelId $lastCandidate -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null -ElapsedMs ([int]((Get-Date) - $started).TotalMilliseconds) -Ok $false -AccountId $null -ErrorClass "unknown"
        }
        throw "All opencode models failed."
    } finally {
        # Гарантируем запись completed если скрипт упал до явного завершения
        if (-not $script:_runCompleted) {
            Write-RunEvent ([pscustomobject]@{
                runId = $runId; delegate = "opencode"; event = "completed"; status = "failed"
                promptSummary = $summary; domain = $domain
                elapsedMs = [int]((Get-Date) - $started).TotalMilliseconds
                note = "force-closed by finally block (unexpected exit)"
            })
            # An unexpected exception at the top of the NEXT rung leaves
            # $lastCandidate pointing at the previous one, which the loop has
            # already recorded - counting it twice would make one bad call look
            # like two - or deliberately SUPPRESSED, and re-adding it here without
            # an errorClass would read as a pre-0.7.2 record, i.e. a full quality
            # signal for a local environment fault.
            $already = $recordedFailures.Contains([string]$lastCandidate) -or $suppressedFailures.Contains([string]$lastCandidate)
            if (-not $already) {
                Write-DelegateUsageRecord -Mode $Command -Provider $lastProvider -ModelId $lastCandidate -PromptTokens $null -CompletionTokens $null -TotalTokens $null -Cost $null -ElapsedMs ([int]((Get-Date) - $started).TotalMilliseconds) -Ok $false -AccountId $null
            }
        }
    }
}


if ($MyInvocation.InvocationName -ne ".") {
    switch ($Command) {
        # `exit 0` is load-bearing. Without it a script that merely RETURNS
        # leaves $LASTEXITCODE untouched, and the dispatcher reads it right
        # after an in-process `& opencode-delegate.ps1` call: it then sees the
        # exit code of whatever external command ran last inside this script
        # (curl, taskkill, the CLI). Good answers were being discarded as
        # failures and re-asked on a weaker backend (diagnosed live 2026-08-12).
        # A failure still throws, and the caller's catch turns that into 1.
        "ask" { Run-Ask; exit 0 }
        "models" {
            $openCodeExecutable = Get-OpenCodeCommandPath
            if ([string]::IsNullOrWhiteSpace($openCodeExecutable)) { throw "OpenCode CLI is not installed. Run: npm install -g opencode-ai" }
            Invoke-WithOpenCodeProxyEnv { & $openCodeExecutable models }
        }
        "stats" {
            $openCodeExecutable = Get-OpenCodeCommandPath
            if ([string]::IsNullOrWhiteSpace($openCodeExecutable)) { throw "OpenCode CLI is not installed. Run: npm install -g opencode-ai" }
            Invoke-WithOpenCodeProxyEnv { & $openCodeExecutable stats }
        }
    }
}

param(
    [string]$DelegateHome = $(if ($env:DELEGATOR_RUNTIME_HOME) { $env:DELEGATOR_RUNTIME_HOME } else { Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime" })
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$updatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
$syncDate = (Get-Date).ToString("yyyy-MM-dd")

function Get-DelegateProxy {
    param([string]$Provider)
    # DEV_CONTRACTS section 7a: effective outbound proxy for MODEL traffic
    # (including catalog refresh), or $null. Precedence: env DELEGATOR_PROXY
    # ("off" disables, any other non-empty value forces that proxy) >
    # <RT>\proxy.json {"enabled":true,"url":...}.
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
    $tempDir = [System.IO.Path]::GetTempPath()
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
            [System.IO.File]::WriteAllBytes($bodyFile, $BodyBytes)
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

# ── Model ratings (DPR) ───────────────────────────────────────────────────────
# The catalog this script writes is the strength channel every consumer reads, so
# this is where the SHIPPED model-ratings.json enters the runtime. DPR: 0 means
# "cannot program at all", no upper bound, 2026-08 snapshot tops at 156. Longest
# substring of the lowercased id wins, so one row covers every provider prefix.
#
# The alias-NAME heuristic this replaced is deliberately GONE, not kept as a
# fallback: it did not merely guess, it guessed BACKWARDS on the models that
# matter. It scored nemotron-3-ultra 93 of 100 - top of the deep tier - while the
# published coding index puts it at 49, and that model is the one already on
# record for burning 175 s on a trivial question and failing 6 of its last 10
# calls. A wrong number is worse than no number, so an unrated alias now gets
# DelegateUnratedDpr and has to earn trust through measured health.
#
# ONE OF FOUR COPIES - delegator-common.ps1, opencode-delegate.ps1,
# update-free-models.ps1 (here) and src\gui\opencode_setup.rs.
$script:DelegateModelRatingsFile = Join-Path $PSScriptRoot "model-ratings.json"
$script:DelegateUnratedDpr = 100
$script:DelegateRatingRows = $null
$script:DelegateRatingsVersion = $null

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
                if ($null -eq $entry.dpr) { continue }
                $rows += [pscustomobject]@{
                    match = ([string]$entry.match).ToLowerInvariant()
                    dpr   = [int]$entry.dpr
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
        if ($name.Contains($row.match)) { return [int]$row.dpr }
    }
    return $null
}

function Get-ZenModelStrength {
    # DPR of a Zen alias for the catalog. Unrated aliases (stealth names like
    # big-pickle or x-preview-f) get the neutral normal-tier score so they stay
    # reachable without being handed deep work.
    param([string]$ModelId)
    $rating = Get-DelegatorModelRating $ModelId
    if ($null -ne $rating) { return [int]$rating }
    return [int]$script:DelegateUnratedDpr
}

# The Zen free set changes with every OpenCode release, so the live
# `opencode models` output is authoritative: every `^opencode/...$` alias IS the
# current free Zen set. The pinned table below only overlays known per-model
# metadata (timeout/variant/ranking score); retired aliases drop out
# automatically and new aliases get defaults - nothing here needs editing when
# the set changes upstream.
$zenKnownMeta = @{
    "opencode/big-pickle"             = @{ timeout = 120; variant = "high"; score = 85.5 }
    "opencode/deepseek-v4-flash-free" = @{ timeout = 90; variant = "high"; score = 91.0 }
    "opencode/nemotron-3-ultra-free"  = @{ timeout = 150; variant = "xhigh"; score = 88.0 }
    "opencode/laguna-s-2.1-free"      = @{ timeout = 120; variant = "high"; score = 87.5 }
    "opencode/ling-3.0-flash-free"    = @{ timeout = 90; variant = "high"; score = 87.0 }
    "opencode/mimo-v2.5-free"         = @{ timeout = 90; variant = "high"; score = 86.5 }
    "opencode/north-mini-code-free"   = @{ timeout = 120; variant = "high"; score = 86.0 }
}

$installed = @(opencode models 2>$null | ForEach-Object { ([string]$_).Trim() })
if ($LASTEXITCODE -ne 0 -or $installed.Count -eq 0) {
    throw "Cannot verify the current OpenCode model list; no config was changed."
}
$liveZenIds = @($installed | Where-Object { $_ -match '^opencode/[0-9A-Za-z._-]+$' } | Select-Object -Unique)
if ($liveZenIds.Count -eq 0) {
    throw "OpenCode CLI returned no opencode/* Zen aliases; no config was changed."
}

# Strength catalog consumed by the PowerShell runtime router
# (opencode-delegate.ps1 refreshes the same file inline when older than 24h).
$catalogPath = Join-Path $DelegateHome "opencode-zen-catalog.json"
New-Item -ItemType Directory -Force -Path $DelegateHome | Out-Null
$catalogModels = @($liveZenIds | ForEach-Object {
    [pscustomobject]@{ id = $_; strength = (Get-ZenModelStrength $_) }
} | Sort-Object @{ Expression = { -[int]$_.strength } }, @{ Expression = { [string]$_.id } })
$zenCatalog = [pscustomobject]@{
    version = 1
    # Stamp of the ratings table this cache was built from. A consumer that
    # reads a different table must reject the cache instead of routing on
    # yesterday's scores until the 24 h TTL expires.
    ratingsVersion = (Get-DelegatorRatingsVersion)
    updatedAt = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    models = $catalogModels
}
[IO.File]::WriteAllText($catalogPath, ($zenCatalog | ConvertTo-Json -Depth 5), $utf8NoBom)

$zenModels = @($liveZenIds | ForEach-Object {
    $id = [string]$_
    $meta = if ($zenKnownMeta.ContainsKey($id)) { $zenKnownMeta[$id] } else { @{ timeout = 120; variant = "high"; score = 86.0 } }
    [pscustomobject]@{
        id = $id
        name = $id.Substring("opencode/".Length)
        timeout = [int]$meta.timeout
        variant = [string]$meta.variant
        score = [double]$meta.score
    }
})
$retiredZen = @($zenKnownMeta.Keys | Where-Object { $liveZenIds -notcontains $_ } | Sort-Object)

$zenFree = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($model in $zenModels) { [void]$zenFree.Add($model.id) }

function Test-ManagedFreeId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    if ($Id.StartsWith("openrouter/", [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($zenFree.Contains($Id) -or $Id -eq "opencode/big-pickle") { return $true }
    # The automatic OpenCode pool is free-only. Any other Zen alias (including
    # paid GPT/MiniMax/etc.) must stay out even if its name does not say "free".
    return $Id.StartsWith("opencode/", [StringComparison]::OrdinalIgnoreCase)
}

function Test-LiveFreeId {
    param([string]$Id)
    return $zenFree.Contains($Id) -or $openRouterFree.Contains($Id)
}

function Sync-RankingRows {
    param([object[]]$Rows)
    $result = @($Rows | Where-Object {
        -not (Test-ManagedFreeId ([string]$_.model)) -or (Test-LiveFreeId ([string]$_.model))
    })
    foreach ($model in $zenModels) {
        if (@($result | Where-Object { $_.model -eq $model.id }).Count -eq 0) {
            $result += [pscustomobject][ordered]@{
                model = $model.id
                name = $model.name
                kind = "opencode"
                score = $model.score
            }
        }
    }
    return $result
}

$rankingPath = Join-Path $DelegateHome "model-rankings.json"
$settingsPath = Join-Path $DelegateHome "delegate-model-settings.json"
$extrasPath = Join-Path $DelegateHome "opencode-extra-models.json"
$missingConfigs = @(@($rankingPath, $settingsPath) | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missingConfigs.Count -gt 0) {
    # The strength catalog is the primary product now; the legacy ranking and
    # model-settings tuning files are optional and simply skipped when absent.
    Write-Output "Zen catalog updated: $catalogPath ($($zenModels.Count) live free models)"
    foreach ($id in $retiredZen) { Write-Output "Retired upstream (dropped): $id" }
    Write-Output "Legacy tuning configs not present; nothing else to sync:"
    foreach ($path in $missingConfigs) { Write-Output "- $path" }
    exit 0
}

# DEV_CONTRACTS section 7a: the catalog refresh honors the optional outbound proxy.
$openRouterCatalogUri = "https://openrouter.ai/api/v1/models"
$catalogProxy = Get-DelegateProxy -Provider 'opencode'
if (-not [string]::IsNullOrWhiteSpace($catalogProxy) -and $catalogProxy -match '^(?i)socks5h?://') {
    $catalogResult = Invoke-CurlJsonRequest -Method "GET" -Uri $openRouterCatalogUri -Headers @{} -BodyBytes $null -TimeoutSec 45 -ProxyUrl $catalogProxy
    if (-not $catalogResult.ok) { throw ("OpenRouter catalog refresh failed: " + [string]$catalogResult.error) }
    $openRouterResponse = $catalogResult.body
} elseif (-not [string]::IsNullOrWhiteSpace($catalogProxy)) {
    $openRouterResponse = Invoke-RestMethod -Uri $openRouterCatalogUri -TimeoutSec 45 -Proxy $catalogProxy
} else {
    $openRouterResponse = Invoke-RestMethod -Uri $openRouterCatalogUri -TimeoutSec 45
}
$openRouterFree = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($model in @($openRouterResponse.data)) {
    try {
        $promptPrice = [decimal]::Parse([string]$model.pricing.prompt, [Globalization.CultureInfo]::InvariantCulture)
        $completionPrice = [decimal]::Parse([string]$model.pricing.completion, [Globalization.CultureInfo]::InvariantCulture)
        if ($promptPrice -eq 0 -and $completionPrice -eq 0) {
            [void]$openRouterFree.Add("openrouter/$($model.id)")
        }
    } catch {}
}

$backupPaths = @($rankingPath, $settingsPath)
if (Test-Path -LiteralPath $extrasPath) { $backupPaths += $extrasPath }
foreach ($path in $backupPaths) {
    Copy-Item -LiteralPath $path -Destination "$path.bak-$timestamp"
}

$rankings = Get-Content -LiteralPath $rankingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$allBefore = @($rankings.overall.model) + @($rankings.domains.PSObject.Properties | ForEach-Object { $_.Value.model })
$staleIds = @($allBefore | Where-Object {
    (Test-ManagedFreeId ([string]$_)) -and -not (Test-LiveFreeId ([string]$_))
} | Sort-Object -Unique)
$rankings.overall = @(Sync-RankingRows @($rankings.overall))
foreach ($property in $rankings.domains.PSObject.Properties) {
    $property.Value = @(Sync-RankingRows @($property.Value))
}
$rankings.version = [Math]::Max([int]$rankings.version, 18)
$rankings.updatedAt = $updatedAt
$rankings.sourceBenchmark = "Live 'opencode models' Zen list + OpenRouter live pricing $syncDate"
$newNote = "Reconciled all active free aliases on ${syncDate}: $($zenModels.Count) live OpenCode Zen models; removed paid or withdrawn aliases."
if (@($rankings.sourceNotes) -notcontains $newNote) {
    $rankings.sourceNotes = @($newNote) + @($rankings.sourceNotes)
}

$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($property in @($settings.models.PSObject.Properties)) {
    $id = [string]$property.Name
    if ((Test-ManagedFreeId $id) -and -not (Test-LiveFreeId $id)) {
        $entry = $property.Value
        if ($entry.PSObject.Properties["enabled"]) { $entry.enabled = $false } else { $entry | Add-Member -NotePropertyName enabled -NotePropertyValue $false }
        if ($entry.PSObject.Properties["disabled"]) { $entry.disabled = $true } else { $entry | Add-Member -NotePropertyName disabled -NotePropertyValue $true }
        $disabledNote = "Disabled ${syncDate}: no longer free or no longer listed by the live provider."
        if ($entry.PSObject.Properties["notes"]) { $entry.notes = $disabledNote } else { $entry | Add-Member -NotePropertyName notes -NotePropertyValue $disabledNote }
    }
}

foreach ($model in $zenModels) {
    $entry = [pscustomobject][ordered]@{
        idleTimeoutSec = $model.timeout
        preferDomains = @("code_debug", "architecture", "reasoning", "refactoring", "data_consistency")
        avoidDomains = @("vision")
        notes = "Verified free in the local 'opencode models' Zen list on ${syncDate}."
        inputModalities = @("text")
        outputModalities = @("text")
        contentModes = @("text")
        supportsVision = $false
        supportsImageOutput = $false
        supportsRawBinary = $false
        executionPath = "opencode-cli"
        enabled = ($model.id -ne "opencode/big-pickle")
        disabled = $false
        variant = $model.variant
        capabilitySource = "Live 'opencode models' Zen list verification $syncDate"
    }
    if ($settings.models.PSObject.Properties[$model.id]) {
        $settings.models.PSObject.Properties[$model.id].Value = $entry
    } else {
        $settings.models | Add-Member -NotePropertyName $model.id -NotePropertyValue $entry
    }
}
$settings.version = [Math]::Max([int]$settings.version, 12)
$settings.updatedAt = $updatedAt

if (Test-Path -LiteralPath $extrasPath) {
    $extras = Get-Content -LiteralPath $extrasPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pool in @("fast", "normal", "deep")) {
        if (-not $extras.PSObject.Properties[$pool]) { continue }
        $extras.$pool = @($extras.$pool | Where-Object {
            $id = if ($_ -is [string]) { [string]$_ } else { [string]$_.model }
            -not (Test-ManagedFreeId $id) -or (Test-LiveFreeId $id)
        })
    }
    $extras.version = [Math]::Max([int]$extras.version, 9)
    $extras.updatedAt = $updatedAt
    $extras.note = "Only models confirmed free by live provider metadata on $syncDate."
    [IO.File]::WriteAllText($extrasPath, ($extras | ConvertTo-Json -Depth 100), $utf8NoBom)
}

[IO.File]::WriteAllText($rankingPath, ($rankings | ConvertTo-Json -Depth 100), $utf8NoBom)
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 100), $utf8NoBom)

Write-Output "Verified OpenCode Zen free models: $($zenModels.Count)"
foreach ($id in $retiredZen) { Write-Output "Retired upstream (dropped): $id" }
Write-Output "Verified OpenRouter free models: $($openRouterFree.Count)"
Write-Output "Removed from active rankings: $($staleIds.Count)"
foreach ($id in $staleIds) { Write-Output "- $id" }
Write-Output "Updated: $catalogPath"
Write-Output "Updated: $rankingPath"
Write-Output "Updated: $settingsPath"
if (Test-Path -LiteralPath $extrasPath) { Write-Output "Updated: $extrasPath" }

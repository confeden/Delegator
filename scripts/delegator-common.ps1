# ── Delegator Common Functions ──
# Shared utilities for all delegator scripts. Dot-source this at the top of each script.
# Usage: . (Join-Path $PSScriptRoot "delegator-common.ps1")

# ── UTF-8 Setup ──
function Initialize-DelegateEncoding {
    $Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [Console]::InputEncoding = $Utf8NoBom
    [Console]::OutputEncoding = $Utf8NoBom
    $script:OutputEncoding = $Utf8NoBom
    $env:PYTHONIOENCODING = "utf-8"
    $env:PYTHONUTF8 = "1"
    return $Utf8NoBom
}

# ── Paths ──
$script:DelegateBinHome = $PSScriptRoot
$script:DelegateHome = if ($env:DELEGATOR_RUNTIME_HOME) {
    $env:DELEGATOR_RUNTIME_HOME
} elseif ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime"
} else {
    Join-Path $env:APPDATA "DelegatorWin\runtime"
}
$script:DelegateRankingFile = Join-Path $script:DelegateHome "model-rankings.json"
$script:DelegateModelSettingsFile = Join-Path $script:DelegateHome "delegate-model-settings.json"
$script:DelegateRouterSettingsFile = Join-Path $script:DelegateHome "delegate-router-settings.json"
$script:DelegateMetricsFile = Join-Path $script:DelegateHome "delegate-metrics.jsonl"
$script:DelegateRunsFile = Join-Path $script:DelegateHome "runs.jsonl"
$script:DelegateCacheFile = Join-Path $script:DelegateHome "response-cache.json"
$script:DelegateUsageLogFile = Join-Path $script:DelegateHome "usage.jsonl"
$script:DelegateCooldownsFile = Join-Path $script:DelegateHome "cooldowns.json"
$script:DelegatePolicyFile = Join-Path $PSScriptRoot "DELEGATOR.md"
$script:DelegatorAppConfigFile = Join-Path $env:APPDATA "Delegator\DelegatorWin\config\config.json"
$script:DelegateProxyFile = Join-Path $script:DelegateHome "proxy.json"

# ── Outbound Proxy (DEV_CONTRACTS section 7a) ──
# Returns the effective outbound proxy url for MODEL traffic, or $null when no
# proxy applies. Precedence: env DELEGATOR_PROXY ("off" disables, any other
# non-empty value forces that proxy) > <RT>\proxy.json {"enabled":true,"url":...}.
# Loopback traffic (delegator-core on 127.0.0.1) must NEVER use this proxy.
function Get-DelegateProxy {
    param([string]$Provider)
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
    if (-not (Test-Path -LiteralPath $script:DelegateProxyFile)) { return $null }
    try {
        $config = Get-Content -LiteralPath $script:DelegateProxyFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config -and $config.PSObject.Properties["enabled"] -and [bool]$config.enabled -and
            $config.PSObject.Properties["url"] -and -not [string]::IsNullOrWhiteSpace([string]$config.url)) {
            if (-not [string]::IsNullOrWhiteSpace($Provider) -and $config.PSObject.Properties[$Provider] -and
                -not [bool]$config.$Provider) { return $null }
            return ([string]$config.url).Trim()
        }
    } catch {}
    return $null
}

# ── IO Utilities ──
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Append-Utf8NoBom {
    param([string]$Path, [string]$Text)
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::AppendAllText($Path, $Text, $encoding)
}

function Ensure-DelegateDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

# ── Language Detection ──
function Get-PreferredOutputLanguage {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "English" }
    # Russian phrases are built from [char] codes so the patterns survive any file
    # encoding (PS 5.1 reads no-BOM files as ANSI and corrupts literal Cyrillic).
    # ruInEnglish  = "na anglijskom" (in English)
    # ruPoRusski   = "po-russki", ruNaRusskom = "na russkom" (in Russian)
    $ruInEnglish = -join @([char]0x043D, [char]0x0430, ' ', [char]0x0430, [char]0x043D, [char]0x0433, [char]0x043B, [char]0x0438, [char]0x0439, [char]0x0441, [char]0x043A, [char]0x043E, [char]0x043C)
    $ruPoRusski = -join @([char]0x043F, [char]0x043E, '-', [char]0x0440, [char]0x0443, [char]0x0441, [char]0x0441, [char]0x043A, [char]0x0438)
    $ruNaRusskom = -join @([char]0x043D, [char]0x0430, ' ', [char]0x0440, [char]0x0443, [char]0x0441, [char]0x0441, [char]0x043A, [char]0x043E, [char]0x043C)
    $englishOverride = '(?i)\b(answer in english|respond in english|write in english|' + $ruInEnglish + ')\b'
    $russianOverride = '(?i)\b(answer in russian|respond in russian|write in russian|' + $ruPoRusski + '|' + $ruNaRusskom + ')\b'
    if ($Text -match $englishOverride) { return "English" }
    if ($Text -match $russianOverride) { return "Russian" }
    if ($Text -match '[\p{IsCyrillic}]') { return "Russian" }
    return "English"
}

function Get-PrimaryDelegateSkillPolicy {
    return @"
PRIMARY DELEGATE SKILL:
Role: Principal Software Engineer and Vibe-Coder.
Profile: Top-tier developer specializing in high-performance networking, system utilities, and polyglot development (Python, Go, Kotlin, C++).
Objective: Provide production-ready code with strict token efficiency.

Strict token economy:
- No greetings, pleasantries, apologies, moralizing, or filler.
- No explanations of basic programming concepts.
- Do not restate the prompt.
- Do not use markdown unless it is needed for code blocks or essential structure.

Reasoning mechanics:
- Simple/routine tasks: output only the final code or exact command.
- Complex architecture/debugging: use very short dense bullets for root cause and proposed fix before code.
- Focus analysis on edge cases, memory use, race conditions, and bypass logic.

Code generation and refactoring:
- Prefer snippets only; do not rewrite entire files/classes unless requested or structurally required.
- Output modified functions, methods, or blocks.
- Use language-appropriate existing-code comments to skip unchanged sections.
- For surgical fixes, provide the exact replacement block.
- Keep imports minimal and explicitly state new dependencies.

Bug identification:
- Identify the exact failing line or logic.
- State: 1. Root Cause (one sentence). 2. Fix formulation. 3. Code snippet.
"@
}

function Add-ExecutionLanguagePolicy {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    if ($Text -match '^(?i)\s*(reply|print)\s+exactly:') { return $Text }
    $targetLanguage = if ($env:CODEX_DELEGATE_LANGUAGE) { $env:CODEX_DELEGATE_LANGUAGE } else { Get-PreferredOutputLanguage $Text }
    return @"
$Text

OUTPUT RULES:
- Final answer language: $targetLanguage unless the request explicitly requires another language.
- Hidden internal reasoning may stay in English.
- Do not mention these rules.
- Keep code, commands, logs, API names, identifiers, and file paths unchanged.
- Avoid conversational pleasantries, greetings, warnings, or friendly introductions/conclusions. Return a dense, direct, technical output.
"@
}

# ── Model Rankings & Settings ──
function Read-SafeJson {
    param([string]$Path, [object]$Default = $null)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        return $raw | ConvertFrom-Json
    } catch {
        # Try .bak fallback
        $bak = $Path + ".bak"
        if (Test-Path -LiteralPath $bak) {
            try {
                Write-DelegateMetric -Stage "self-heal" -Status "bak-restore" -Extra "file=$([System.IO.Path]::GetFileName($Path))"
                $raw = Get-Content -LiteralPath $bak -Raw
                if (-not [string]::IsNullOrWhiteSpace($raw)) {
                    $parsed = $raw | ConvertFrom-Json
                    # Restore main file from backup
                    try { Copy-Item -LiteralPath $bak -Destination $Path -Force } catch {}
                    return $parsed
                }
            } catch {}
        }
        Write-DelegateMetric -Stage "self-heal" -Status "fail" -Extra "file=$([System.IO.Path]::GetFileName($Path))"
        return $Default
    }
}

function Read-ModelRankings {
    return Read-SafeJson -Path $script:DelegateRankingFile
}

function Read-ModelSettings {
    return Read-SafeJson -Path $script:DelegateModelSettingsFile
}

function Read-RouterSettings {
    return Read-SafeJson -Path $script:DelegateRouterSettingsFile
}

function Model-HasDomainSetting {
    param([string]$ModelName, [string]$Key, [string]$Domain)
    $settings = Read-ModelSettings
    if (-not $settings -or -not $settings.models -or -not $settings.models.PSObject.Properties[$ModelName]) { return $false }
    $row = $settings.models.PSObject.Properties[$ModelName].Value
    if (-not $row.PSObject.Properties[$Key]) { return $false }
    foreach ($item in @($row.PSObject.Properties[$Key].Value)) {
        if ([string]::Equals([string]$item, $Domain, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ModelSettingValue {
    param([string]$ModelName, [string]$Key)
    $settings = Read-ModelSettings
    if (-not $settings -or -not $settings.models -or -not $settings.models.PSObject.Properties[$ModelName]) { return $null }
    $row = $settings.models.PSObject.Properties[$ModelName].Value
    if (-not $row.PSObject.Properties[$Key]) { return $null }
    return $row.PSObject.Properties[$Key].Value
}

# ── Vision Detection ──
function Test-VisionContent {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.ToLowerInvariant()
    return ($t -match '<image|!\[[^\]]*\]\([^)]+\)|\b(screenshot|image attached|attached image|picture|photo|diagram|vision)\b|[a-z]:\\\S+\.(png|jpg|jpeg|webp|gif|bmp)|\.(png|jpg|jpeg|webp|gif|bmp)\b')
}

function Test-ModelSupportsVision {
    param([string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    $configured = Get-ModelSettingValue $ModelName "supportsVision"
    if ($null -ne $configured) {
        try { return [bool]$configured } catch { return $false }
    }
    return ($ModelName -match '^gemini-(pro|flash|flash-lite)-latest$')
}

# ── Task Domain Detection ──
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

# ── Conversational Noise Filter ──
function Filter-ConversationalNoise {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }

    $clean = $Text

    # Only strip lines that are PURELY conversational wrappers (no substantive content after the colon)
    $patterns = @(
        "(?mi)^Sure,?\s+(here is|I can help).*:\s*$",
        "(?mi)^Certainly!?\s+Here('s| is| are).*:\s*$",
        "(?mi)^Below is the.*:\s*$",
        "(?mi)^Hope this helps[.!]*\s*$",
        "(?mi)^Let me know if you need anything else[.!]*\s*$",
        "(?mi)^Feel free to ask[.!]*\s*$"
    )
    foreach ($p in $patterns) {
        $clean = $clean -replace $p, ""
    }
    return $clean.Trim()
}

# ── Adaptive Timeout ──
function Get-AdaptiveTimeout {
    param(
        [string]$Complexity,
        [int]$DefaultTimeout = 180
    )
    switch ($Complexity) {
        "fast"   { return [Math]::Min($DefaultTimeout, 30) }
        "normal" { return [Math]::Min($DefaultTimeout, 90) }
        "deep"   { return $DefaultTimeout }
        default  { return $DefaultTimeout }
    }
}

# ── Structured Metrics Logging ──
function Write-DelegateMetric {
    param(
        [string]$Stage,         # triage, extract, solve, verify, cache-hit, gc
        [string]$Model = "",
        [string]$Backend = "",
        [int]$LatencyMs = 0,
        [int]$Tokens = 0,
        [string]$Status = "ok", # ok, error, timeout, cache-hit, fallback
        [string]$Domain = "",
        [string]$Extra = ""     # verdict, cache-key, etc.
    )
    try {
        Ensure-DelegateDir $script:DelegateHome
        $entry = [pscustomobject]@{
            ts        = (Get-Date).ToString("o")
            stage     = $Stage
            model     = $Model
            backend   = $Backend
            latencyMs = $LatencyMs
            tokens    = $Tokens
            status    = $Status
            domain    = $Domain
            extra     = $Extra
        }
        $line = ($entry | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine
        Append-Utf8NoBom -Path $script:DelegateMetricsFile -Text $line
    } catch {}
}

# ── Usage Accounting (DEV_CONTRACTS section 2) ──
# Appends one usage record to the global usage.jsonl (mutex Global\DelegatorUsageLog)
# and, when DELEGATOR_USAGE_FILE is set, to the per-request file so the dispatcher
# can aggregate a request without re-reading the global log.
function Write-DelegateUsageRecord {
    param(
        [string]$Stage,             # answer|triage|advisor|synthesis|verify|micro|plan|parallel
        [string]$Mode = "",         # ask|micro|verify|boost|parallel|plan
        [string]$Provider = "",     # gemini|opencode-cli|openrouter|zen
        [string]$Model = "",
        [object]$PromptTokens = $null,
        [object]$CompletionTokens = $null,
        [object]$TotalTokens = $null,
        [object]$Cost = $null,
        [int]$ElapsedMs = 0,
        [bool]$Ok = $true,
        [string]$AccountId = ""
    )
    try {
        $requestId = if ($env:DELEGATOR_REQUEST_ID) { [string]$env:DELEGATOR_REQUEST_ID } else { "" }
        $client = if ($env:DELEGATOR_CLIENT) { [string]$env:DELEGATOR_CLIENT } else { "cli" }
        $entry = [pscustomobject]@{
            ts               = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
            requestId        = $requestId
            client           = $client
            stage            = $Stage
            mode             = $Mode
            provider         = $Provider
            model            = $Model
            promptTokens     = $PromptTokens
            completionTokens = $CompletionTokens
            totalTokens      = $TotalTokens
            cost             = $Cost
            elapsedMs        = $ElapsedMs
            ok               = $Ok
            accountId        = $AccountId
        }
        $line = ($entry | ConvertTo-Json -Depth 4 -Compress) + [Environment]::NewLine

        $mutex = $null
        try {
            Ensure-DelegateDir $script:DelegateHome
            $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorUsageLog")
            $null = $mutex.WaitOne(5000)
            Append-Utf8NoBom -Path $script:DelegateUsageLogFile -Text $line
        } catch {} finally {
            if ($null -ne $mutex) {
                try { $mutex.ReleaseMutex() } catch {}
                $mutex.Dispose()
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_FILE)) {
            try { Append-Utf8NoBom -Path $env:DELEGATOR_USAGE_FILE -Text $line } catch {}
        }
    } catch {}
}

# ── Model Cooldowns (DEV_CONTRACTS section 5) ──
# cooldowns.json is WRITTEN by the provider scripts; the dispatcher only reads it
# so the ranking walk can skip models that are cooling down.
function Get-DelegateCooldowns {
    $mutex = $null
    try {
        if (-not (Test-Path -LiteralPath $script:DelegateCooldownsFile)) { return $null }
        $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorCooldowns")
        $null = $mutex.WaitOne(2000)
        $raw = Get-Content -LiteralPath $script:DelegateCooldownsFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch {
        return $null
    } finally {
        if ($null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }
}

function Test-ModelCoolingDown {
    param(
        [string]$ModelName,
        [object]$Cooldowns = $null
    )
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $false }
    $data = if ($null -ne $Cooldowns) { $Cooldowns } else { Get-DelegateCooldowns }
    if (-not $data -or -not $data.PSObject.Properties["models"] -or -not $data.models) { return $false }
    $row = $data.models.PSObject.Properties[$ModelName]
    if (-not $row -or -not $row.Value -or -not $row.Value.PSObject.Properties["until"]) { return $false }
    try {
        $until = [datetime]::Parse([string]$row.Value.until,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        return ((Get-Date).ToUniversalTime() -lt $until)
    } catch {
        return $false
    }
}

# Filters a ranked candidate list down to models without an active cooldown.
# When every candidate is cooling down (or only one candidate exists) the original
# list is returned unchanged - a model is exempt when it is the only option.
function Select-ActiveRankedModels {
    param([string[]]$Models)
    $list = @(@($Models) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($list.Count -le 1) { return $list }
    $cooldowns = Get-DelegateCooldowns
    if (-not $cooldowns) { return $list }
    $active = @($list | Where-Object { -not (Test-ModelCoolingDown -ModelName ([string]$_) -Cooldowns $cooldowns) })
    if ($active.Count -gt 0) { return $active }
    return $list
}

# ── Garbage Collection ──
$script:GcStateFile = Join-Path $script:DelegateHome "gc-state.json"
$script:GcIntervalHours = 6
$script:GcRetentionHours = 48

function Invoke-DelegateGarbageCollect {
    param(
        [int]$RetentionHours = $script:GcRetentionHours,
        [switch]$Force
    )
    try {
        # Throttle: run at most once per GcIntervalHours
        if (-not $Force -and (Test-Path -LiteralPath $script:GcStateFile)) {
            $gcState = Get-Content -LiteralPath $script:GcStateFile -Raw | ConvertFrom-Json
            if ($gcState.lastRun) {
                $elapsed = ((Get-Date) - [datetime]$gcState.lastRun).TotalHours
                if ($elapsed -lt $script:GcIntervalHours) { return }
            }
        }

        $cutoff = (Get-Date).AddHours(-$RetentionHours)
        $patterns = @(
            "opencode-run-*",
            "opencode-prompt-*",
            "codex-prompt-*",
            "codex-stderr-*",
            "codex-stdout-*",
            "micro-output-*",
            "micro-error-*",
            "micro-prompt-*",
            "prompt-*.txt",
            "usage-req-*",
            "synthesis-*.md",
            "opencode-stderr-*.log",
            "opencode-stdout-*.log"
        )
        $deleted = 0
        foreach ($pattern in $patterns) {
            $files = Get-ChildItem -LiteralPath $script:DelegateHome -Filter $pattern -File -ErrorAction SilentlyContinue
            foreach ($f in $files) {
                if ($f.LastWriteTime -lt $cutoff) {
                    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                    $deleted++
                }
            }
        }

        # Save GC state
        Ensure-DelegateDir $script:DelegateHome
        Write-Utf8NoBom -Path $script:GcStateFile -Text (
            [pscustomobject]@{
                lastRun = (Get-Date).ToString("o")
                deleted = $deleted
            } | ConvertTo-Json -Compress
        )

        if ($deleted -gt 0) {
            Write-DelegateMetric -Stage "gc" -Status "ok" -Extra "deleted=$deleted"
        }

        # ── Log rotation: keep metrics and runs files from growing unbounded ──
        Invoke-DelegateLogRotation
    } catch {}
}

# ── Confidence Heuristics ──
function Test-ResponseConfidence {
    param(
        [string]$Response,
        [string]$Domain,
        [string]$OriginalPrompt
    )
    if ([string]::IsNullOrWhiteSpace($Response)) { return $false }
    if ($Response.Length -lt 20) { return $false }

    # Low-confidence signals
    $lowConfidencePatterns = @(
        "(?i)I'm not sure",
        "(?i)I don't know",
        "(?i)I cannot determine",
        "(?i)I'm unable to",
        "(?i)I apologize.*(cannot|can't|unable)",
        "(?i)insufficient (context|information|data)",
        "(?i)more (context|information|details) (is|are)? needed",
        "(?i)this is (just )?a guess",
        "(?i)I('m| am) not (entirely )?certain"
    )
    foreach ($p in $lowConfidencePatterns) {
        if ($Response -match $p) { return $false }
    }

    # For code tasks: check balanced brackets/braces
    if ($Domain -in @("code_debug", "refactoring", "code_edge_cases", "security")) {
        $codeBlocks = [regex]::Matches($Response, '```[\s\S]*?```')
        foreach ($block in $codeBlocks) {
            $code = $block.Value
            $openBraces = ($code.ToCharArray() | Where-Object { $_ -eq '{' }).Count
            $closeBraces = ($code.ToCharArray() | Where-Object { $_ -eq '}' }).Count
            if ([Math]::Abs($openBraces - $closeBraces) -gt 1) { return $false }

            $openParens = ($code.ToCharArray() | Where-Object { $_ -eq '(' }).Count
            $closeParens = ($code.ToCharArray() | Where-Object { $_ -eq ')' }).Count
            if ([Math]::Abs($openParens - $closeParens) -gt 1) { return $false }
        }
    }

    # Response too short for a complex prompt
    if ($OriginalPrompt.Length -gt 500 -and $Response.Length -lt 100) { return $false }

    return $true
}

# ── Semantic Response Cache ──
$script:CacheMaxEntries = 200
$script:CacheTTLHours = 24
$script:CacheSimilarityThreshold = 0.92
$script:CacheSimilarityThresholdGeneral = 0.88

function Read-ResponseCache {
    if (-not (Test-Path -LiteralPath $script:DelegateCacheFile)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $script:DelegateCacheFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        if ($parsed -is [array]) { return $parsed }
        # Single-object JSON: wrap in array
        if ($parsed.PSObject.Properties["promptHash"]) { return @($parsed) }
        return @()
    } catch { return @() }
}

function Write-ResponseCache {
    param([array]$Entries)
    Ensure-DelegateDir $script:DelegateHome
    # Keep only last N entries
    $trimmed = @($Entries | Select-Object -Last $script:CacheMaxEntries)
    # Force JSON array even for single entry
    $json = if ($trimmed.Count -eq 1) {
        "[" + ($trimmed[0] | ConvertTo-Json -Depth 6 -Compress) + "]"
    } else {
        $trimmed | ConvertTo-Json -Depth 6
    }
    Write-Utf8NoBom -Path $script:DelegateCacheFile -Text $json
}

function Get-PromptHash {
    param([string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text.Trim().ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($bytes)
    return [BitConverter]::ToString($hash).Replace("-", "").Substring(0, 16)
}

function Find-CachedResponse {
    param(
        [string]$PromptHash,
        [string]$Domain
    )
    $cache = Read-ResponseCache
    if ($cache.Count -eq 0) { return $null }

    $cutoff = (Get-Date).AddHours(-$script:CacheTTLHours).ToString("o")
    foreach ($entry in $cache) {
        if ($entry.promptHash -eq $PromptHash -and $entry.timestamp -gt $cutoff) {
            Write-DelegateMetric -Stage "cache-hit" -Model $entry.model -Status "ok" -Domain $Domain -Extra "hash=$PromptHash"
            return $entry.response
        }
    }
    return $null
}

function Add-CachedResponse {
    param(
        [string]$PromptHash,
        [string]$Response,
        [string]$Model,
        [string]$Domain
    )
    if ([string]::IsNullOrWhiteSpace($Response) -or $Response.Length -lt 2) { return }
    $cache = Read-ResponseCache
    # Don't cache duplicate hashes
    $cache = @($cache | Where-Object { $_.promptHash -ne $PromptHash })
    $cache += [pscustomobject]@{
        promptHash = $PromptHash
        response   = $Response
        model      = $Model
        domain     = $Domain
        timestamp  = (Get-Date).ToString("o")
    }
    Write-ResponseCache $cache
}

# ── Dynamic Profiles Discovery ──
function Get-ProfilesCount {
    if (-not (Test-Path -LiteralPath $script:DelegatorAppConfigFile)) { return 1 }
    try {
        $config = Get-Content -LiteralPath $script:DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $count = @($config.google_accounts | Where-Object {
            $null -ne $_ -and
            -not [string]::IsNullOrWhiteSpace([string]$_.api_key_enc) -and
            ($null -eq $_.enabled -or [bool]$_.enabled)
        }).Count
        return [Math]::Max(1, $count)
    } catch {
        return 1
    }
}

# ── Response Quality Gate ──
function Test-ResponseQuality {
    param(
        [string]$Response,
        [string]$OriginalPrompt = ""
    )
    # Returns: "ok", "empty", "truncated", "refusal", "too-short"
    if ([string]::IsNullOrWhiteSpace($Response)) { return "empty" }
    if ($Response.Length -lt 10 -and $OriginalPrompt.Length -gt 100) { return "too-short" }

    # Refusal patterns
    $refusalPatterns = @(
        '(?i)^\s*I\s+(cannot|can''t|am unable|''m unable)',
        '(?i)^\s*As an AI',
        '(?i)^\s*I\s+apologize.{0,30}(cannot|can''t|unable)',
        '(?i)^\s*Sorry.{0,20}(cannot|can''t|unable|not able)',
        '(?i)^\s*I don''t have (access|the ability|enough)'
    )
    foreach ($p in $refusalPatterns) {
        if ($Response -match $p) { return "refusal" }
    }

    # Truncation: response ends mid-word (no terminal punctuation or code block end)
    $trimmed = $Response.TrimEnd()
    if ($trimmed.Length -gt 200) {
        $lastChar = $trimmed[-1]
        $terminalChars = '.', '!', '?', '`', '}', ')', ']', '"', "'", ';', ':', '*', '-'
        $endsClean = $terminalChars -contains $lastChar
        if (-not $endsClean) {
            # Check for unmatched code fences
            $fenceCount = ([regex]::Matches($trimmed, '```')).Count
            if ($fenceCount % 2 -ne 0) { return "truncated" }
        }
    }

    return "ok"
}

# ── Retryable Error Detection ──
function Test-RetryableError {
    param([string]$Output, [int]$ExitCode)
    if ($ExitCode -eq 0) { return $false }
    if ([string]::IsNullOrWhiteSpace($Output)) { return $true }
    $retryPatterns = @(
        'rate_limit', '429', '503', 'RESOURCE_EXHAUSTED',
        'temporarily unavailable', 'server error', 'internal error',
        'capacity', 'overloaded', 'too many requests',
        'All Gemini profiles failed', 'All models failed',
        'connection reset', 'timeout', 'ETIMEDOUT', 'ECONNRESET'
    )
    foreach ($p in $retryPatterns) {
        if ($Output -match [regex]::Escape($p)) { return $true }
    }
    return $false
}

# ── Get Next Ranked Model (for retry with different model) ──
function Get-NextRankedModel {
    param(
        [string]$CurrentModel,
        [string]$Domain = "universal"
    )
    $rankings = Read-ModelRankings
    if (-not $rankings -or -not $rankings.overall) { return "" }
    $rows = @($rankings.overall)
    $cooldowns = Get-DelegateCooldowns
    $found = $false
    foreach ($row in $rows) {
        $m = [string]$row.model
        if ($m -eq $CurrentModel) { $found = $true; continue }
        if ($found -and -not [string]::IsNullOrWhiteSpace($m) -and
            -not (Model-HasDomainSetting $m "avoidDomains" $Domain) -and
            -not (Test-ModelCoolingDown -ModelName $m -Cooldowns $cooldowns)) {
            return $m
        }
    }
    # Wrap around to first model if current was last
    foreach ($row in $rows) {
        $m = [string]$row.model
        if ($m -ne $CurrentModel -and -not [string]::IsNullOrWhiteSpace($m)) { return $m }
    }
    return ""
}

# ── Log Rotation ──
function Invoke-DelegateLogRotation {
    param(
        [int]$MetricsMaxLines = 2000,
        [int]$RunsMaxLines = 500
    )
    try {
        foreach ($entry in @(
            @{ Path = $script:DelegateMetricsFile; Max = $MetricsMaxLines },
            @{ Path = $script:DelegateRunsFile; Max = $RunsMaxLines }
        )) {
            if (-not (Test-Path -LiteralPath $entry.Path)) { continue }
            $lines = @(Get-Content -LiteralPath $entry.Path -ErrorAction SilentlyContinue)
            if ($lines.Count -gt ($entry.Max * 1.5)) {
                $keep = $lines | Select-Object -Last $entry.Max
                $keep | Set-Content -LiteralPath $entry.Path -Encoding UTF8
            }
        }

        # Clean stale .codex tmp files
        $codexHome = Join-Path $env:USERPROFILE ".codex"
        $cutoff = (Get-Date).AddHours(-48)
        Get-ChildItem -LiteralPath $codexHome -Filter "..codex-global-state.json.tmp-*" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    } catch {}
}

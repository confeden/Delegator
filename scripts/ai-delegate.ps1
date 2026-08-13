param(
    [Parameter(Position = 0)]
    [ValidateSet("ask", "delegate", "boost", "improve", "micro", "verify", "plan", "parallel", "ui", "status", "models", "policy", "triage", "extract", "usage")]
    [string]$Command = "ask",

    [Parameter(Position = 1)]
    [Alias("Prompts")]
    [string]$PromptArg,

    [ValidateSet("auto", "fast", "normal", "deep")]
    [string]$Complexity = "auto",

    [ValidateSet("auto", "gemini", "opencode")]
    [string]$Backend = "auto",

    [string]$Model,
    [int]$TimeoutSec = 180,
    [switch]$Json,
    [switch]$Boost,
    [switch]$NoBoost,
    [switch]$NoPlanner,
    [switch]$Async,
    [switch]$NoDiverseModels,
    [switch]$DiffOnly,

    # UTF-8 text file(s) containing the full prompt (DEV_CONTRACTS section 1).
    # Precedence: -PromptFile > stdin > positional prompt. For `parallel`, several
    # files may be passed: array binding in-process, or a semicolon-separated list
    # from the command line (-PromptFile "a.txt;b.txt") - powershell -File cannot
    # bind the same named parameter twice.
    [string[]]$PromptFile,

    # `improve`: the answer the CALLER already produced and wants checked.
    # UTF-8 file, same transport rule as -PromptFile (DEV_CONTRACTS section 1).
    [string]$DraftFile,

    # `improve`: source files / logs the reviewer should look at, semicolon
    # separated ("a.rs;b.rs"). Trimmed to a budget, see Read-ContextFiles.
    [string[]]$ContextFile,

    # Window for the `usage` subcommand summary.
    [int]$Days = 7,

    # Hidden diagnostic: print the resolved prompt(s) and exit 0 (transport tests).
    [switch]$EchoPrompt,

    # Extra positional prompts (parallel mode) and legacy `--flag` tokens from
    # in-process callers; both are consumed by the re-parser below.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs
)

$ErrorActionPreference = "Stop"

# ── Load shared module ──
. (Join-Path $PSScriptRoot "delegator-common.ps1")
$Utf8NoBom = Initialize-DelegateEncoding

# ── Run garbage collection (throttled) ──
Invoke-DelegateGarbageCollect

$BinHome = $script:DelegateBinHome
$GeminiDelegate = Join-Path $BinHome "gemini-delegate.ps1"
$OpenCodeDelegate = Join-Path $BinHome "opencode-delegate.ps1"
$DelegatePlanner = Join-Path $BinHome "ai-delegate-plan.ps1"
$ParallelDelegate = Join-Path $BinHome "ai-delegate-parallel.ps1"
$MicroDelegate = Join-Path $BinHome "ai-delegate-micro.ps1"
$RankingFile = $script:DelegateRankingFile
$ModelSettingsFile = $script:DelegateModelSettingsFile
$PolicyFile = $script:DelegatePolicyFile
$rawPrompts = @($PromptArg) + @($RemainingArgs)
$cleanPrompts = [System.Collections.Generic.List[string]]::new()
$promptFileList = [System.Collections.Generic.List[string]]::new()
foreach ($pf in @($PromptFile)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$pf)) { $promptFileList.Add([string]$pf) }
}
for ($i = 0; $i -lt $rawPrompts.Count; $i++) {
    $token = [string]$rawPrompts[$i]
    if ($null -eq $token) { continue }
    switch ($token.ToLowerInvariant()) {
        "--complexity" { if ($i + 1 -lt $rawPrompts.Count) { $Complexity = [string]$rawPrompts[++$i] }; continue }
        "--backend" { if ($i + 1 -lt $rawPrompts.Count) { $Backend = [string]$rawPrompts[++$i] }; continue }
        "--model" { if ($i + 1 -lt $rawPrompts.Count) { $Model = [string]$rawPrompts[++$i] }; continue }
        "--timeoutsec" { if ($i + 1 -lt $rawPrompts.Count) { $TimeoutSec = [int]$rawPrompts[++$i] }; continue }
        "--promptfile" { if ($i + 1 -lt $rawPrompts.Count) { $promptFileList.Add([string]$rawPrompts[++$i]) }; continue }
        "--days" { if ($i + 1 -lt $rawPrompts.Count) { $Days = [int]$rawPrompts[++$i] }; continue }
        "--json" { $Json = $true; continue }
        "--boost" { $Boost = $true; continue }
        "--noboost" { $NoBoost = $true; continue }
        "--noplanner" { $NoPlanner = $true; continue }
        "--async" { $Async = $true; continue }
        "--nodiversemodels" { $NoDiverseModels = $true; continue }
        "--diffonly" { $DiffOnly = $true; continue }
        "--echoprompt" { $EchoPrompt = $true; continue }
        default { if (-not [string]::IsNullOrWhiteSpace($token)) { $cleanPrompts.Add($token) } }
    }
}
$Prompts = @($cleanPrompts)

# ── -PromptFile transport (DEV_CONTRACTS section 1) ──
# File prompts take precedence over stdin and positional prompts. Files are
# caller-owned (the caller deletes them); they are read as UTF-8. Each entry may
# be a semicolon-separated list so external callers can pass several files.
$filePrompts = @()
foreach ($entry in $promptFileList) {
    foreach ($pfPiece in ([string]$entry).Split(";")) {
        $pf = $pfPiece.Trim()
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        if (-not (Test-Path -LiteralPath $pf)) { throw "Prompt file not found: $pf" }
        $filePrompts += ,([System.IO.File]::ReadAllText($pf, [System.Text.UTF8Encoding]::new($false)))
    }
}
if ($filePrompts.Count -gt 0) {
    $Prompts = @($filePrompts) + @($Prompts)
}
$Prompt = if ($Prompts.Count -gt 0) { [string]$Prompts[0] } else { "" }

if ($EchoPrompt) {
    foreach ($p in $Prompts) {
        Write-Output "--- PROMPT ---"
        Write-Output ([string]$p)
    }
    exit 0
}

# ── Per-request usage accounting env (DEV_CONTRACTS section 2.2) ──
# The top-most dispatcher instance owns the request: it generates the request id,
# creates the per-request usage file that all children append to, aggregates it at
# the end and deletes it. Nested instances (boost advisors, parallel workers) see
# DELEGATOR_USAGE_FILE already set and only append.
$script:RequestStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:FinalModel = ""
$script:FinalProvider = ""
$script:FinalExitCode = $null
$script:LastParallelExitCode = 0
$script:UsageOwner = $false
if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_REQUEST_ID)) {
    $env:DELEGATOR_REQUEST_ID = "r-" + [Guid]::NewGuid().ToString("n").Substring(0, 8)
}
if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_CLIENT)) { $env:DELEGATOR_CLIENT = "cli" }
if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_FILE)) {
    try { Ensure-DelegateDir $script:DelegateHome } catch {}
    $env:DELEGATOR_USAGE_FILE = Join-Path $script:DelegateHome ("usage-req-" + $env:DELEGATOR_REQUEST_ID + "-" + [Guid]::NewGuid().ToString("n").Substring(0, 6) + ".jsonl")
    $script:UsageOwner = $true
}
$script:DelegateRequestId = $env:DELEGATOR_REQUEST_ID

# Get-TaskDomain, Test-VisionContent, Test-ModelSupportsVision, Get-ModelSettingValue,
# Model-HasDomainSetting, Read-ModelRankings, Read-ModelSettings, Get-PreferredOutputLanguage,
# Add-ExecutionLanguagePolicy, Filter-ConversationalNoise are now in delegator-common.ps1

# Legacy tie-break order for triage/extract picks (used only between models of
# equal catalog strength). Only models enabled in the GUI config are ever used;
# when nothing is enabled the caller must skip the stage cleanly instead of
# spawning a doomed subprocess.
$script:TriageModelPreference = @(
    "opencode/deepseek-v4-flash-free",
    "opencode/ling-3.0-tiny-free",
    "opencode/mimo-v2.5-free"
)

function Get-ZenCatalogStrengthMap {
    # <RT>\opencode-zen-catalog.json - written by update-free-models.ps1 and kept
    # fresh by opencode-delegate.ps1. Read-only here: maps live zen id -> strength.
    $map = @{}
    $catalogFile = Join-Path $script:DelegateHome "opencode-zen-catalog.json"
    if (-not (Test-Path -LiteralPath $catalogFile)) { return $map }
    try {
        $catalog = Get-Content -LiteralPath $catalogFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($row in @($catalog.models)) {
            $id = ([string]$row.id).Trim()
            if ($id -match '^opencode/[0-9A-Za-z._-]+$') { $map[$id] = [int]$row.strength }
        }
    } catch {}
    return $map
}

function Get-FastEnabledOpenCodeModel {
    # Internal plumbing (triage/extract) deliberately runs on the WEAKEST enabled
    # model (strength ASC from the Zen catalog, absent -> 50): cheap models for
    # plumbing, strong models for user-facing answers. opencode/* ids the live
    # catalog no longer lists are dropped unless that would leave nothing.
    $enabled = @(Get-DelegatorEnabledModels "enabled_opencode_models")
    if ($enabled.Count -eq 0) { return "" }
    $strengths = Get-ZenCatalogStrengthMap
    if ($strengths.Count -gt 0) {
        $live = @($enabled | Where-Object { $_ -notlike "opencode/*" -or $strengths.ContainsKey($_) })
        if ($live.Count -gt 0) { $enabled = $live }
    }
    $ordered = @()
    foreach ($candidate in $script:TriageModelPreference) {
        if ($enabled -contains $candidate) { $ordered += $candidate }
    }
    foreach ($candidate in $enabled) {
        if ($ordered -notcontains $candidate) { $ordered += $candidate }
    }
    $tieBreak = @{}
    for ($i = 0; $i -lt $ordered.Count; $i++) { $tieBreak[[string]$ordered[$i]] = $i }
    $ordered = @($ordered | Sort-Object `
        @{ Expression = { if ($strengths.ContainsKey($_)) { [int]$strengths[$_] } else { 50 } } }, `
        @{ Expression = { [int]$tieBreak[[string]$_] } })
    $ordered = @(Select-ActiveRankedModels $ordered)
    if ($ordered.Count -gt 0) { return [string]$ordered[0] }
    return ""
}

function Get-ModelLatencyStats {
    # Recent per-model behaviour from <RT>\usage.jsonl, in call order. Read
    # without the usage mutex on purpose - the file is append-only and a torn
    # last line is simply skipped; blocking a routing decision on a writer would
    # be worse than losing one sample.
    if ($null -ne $script:ModelLatencyStats) { return $script:ModelLatencyStats }
    $stats = @{}
    $usageFile = Join-Path $script:DelegateHome "usage.jsonl"
    if (-not (Test-Path -LiteralPath $usageFile)) {
        $script:ModelLatencyStats = $stats
        return $stats
    }
    try {
        $lines = @([System.IO.File]::ReadAllLines($usageFile))
        if ($lines.Count -gt 400) { $lines = @($lines[($lines.Count - 400)..($lines.Count - 1)]) }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $null
            try { $row = $line | ConvertFrom-Json } catch { continue }
            $id = [string]$row.model
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $isOk = $true
            try { if ($row.PSObject.Properties["ok"] -and $null -ne $row.ok) { $isOk = [bool]$row.ok } } catch {}
            $ms = 0
            [void][int]::TryParse([string]$row.elapsedMs, [ref]$ms)
            if (-not $stats.ContainsKey($id)) { $stats[$id] = @() }
            $stats[$id] += ,([pscustomobject]@{ ok = $isOk; ms = $ms })
        }
    } catch {}
    $script:ModelLatencyStats = $stats
    return $stats
}

function Get-ModelHealth {
    # Verdict over the last MODEL_HEALTH_WINDOW calls of one model:
    # how often it failed, and how slow it is when it does answer (p75, because
    # the tail is what runs into the timeout - a median hides exactly the runs
    # that get killed).
    param([string]$ModelId)
    $window = 12
    $stats = Get-ModelLatencyStats
    $health = [pscustomobject]@{ samples = 0; failRate = 0.0; p75Ms = $null }
    if (-not $stats.ContainsKey($ModelId)) { return $health }
    $rows = @($stats[$ModelId])
    if ($rows.Count -gt $window) { $rows = @($rows[($rows.Count - $window)..($rows.Count - 1)]) }
    if ($rows.Count -eq 0) { return $health }
    $failed = @($rows | Where-Object { -not $_.ok }).Count
    $durations = @($rows | Where-Object { $_.ok -and [int]$_.ms -gt 0 } | ForEach-Object { [int]$_.ms } | Sort-Object)
    $health.samples = $rows.Count
    $health.failRate = [double]$failed / [double]$rows.Count
    if ($durations.Count -gt 0) {
        $index = [int][Math]::Ceiling(0.75 * $durations.Count) - 1
        if ($index -lt 0) { $index = 0 }
        if ($index -ge $durations.Count) { $index = $durations.Count - 1 }
        $health.p75Ms = [int]$durations[$index]
    }
    return $health
}

function Test-ModelAffordable {
    # "Strongest" is worthless if the caller never gets the answer. Nothing known
    # about a model means "try it" (a fresh install must still reach for the best
    # one); the routing then demotes it by itself as soon as its own record says
    # it is too slow or fails too often.
    #
    # Measured here 2026-08-12: nemotron-3-ultra needed 175s for a trivial Python
    # question and failed 6 of its last 10 calls, while deepseek-v4-flash answered
    # the same question in 7s. A pure strength ranking routed every delegation
    # into a timeout and then into a flash-class fallback - slower AND weaker.
    param([string]$ModelId, [int]$BudgetMs)
    $health = Get-ModelHealth $ModelId
    if ($health.samples -eq 0) { return $true }
    if ($health.samples -ge 4 -and $health.failRate -ge 0.4) { return $false }
    if ($null -eq $health.p75Ms) { return ($health.failRate -lt 0.5) }
    return ([int]$health.p75Ms -le $BudgetMs)
}

function Get-ModelLatencyRank {
    # Sort key for "least bad" when every candidate is unaffordable.
    param([string]$ModelId)
    $health = Get-ModelHealth $ModelId
    if ($null -eq $health.p75Ms) { return [int]::MaxValue }
    return [int]$health.p75Ms
}

function Get-LatencyBudgetMs {
    if ($env:CODEX_DELEGATE_LATENCY_BUDGET_MS) {
        $parsed = 0
        if ([int]::TryParse([string]$env:CODEX_DELEGATE_LATENCY_BUDGET_MS, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    }
    return 100000
}

function Get-ModelStrengthScore {
    # Strength of one model id: the Zen catalog when it exists, otherwise the
    # same name heuristic the catalog itself is built from. The catalog is only
    # written on the first non-dot-sourced run of opencode-delegate.ps1, so on a
    # cold install it is missing - and without this fallback every candidate
    # scored a flat 50 and the tie-break picked ALPHABETICALLY (big-pickle before
    # nemotron-3-ultra), which is exactly the case this floor exists for.
    #
    # FOURTH copy of the heuristic (update-free-models.ps1, opencode-delegate.ps1,
    # src/gui/opencode_setup.rs are the others) - change them together.
    param([string]$ModelId, [hashtable]$Catalog)
    if ($Catalog -and $Catalog.ContainsKey($ModelId)) { return [int]$Catalog[$ModelId] }
    $name = ([string]$ModelId).ToLowerInvariant()
    $score = 50
    if ($name -match "ultra") { $score += 40 }
    elseif ($name -match "pro|max") { $score += 30 }
    elseif ($name -match "large|big") { $score += 20 }
    elseif ($name -match "flash|standard") { $score += 10 }
    if ($name -match "mini") { $score -= 20 }
    if ($name -match "tiny|nano|lite") { $score -= 30 }
    $version = [regex]::Match($name, "[1-9]")
    if ($version.Success) { $score += [int]$version.Value }
    return $score
}

function Get-StrongEnabledModel {
    # Mirror image of Get-FastEnabledOpenCodeModel: user-facing answers, the
    # fusion judge and the critic run on the STRONGEST enabled model (strength
    # DESC from the Zen catalog, absent -> 50).
    #
    # Why this exists: <RT>\model-rankings.json does not ship and is absent on a
    # normal install, so Select-RankedDelegateModel returns "" and the backend
    # then answers with its own default, which is a flash-class model. A weak
    # IDE agent would be delegating to an equally weak model - the delegation
    # buys nothing. This is the floor under that path.
    param([string[]]$Exclude = @())
    $enabled = @(Get-DelegatorEnabledModels "enabled_opencode_models")
    if ($Exclude.Count -gt 0) { $enabled = @($enabled | Where-Object { $Exclude -notcontains $_ }) }
    if ($enabled.Count -eq 0) { return "" }
    $strengths = Get-ZenCatalogStrengthMap
    if ($strengths.Count -gt 0) {
        $live = @($enabled | Where-Object { $_ -notlike "opencode/*" -or $strengths.ContainsKey($_) })
        if ($live.Count -gt 0) { $enabled = $live }
    }
    $ordered = @($enabled | Sort-Object `
        @{ Expression = { Get-ModelStrengthScore -ModelId $_ -Catalog $strengths }; Descending = $true }, `
        @{ Expression = { [string]$_ }; Descending = $false })
    $ordered = @(Select-ActiveRankedModels $ordered)
    if ($ordered.Count -eq 0) { return "" }

    # Strength decides the order, measured latency decides what is reachable.
    $budget = Get-LatencyBudgetMs
    $affordable = @($ordered | Where-Object { Test-ModelAffordable -ModelId $_ -BudgetMs $budget })
    if ($affordable.Count -gt 0) { return [string]$affordable[0] }

    # Every candidate is known to be too slow: take the least slow one rather
    # than the strongest, so the caller gets an answer at all.
    $fastest = @($ordered | Sort-Object @{ Expression = { Get-ModelLatencyRank $_ } })
    return [string]$fastest[0]
}

function Get-TriageModel {
    param([string]$Text)
    if (Test-VisionContent $Text) { return "gemini-flash-latest" }
    return Get-FastEnabledOpenCodeModel
}

function Get-ExtractModel {
    param([string]$Text)
    if (Test-VisionContent $Text) { return "gemini-flash-latest" }
    return Get-FastEnabledOpenCodeModel
}

# Read-ModelRankings, Read-ModelSettings, Model-HasDomainSetting → delegator-common.ps1

# Get-ModelSettingValue, Test-VisionContent, Get-PreferredOutputLanguage → delegator-common.ps1

# Add-ExecutionLanguagePolicy, Test-ModelSupportsVision → delegator-common.ps1

function Get-PreferredVisionModel {
    $rankings = Read-ModelRankings
    if ($rankings -and $rankings.overall) {
        $visionCandidates = @()
        foreach ($row in @($rankings.overall)) {
            $m = [string]$row.model
            if (Test-ModelSupportsVision $m) { $visionCandidates += $m }
        }
        $visionCandidates = @(Select-ActiveRankedModels $visionCandidates)
        if ($visionCandidates.Count -gt 0) { return [string]$visionCandidates[0] }
    }
    return "gemini-pro-latest"
}

function Test-ModelMatchesBackend {
    param([string]$ModelName, [string]$BackendName)
    if ([string]::IsNullOrWhiteSpace($ModelName) -or [string]::IsNullOrWhiteSpace($BackendName) -or $BackendName -eq "auto") { return $true }
    if ($BackendName -eq "opencode") {
        return ($ModelName -like "google/gemma*" -or $ModelName -like "opencode/*" -or $ModelName -like "openrouter/*")
    }
    if ($BackendName -eq "gemini") {
        return ($ModelName -like "gemini-*")
    }
    if ($BackendName -eq "puter") {
        return ($ModelName -like "moonshotai/kimi-*")
    }
    if ($BackendName -eq "capy") {
        return ($ModelName -like "capy/*")
    }
    return $true
}

function Get-DelegatorEnabledModels {
    param([string]$PropertyName)
    if (-not (Test-Path -LiteralPath $script:DelegatorAppConfigFile)) { return @() }
    try {
        $config = Get-Content -LiteralPath $script:DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $config.PSObject.Properties[$PropertyName]) { return @() }
        return @($config.PSObject.Properties[$PropertyName].Value | ForEach-Object {
            ([string]$_).Trim()
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    } catch {
        return @()
    }
}

function Get-PreferredBackendModel {
    param([string]$BackendName, [string]$Text)
    if ($BackendName -eq "gemini") {
        $enabledGemini = @(Get-DelegatorEnabledModels "enabled_gemini_models")
        $order = if ($Text.Length -gt 4000 -or $Text -match "architecture|security|debug|root cause|migration|refactor") {
            @("gemini-pro-latest", "gemini-flash-latest", "gemini-flash-lite-latest")
        } else {
            @("gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest")
        }
        $selectedGemini = @(Select-ActiveRankedModels @($order | Where-Object { $enabledGemini -contains $_ }))
        if ($selectedGemini.Count -gt 0) { return [string]$selectedGemini[0] }
        return ""
    }
    $enabledForBackend = if ($BackendName -eq "opencode") {
        @(Get-DelegatorEnabledModels "enabled_opencode_models")
    } else {
        @()
    }
    $rankings = Read-ModelRankings
    if (-not $rankings -or -not $rankings.overall) {
        if ($BackendName -eq "opencode") { return "opencode/deepseek-v4-flash-free" }
        if ($BackendName -eq "puter") { return "moonshotai/kimi-k2.6" }
        return ""
    }
    $domain = Get-TaskDomain $Text
    $rows = @()
    if ($rankings.domains -and $rankings.domains.PSObject.Properties[$domain]) {
        $rows = @($rankings.domains.$domain)
    }
    if (-not $rows -or $rows.Count -eq 0) { $rows = @($rankings.overall) }
    $domainCandidates = @()
    foreach ($row in @($rows)) {
        $m = [string]$row.model
        if ((Test-ModelMatchesBackend $m $BackendName) -and
            ($enabledForBackend.Count -eq 0 -or $enabledForBackend -contains $m) -and
            -not (Model-HasDomainSetting $m "avoidDomains" $domain)) { $domainCandidates += $m }
    }
    $domainCandidates = @(Select-ActiveRankedModels $domainCandidates)
    if ($domainCandidates.Count -gt 0) { return [string]$domainCandidates[0] }
    $overallCandidates = @()
    foreach ($row in @($rankings.overall)) {
        $m = [string]$row.model
        if ((Test-ModelMatchesBackend $m $BackendName) -and
            ($enabledForBackend.Count -eq 0 -or $enabledForBackend -contains $m)) { $overallCandidates += $m }
    }
    $overallCandidates = @(Select-ActiveRankedModels $overallCandidates)
    if ($overallCandidates.Count -gt 0) { return [string]$overallCandidates[0] }
    return ""
}

function Get-LockName {
    param([string]$BackendName, [string]$ModelName)
    $raw = ("CodexDelegateModel_" + $BackendName + "_" + $ModelName)
    $safe = ($raw -replace '[^A-Za-z0-9_]+', '_')
    if ($safe.Length -gt 180) { $safe = $safe.Substring(0, 180) }
    return "Global\" + $safe
}

function Invoke-WithModelLock {
    param([string]$BackendName, [string]$ModelName, [scriptblock]$Body)
    if ($env:CODEX_DELEGATE_MODEL_LOCK -eq "0") { return & $Body }
    $lockModel = if ([string]::IsNullOrWhiteSpace($ModelName)) { "auto" } else { $ModelName }
    
    # Dynamically determine slots count based on available profiles (for Gemini)
    $slotsCount = 1
    if ($BackendName -eq "gemini") {
        $slotsCount = Get-ProfilesCount
    }
    
    $mutex = $null
    $locked = $false
    $started = [System.Diagnostics.Stopwatch]::StartNew()
    $waitMs = [Math]::Max(30000, ([int]$TimeoutSec + 60) * 1000)
    
    while ($started.ElapsedMilliseconds -lt $waitMs) {
        for ($slot = 0; $slot -lt $slotsCount; $slot++) {
            $lockName = (Get-LockName $BackendName $lockModel) + "_Slot_" + $slot
            $tempMutex = [System.Threading.Mutex]::new($false, $lockName)
            try {
                if ($tempMutex.WaitOne(0)) {
                    $mutex = $tempMutex
                    $locked = $true
                    break
                }
            } catch {}
            $tempMutex.Dispose()
        }
        if ($locked) { break }
        Start-Sleep -Milliseconds 100
    }
    
    try {
        if (-not $locked) {
            [Console]::Error.WriteLine("[Delegator] WARNING: Mutex lock timed out for $BackendName/$lockModel (Slots: $slotsCount). Running without lock.")
            Write-DelegateMetric -Stage "mutex-timeout" -Backend $BackendName -Model $lockModel -Status "warn" -Extra "slots=$slotsCount"
        }
        return & $Body
    } finally {
        if ($locked -and $null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }
}

function Select-RankedDelegateModel {
    param([string]$Text)
    if (-not [string]::IsNullOrWhiteSpace($Model)) { return $Model }
    if (Test-VisionContent $Text) { return Get-PreferredVisionModel }
    $rankings = Read-ModelRankings
    if (-not $rankings) { return "" }
    $domain = Get-TaskDomain $Text
    $rows = @()
    if ($rankings.domains -and $rankings.domains.PSObject.Properties[$domain]) {
        $rows = @($rankings.domains.$domain)
    }
    if (-not $rows -or $rows.Count -eq 0) {
        $rows = @($rankings.overall)
    }
    
    # Use actual rankings instead of hardcoded score injections;
    # latest aliases already present in rankings if benchmarked.
    $sortedRows = @($rows) | Sort-Object {
        if ($_.PSObject.Properties["score"]) { [int]$_.score } elseif ($_.PSObject.Properties["weightedScore"]) { [int]$_.weightedScore } elseif ($_.PSObject.Properties["totalScore"]) { [int]$_.totalScore } else { 0 }
    } -Descending

    $eligible = @($sortedRows | Where-Object {
        $points = if ($_.PSObject.Properties["score"]) { [int]$_.score } elseif ($_.PSObject.Properties["weightedScore"]) { [int]$_.weightedScore } elseif ($_.PSObject.Properties["totalScore"]) { [int]$_.totalScore } else { 0 }
        $points -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.model) -and -not (Model-HasDomainSetting ([string]$_.model) "avoidDomains" $domain)
    } | ForEach-Object { [string]$_.model })
    $eligible = @(Select-ActiveRankedModels $eligible)
    if ($eligible.Count -gt 0) { return [string]$eligible[0] }
    return ""
}

function Select-Backend {
    param([string]$Text, [string]$ChosenModel = "")
    if ($Backend -ne "auto") { return $Backend }
    if (Test-VisionContent $Text) { return "gemini" }
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($ChosenModel)) { $ChosenModel } else { $Model }
    if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) {
        # ANY provider-prefixed id goes through the OpenCode CLI - that is what
        # serves opencode/*, openrouter/* and every provider the user added to
        # their own config (agentrouter/..., ornith/..., a local gemma). Only a
        # bare `gemini-*` name is a direct Google call. Before this, a custom id
        # fell through to the gemini backend and could never work.
        if ($effectiveModel -like "gemini-*") { return "gemini" }
        if ($effectiveModel -like "*/*") { return "opencode" }
        return "gemini"
    }
    # Default backend is gemini for prioritizing Gemini models over OpenCode/Deepseek
    return "gemini"
}

function Invoke-Delegate {
    param(
        [string]$ChosenBackend,
        [string]$Text,
        [string]$ChosenModel = "",
        [string]$EffectiveComplexity = ""
    )

    $cx = if (-not [string]::IsNullOrWhiteSpace($EffectiveComplexity)) { $EffectiveComplexity } else { $Complexity }
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($ChosenModel)) { $ChosenModel } else { $Model }
    $delegateParams = @{ Command = "ask"; Prompt = $Text; Complexity = $cx; TimeoutSec = $TimeoutSec }
    if ($Json) { $delegateParams.Json = $true }
    if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) { $delegateParams.Model = $effectiveModel }

    # $LASTEXITCODE is process-wide state, not a return value: it survives from
    # the last external command this session ran. Clear it before the call so a
    # provider that answers fine cannot inherit a stale non-zero code (the
    # providers now `exit 0` explicitly, this is the second lock on that door).
    if ($ChosenBackend -eq "opencode") {
        return Invoke-WithModelLock -BackendName "opencode" -ModelName $effectiveModel -Body {
            try {
                $global:LASTEXITCODE = 0
                $output = & $OpenCodeDelegate @delegateParams 2>&1
                $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
                return [pscustomobject]@{ exitCode = $code; output = $output }
            } catch {
                return [pscustomobject]@{ exitCode = 1; output = @($_.Exception.Message) }
            }
        }
    }

    return Invoke-WithModelLock -BackendName "gemini" -ModelName $effectiveModel -Body {
        try {
            $global:LASTEXITCODE = 0
            $output = & $GeminiDelegate @delegateParams 2>&1
            $code = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
            return [pscustomobject]@{ exitCode = $code; output = $output }
        } catch {
            return [pscustomobject]@{ exitCode = 1; output = @($_.Exception.Message) }
        }
    }
}

function Get-GeminiModelScore {
    <#
      Ranks a Google model id. Higher is stronger.

      Two rules, both from measurement rather than taste:
      * GENERATION dominates tier. The owner measured `gemini-3.7-flash` as
        stronger than what `gemini-pro-latest` resolves to today (3.1 Pro), so
        a newer flash outranks an older pro.
      * An explicitly VERSIONED id outranks a `-latest` alias of the same tier.
        An alias is a moving target we cannot rank: `pro-latest` is still 3.1
        Pro while 3.7 Flash ships as its own id, so trusting the alias to be
        "the newest" would pick the weaker model.
    #>
    param([string]$ModelId)

    $id = ([string]$ModelId).ToLowerInvariant()
    $tier = if ($id -match "flash-?lite" -or $id -match "lite") { 1 }
            elseif ($id -match "pro") { 3 }
            else { 2 }
    $generation = 0.0
    if ($id -match "gemini-(\d+(?:\.\d+)?)") { $generation = [double]$Matches[1] }
    if ($generation -le 0) { return $tier * 3 }   # alias: tier only, ranks last
    return [int]([math]::Round($generation * 10)) + $tier * 3
}

function Get-EnabledGeminiModelsByStrength {
    # Enabled Google models, strongest first, cooldown-aware.
    #
    # Returns a LIST, not one model, because Google meters each model
    # separately: measured live 2026-08-13, `gemini-pro-latest` answered 429
    # while the key itself was healthy and flash still had quota. A fallback
    # that tries only the strongest one fails exactly when it is needed most.
    param([string[]]$Exclude = @())
    $enabled = @(Get-DelegatorEnabledModels "enabled_gemini_models")
    if ($Exclude.Count -gt 0) { $enabled = @($enabled | Where-Object { $Exclude -notcontains $_ }) }
    if ($enabled.Count -eq 0) { return @() }
    $ranked = @($enabled | Sort-Object `
        @{ Expression = { Get-GeminiModelScore $_ }; Descending = $true }, `
        @{ Expression = { [string]$_ }; Descending = $false })
    # Not-cooling first, but a cooling model still stays in the list: it may be
    # the only one left, and the provider re-checks the cooldown itself.
    $active = @(Select-ActiveRankedModels $ranked)
    $rest = @($ranked | Where-Object { $active -notcontains $_ })
    return @($active + $rest)
}

# OpenRouter's "auto free" route: it picks whatever free model is available, so
# it keeps answering when every metered model is out of quota. Mirrors
# config.rs UNIVERSAL_FREE_MODEL - change both together.
$script:UniversalFreeModel = "openrouter/openrouter/free"

function Get-UniversalFreeModel {
    # Only if the GUI has it enabled: the allowlist is mandatory (CONTRIBUTING),
    # and the v9->v10 migration is what puts it there.
    $enabled = @(Get-DelegatorEnabledModels "enabled_opencode_models")
    if ($enabled -contains $script:UniversalFreeModel) { return $script:UniversalFreeModel }
    return ""
}

function Get-StrongEnabledGeminiModel {
    param([string[]]$Exclude = @())
    $models = @(Get-EnabledGeminiModelsByStrength -Exclude $Exclude)
    if ($models.Count -gt 0) { return [string]$models[0] }
    return ""
}

function Get-CustomProviderModels {
    <#
      Enabled models from a provider the USER added to their OpenCode config
      (agentrouter/..., a local gemma, ...). Everything with a `/` that is not
      one of the providers OpenCode ships with.

      Owner's rule 2026-08-13: their own providers come first, because the only
      reason to configure one is to use it.
    #>
    $builtIn = @("opencode", "openrouter", "google", "google-vertex", "google-vertex-anthropic")
    $enabled = @(Get-DelegatorEnabledModels "enabled_opencode_models")
    return @($enabled | Where-Object {
        $parts = ([string]$_).Split("/", 2)
        $parts.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[1]) -and $builtIn -notcontains $parts[0]
    } | Sort-Object)
}

function Get-StrongestReviewer {
    <#
      The model that CHECKS an answer, picked across BOTH providers.

      Until 0.5.13 this read `enabled_opencode_models` only, so the reviewer was
      always a free Zen model even when a current-generation Gemini was sitting
      right there. Owner's brief 2026-08-13: Delegator's first job is now the
      QUALITY of the answer, economy second - and a reviewer weaker than the
      model it reviews invents defects it cannot justify (`verdict-unparsable`
      showed up twice in run #9 for exactly that reason).

      Order: best available Google model, then the strongest enabled Zen model,
      then the universal free route. Free Zen models and Gemini cannot honestly
      be put on one numeric scale, but a current-generation Gemini is stronger
      than any of the free aliases, so this IS "the strongest available".

      Returns @{ model; backend } - empty model when nothing is configured.
    #>
    # A provider the user configured themselves outranks everything: they added
    # it deliberately, and it is usually a frontier model behind their own key.
    $custom = @(Get-CustomProviderModels)
    if ($custom.Count -gt 0) {
        return [pscustomobject]@{ model = [string]$custom[0]; backend = "opencode" }
    }
    $gemini = @(Get-EnabledGeminiModelsByStrength)
    if ($gemini.Count -gt 0) {
        return [pscustomobject]@{ model = [string]$gemini[0]; backend = "gemini" }
    }
    $zen = Get-StrongEnabledModel
    if (-not [string]::IsNullOrWhiteSpace($zen)) {
        return [pscustomobject]@{ model = $zen; backend = "opencode" }
    }
    $free = Get-UniversalFreeModel
    if (-not [string]::IsNullOrWhiteSpace($free)) {
        return [pscustomobject]@{ model = $free; backend = "opencode" }
    }
    return [pscustomobject]@{ model = ""; backend = "gemini" }
}

function Invoke-DelegateAcrossBackends {
    <#
      One call, and if the whole backend is unusable, the SAME call on the other
      one with that backend's strongest enabled model.

      Why: `improve` picked its reviewer from enabled_opencode_models only, so
      when the OpenCode free tier ran out the reviewer call failed and improve
      exited 1 - Delegator simply stopped working, while the Google keys still
      had quota. The owner hit exactly that during a benchmark run.

      Returns the original result object plus `backend`, `model` and
      `fellBack` so callers can report which side actually answered.
    #>
    param(
        [string]$ChosenBackend,
        [string]$Text,
        [string]$ChosenModel = "",
        [string]$EffectiveComplexity = ""
    )

    $result = Invoke-Delegate -ChosenBackend $ChosenBackend -Text $Text -ChosenModel $ChosenModel -EffectiveComplexity $EffectiveComplexity
    if ($result.exitCode -eq 0) {
        return [pscustomobject]@{
            exitCode = 0; output = $result.output; backend = $ChosenBackend
            model = $ChosenModel; fellBack = $false
        }
    }

    # A custom provider usually exposes SEVERAL models and they fail
    # independently: the owner's AgentRouter answers on gpt-5.6-sol while both
    # Claude routes return HTTP 402 (budget pool exhausted). Walk the rest of
    # their own models before leaving the provider they configured.
    $custom = @(Get-CustomProviderModels | Where-Object { $_ -ne $ChosenModel })
    foreach ($sibling in @($custom | Select-Object -First 2)) {
        [Console]::Error.WriteLine("[Delegator] $ChosenModel failed, trying $sibling")
        Write-DelegateMetric -Stage "failover" -Model $sibling -Backend "opencode" -Status "same-provider" -Extra "was=$ChosenModel"
        $retry = Invoke-Delegate -ChosenBackend "opencode" -Text $Text -ChosenModel $sibling -EffectiveComplexity $EffectiveComplexity
        if ($retry.exitCode -eq 0) {
            return [pscustomobject]@{
                exitCode = 0; output = $retry.output; backend = "opencode"
                model = $sibling; fellBack = $true
            }
        }
    }

    $otherBackend = if ($ChosenBackend -eq "opencode") { "gemini" } else { "opencode" }
    # Up to two models on the other side. Google meters each model separately,
    # so "pro is out of quota" must not read as "Google is out of quota".
    $candidates = if ($otherBackend -eq "gemini") {
        @(Get-EnabledGeminiModelsByStrength | Select-Object -First 2)
    } else {
        $first = Get-StrongEnabledModel
        $second = if ([string]::IsNullOrWhiteSpace($first)) { "" } else { Get-StrongEnabledModel -Exclude @($first) }
        @(@($first, $second) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{
            exitCode = $result.exitCode; output = $result.output; backend = $ChosenBackend
            model = $ChosenModel; fellBack = $false
        }
    }

    # Last rung: the universal free route, whichever side we ended up on. When
    # both providers are rate-limited this is the only thing left that answers.
    $universal = Get-UniversalFreeModel
    if (-not [string]::IsNullOrWhiteSpace($universal) -and $candidates -notcontains $universal) {
        $candidates = @($candidates) + $universal
    }

    $lastRetry = $null
    foreach ($otherModel in $candidates) {
        # `openrouter/*` is served by the opencode side regardless of which
        # backend we failed over FROM.
        $useBackend = if ($otherModel -like "openrouter/*") { "opencode" } else { $otherBackend }
        [Console]::Error.WriteLine("[Delegator] $ChosenBackend failed, retrying on $useBackend ($otherModel)")
        Write-DelegateMetric -Stage "failover" -Model $otherModel -Backend $useBackend -Status "from-$ChosenBackend" -Extra "was=$ChosenModel"
        $lastRetry = Invoke-Delegate -ChosenBackend $useBackend -Text $Text -ChosenModel $otherModel -EffectiveComplexity $EffectiveComplexity
        if ($lastRetry.exitCode -eq 0) {
            return [pscustomobject]@{
                exitCode = 0; output = $lastRetry.output; backend = $useBackend
                model = $otherModel; fellBack = $true
            }
        }
    }
    return [pscustomobject]@{
        exitCode = $lastRetry.exitCode; output = $lastRetry.output; backend = $otherBackend
        model = [string]$candidates[-1]; fellBack = $true
    }
}

function Invoke-DelegateWithRetry {
    param(
        [string]$ChosenBackend,
        [string]$Text,
        [string]$ChosenModel = "",
        [string]$EffectiveComplexity = "",
        [int]$MaxRetries = 2
    )

    $currentBackend = $ChosenBackend
    $currentModel = $ChosenModel
    $attempt = 0

    while ($attempt -le $MaxRetries) {
        $result = Invoke-Delegate -ChosenBackend $currentBackend -Text $Text -ChosenModel $currentModel -EffectiveComplexity $EffectiveComplexity
        
        # Check exit code and quality
        $outStr = (($result.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
        $quality = Test-ResponseQuality -Response $outStr -OriginalPrompt $Text

        if ($result.exitCode -eq 0 -and $quality -eq "ok") {
            return $result
        }

        $isRetryable = Test-RetryableError -Output $outStr -ExitCode $result.exitCode
        if ($attempt -lt $MaxRetries -and ($isRetryable -or $quality -in @("empty", "truncated", "refusal", "too-short"))) {
            $attempt++
            $backoffMs = [int]([Math]::Pow(2, $attempt) * 1000)
            Write-DelegateMetric -Stage "retry" -Status $quality -Extra "attempt=$attempt,backoff=$backoffMs,backend=$currentBackend,model=$currentModel"
            
            # Switch model/backend on retry
            $nextModel = Get-NextRankedModel -CurrentModel $currentModel
            if (-not [string]::IsNullOrWhiteSpace($nextModel)) {
                $currentModel = $nextModel
                $currentBackend = if ($currentModel -like "gemini-*") { "gemini" } else { "opencode" }
            }
            Start-Sleep -Milliseconds $backoffMs
            continue
        }

        return $result
    }
}

# ── Usage accounting helpers (DEV_CONTRACTS section 2) ──

# Commands that execute prompts; only these emit the ##DELEGATOR_USAGE## marker.
$script:PromptModes = @("ask", "delegate", "boost", "improve", "micro", "verify", "plan", "parallel", "triage", "extract")

function Get-DelegateUsageMode {
    if ($Command -in @("ask", "delegate")) { if ($Boost) { return "boost" } else { return "ask" } }
    if ($Command -in @("triage", "extract")) { return "ask" }
    return $Command
}

function Get-UsageProviderName {
    param([string]$BackendName)
    if ($BackendName -eq "gemini") { return "gemini" }
    if ($BackendName -eq "opencode") { return "opencode-cli" }
    return [string]$BackendName
}

function Get-UsageNumber {
    param([object]$Record, [string]$Name)
    try {
        $prop = $Record.PSObject.Properties[$Name]
        if ($prop -and $null -ne $prop.Value -and "$($prop.Value)" -ne "") {
            return [double]$prop.Value
        }
    } catch {}
    return 0
}

# Records the intended exit code (for the marker's ok flag) and exits; the
# try/finally around the command dispatch runs Complete-DelegateUsage on the way out.
function Exit-Delegate {
    param([int]$Code = 0)
    $script:FinalExitCode = $Code
    exit $Code
}

# Aggregates the per-request usage file, optionally emits the stream marker
# (DEV_CONTRACTS section 2.3) as the LAST stdout line, then deletes the temp file.
function Complete-DelegateUsage {
    try {
        if (-not $script:UsageOwner) { return }
        $usageFile = $env:DELEGATOR_USAGE_FILE
        $records = @()
        if (-not [string]::IsNullOrWhiteSpace($usageFile) -and (Test-Path -LiteralPath $usageFile)) {
            foreach ($line in @([System.IO.File]::ReadAllLines($usageFile))) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $records += @(($line | ConvertFrom-Json)) } catch {}
            }
        }
        if ($env:DELEGATOR_EMIT_USAGE -eq "1" -and $script:PromptModes -contains $Command) {
            $pt = 0.0; $ct = 0.0; $tt = 0.0; $cost = 0.0
            $stages = @()
            foreach ($r in $records) {
                $pt += Get-UsageNumber $r "promptTokens"
                $ct += Get-UsageNumber $r "completionTokens"
                $tt += Get-UsageNumber $r "totalTokens"
                $cost += Get-UsageNumber $r "cost"
                $stages += [pscustomobject]@{
                    stage       = [string]$r.stage
                    model       = [string]$r.model
                    totalTokens = [long](Get-UsageNumber $r "totalTokens")
                }
            }
            $finalModel = [string]$script:FinalModel
            $finalProvider = [string]$script:FinalProvider
            if ([string]::IsNullOrWhiteSpace($finalModel)) {
                for ($ri = $records.Count - 1; $ri -ge 0; $ri--) {
                    $r = $records[$ri]
                    if ([string]::IsNullOrWhiteSpace([string]$r.model)) { continue }
                    $rOk = $true
                    try { if ($r.PSObject.Properties["ok"] -and $null -ne $r.ok) { $rOk = [bool]$r.ok } } catch {}
                    if (-not $rOk) { continue }
                    $finalModel = [string]$r.model
                    $finalProvider = [string]$r.provider
                    break
                }
            } elseif ([string]::IsNullOrWhiteSpace($finalProvider)) {
                for ($ri = $records.Count - 1; $ri -ge 0; $ri--) {
                    $r = $records[$ri]
                    if ([string]$r.model -eq $finalModel -and -not [string]::IsNullOrWhiteSpace([string]$r.provider)) {
                        $finalProvider = [string]$r.provider
                        break
                    }
                }
            }
            $okFlag = ($null -eq $script:FinalExitCode -or [int]$script:FinalExitCode -eq 0)
            $marker = [pscustomobject]@{
                requestId        = [string]$script:DelegateRequestId
                mode             = (Get-DelegateUsageMode)
                model            = $finalModel
                provider         = $finalProvider
                promptTokens     = [long]$pt
                completionTokens = [long]$ct
                totalTokens      = [long]$tt
                cost             = [Math]::Round($cost, 6)
                elapsedMs        = [long]$script:RequestStopwatch.ElapsedMilliseconds
                ok               = $okFlag
                stages           = @($stages)
            }
            Write-Output ("##DELEGATOR_USAGE## " + ($marker | ConvertTo-Json -Depth 5 -Compress))
        }
    } catch {}
    if ($script:UsageOwner -and -not [string]::IsNullOrWhiteSpace($env:DELEGATOR_USAGE_FILE)) {
        Remove-Item -LiteralPath $env:DELEGATOR_USAGE_FILE -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\DELEGATOR_USAGE_FILE -ErrorAction SilentlyContinue
    }
}

# ── Parallel fan-out via temp prompt files (DEV_CONTRACTS section 1) ──
# Prompts are handed to ai-delegate-parallel.ps1 as -PromptFile temp files, never
# as argv text. Streams the child output; exit code lands in $script:LastParallelExitCode.
function Invoke-ParallelDelegate {
    param(
        [string[]]$PromptList,
        [string]$Cx,
        [bool]$AsJson = $false,
        [bool]$NoDiverse = $false,
        [int]$MaxParallelCount = 0
    )
    Ensure-DelegateDir $script:DelegateHome
    $tempFiles = @()
    try {
        $runArgs = @("ask")
        foreach ($p in @($PromptList)) {
            $tf = Join-Path $script:DelegateHome ("prompt-parallel-" + [Guid]::NewGuid().ToString("n") + ".txt")
            Write-Utf8NoBom -Path $tf -Text ([string]$p)
            $tempFiles += $tf
            $runArgs += @("-PromptFile", $tf)
        }
        $runArgs += @("-Complexity", $Cx, "-TimeoutSec", "$TimeoutSec")
        if ($MaxParallelCount -gt 0) { $runArgs += @("-MaxParallel", "$MaxParallelCount") }
        if ($AsJson) { $runArgs += "-Json" }
        if ($NoDiverse) { $runArgs += "-NoDiverseModels" }
        & $ParallelDelegate @runArgs
        $script:LastParallelExitCode = $LASTEXITCODE
    } finally {
        foreach ($tf in $tempFiles) {
            Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-DelegationPlan {
    param([string]$Text)
    if ($NoPlanner -or $env:CODEX_DELEGATE_PLANNER -eq "0" -or $env:CODEX_DELEGATE_PLANNER_ACTIVE -eq "1") { return $null }
    if (-not (Test-Path -LiteralPath $DelegatePlanner)) { return $null }
    if ($Text -match "^Reply exactly:.*") { return $null }
    if (-not [string]::IsNullOrWhiteSpace($Model) -or $Backend -ne "auto") { return $null }

    try {
        $raw = (& $DelegatePlanner -Prompt $Text -TimeoutSec 45 -Json 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
        $start = $raw.IndexOf("{")
        $end = $raw.LastIndexOf("}")
        if ($start -lt 0 -or $end -le $start) { return $null }
        return ($raw.Substring($start, $end - $start + 1) | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Invoke-StructuredTriage {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }

    # Fast semantic routing pre-filter
    $routerScript = Join-Path $BinHome "ai-delegate-semantic-router.ps1"
    if (Test-Path -LiteralPath $routerScript) {
        try {
            $routerRes = (& $routerScript $Text 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($routerRes)) {
                $parsed = $routerRes | ConvertFrom-Json
                if ($parsed -and $parsed.reason -match "Semantic routing decision") {
                    return $parsed
                }
            }
        } catch {}
    }

    $triageModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { Get-TriageModel $Text }
    if ([string]::IsNullOrWhiteSpace($triageModel)) {
        # No enabled fast model: skip triage cleanly without spawning a subprocess.
        Write-DelegateMetric -Stage "triage" -Status "skipped-no-model"
        return $null
    }
    $triageBackend = Select-Backend -Text $Text -ChosenModel $triageModel
    $triagePrompt = @"
Classify and route this delegated task. Return strict minified JSON only.
Schema: {"mode":"single|parallel","complexity":"fast|normal|deep|auto","backend":"auto|gemini|opencode","preprocess":"none|extract","verify":true,"taskType":"universal|code_debug|architecture|security|context_analysis|summarization|math_algo|reasoning|refactoring|data_consistency","mustHave":["..."],"reason":"short"}
Rules:
- preprocess=extract when the input is long, noisy, or contains logs/code blocks that should be compressed first.
- verify=true for code/debug/security/architecture/high-risk conclusions.
- mustHave contains only explicit hard constraints from the user.
- Prefer single unless there are clearly independent subtasks.
TASK:
$Text
"@
    $triageSw = [System.Diagnostics.Stopwatch]::StartNew()
    $res = Invoke-Delegate -ChosenBackend $triageBackend -Text $triagePrompt -ChosenModel $triageModel -EffectiveComplexity "fast"
    Write-DelegateUsageRecord -Stage "triage" -Mode (Get-DelegateUsageMode) -Provider (Get-UsageProviderName $triageBackend) -Model $triageModel -ElapsedMs ([int]$triageSw.ElapsedMilliseconds) -Ok ($res.exitCode -eq 0)
    if ($res.exitCode -ne 0) { return $null }
    try {
        $raw = (($res.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        $start = $raw.IndexOf("{")
        $end = $raw.LastIndexOf("}")
        if ($start -lt 0 -or $end -le $start) { return $null }
        return ($raw.Substring($start, $end - $start + 1) | ConvertFrom-Json)
    } catch {
        Write-DelegateMetric -Stage "triage" -Status "parse-error" -Extra "raw-length=$($raw.Length)"
        return $null
    }
}

function Invoke-ContextExtract {
    param(
        [string]$Text,
        [string[]]$MustHave
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $extractModel = Get-ExtractModel $Text
    if ([string]::IsNullOrWhiteSpace($extractModel)) { return $Text }
    $extractBackend = Select-Backend -Text $Text -ChosenModel $extractModel
    $constraints = if ($MustHave -and $MustHave.Count -gt 0) { ($MustHave -join "; ") } else { "none" }
    $extractPrompt = @"
Compress this task into a concise execution brief for a stronger model.
Return plain text only with sections:
TASK
CONTEXT
MUST-HAVE
IGNORE

Rules:
- Do not solve the task.
- Preserve all explicit hard requirements.
- Keep concrete identifiers, filenames, APIs, errors, versions, and dates.
- Keep actual source code snippets and class/method signatures completely intact. Do not summarize code syntax.
- Only drop large unstructured logs, repetitive descriptions, and obvious boilerplate.

MUST-HAVE CONSTRAINTS:
$constraints

INPUT:
$Text
"@
    $res = Invoke-Delegate -ChosenBackend $extractBackend -Text $extractPrompt -ChosenModel $extractModel -EffectiveComplexity "fast"
    if ($res.exitCode -ne 0) { return $Text }
    $out = (($res.output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($out)) { return $Text }
    return $out
}

function Invoke-PlannedParallel {
    param([object]$Plan)
    $prompts = @($Plan.prompts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 4 | ForEach-Object { [string]$_ })
    if ($prompts.Count -lt 2) { return }
    $cx = if ($Plan.complexity -in @("fast", "normal", "deep", "auto")) { [string]$Plan.complexity } else { $Complexity }
    Invoke-ParallelDelegate -PromptList $prompts -Cx $cx -AsJson $true -MaxParallelCount ([Math]::Min(4, $prompts.Count))
    Exit-Delegate $script:LastParallelExitCode
}

function Run-Plan {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    & $DelegatePlanner -Prompt $Prompt -TimeoutSec 45 -Json
    Exit-Delegate $LASTEXITCODE
}

function Run-Triage {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    $triage = Invoke-StructuredTriage $Prompt
    if ($triage) { $triage | ConvertTo-Json -Depth 8 } else { "{}" }
    Exit-Delegate 0
}

function Run-Extract {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    $triage = Invoke-StructuredTriage $Prompt
    $must = @()
    if ($triage -and $triage.mustHave) { $must = @($triage.mustHave | ForEach-Object { [string]$_ }) }
    $brief = Invoke-ContextExtract -Text $Prompt -MustHave $must
    Write-Output $brief
    Exit-Delegate 0
}

function Run-Parallel {
    $items = @($Prompts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    if ($items.Count -eq 0) {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if (-not [string]::IsNullOrWhiteSpace($raw)) { $items = @($raw) }
        }
    }
    if ($items.Count -eq 0) { throw "At least one prompt is required for parallel." }

    Invoke-ParallelDelegate -PromptList $items -Cx $Complexity -AsJson ([bool]$Json) -NoDiverse ([bool]$NoDiverseModels)
    Exit-Delegate $script:LastParallelExitCode
}

function Run-UI {
    $appExe = Join-Path (Split-Path $BinHome -Parent) "delegator.exe"
    if (-not (Test-Path -LiteralPath $appExe)) { throw "Delegator GUI was not found: $appExe" }
    Start-Process -FilePath $appExe
    exit 0
}

function Run-Policy {
    if (Test-Path -LiteralPath $PolicyFile) {
        Get-Content -LiteralPath $PolicyFile -Raw
    } else {
        Write-Output "Use $BinHome\ai-delegate.cmd as the single delegation entry point. Default mode is delegate."
    }
    exit 0
}

function Run-Micro {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    $microParams = @{ Prompt = $Prompt; TimeoutSec = $TimeoutSec }
    if ($Json) { $microParams.Json = $true }
    if ($Async) { $microParams.Async = $true }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $microParams.Model = $Model }
    & $MicroDelegate @microParams
    Exit-Delegate $LASTEXITCODE
}

function Get-OrchestratorModel {
    # Judge of a boost fan-out, synthesis model and `verify` model. It reads
    # several answers from stronger models and picks/merges - a flash-class
    # default here is a lossy compressor placed on top of the best candidate,
    # so the strongest enabled model wins. The old preference order stays as
    # the fallback when nothing is enabled or everything is cooling down.
    param([string]$Preferred = "opencode/deepseek-v4-flash-free")

    $strongest = Get-StrongEnabledModel
    if (-not [string]::IsNullOrWhiteSpace($strongest)) { return $strongest }

    $enabled = @(Get-DelegatorEnabledModels "enabled_opencode_models")
    $candidates = @()
    if ($enabled -contains $Preferred) { $candidates += $Preferred }
    $rankings = Read-ModelRankings
    if ($rankings -and $rankings.overall) {
        foreach ($row in @($rankings.overall)) {
            $candidate = [string]$row.model
            if ($enabled -contains $candidate -and $candidates -notcontains $candidate) { $candidates += $candidate }
        }
    }
    foreach ($candidate in $enabled) {
        if ($candidates -notcontains $candidate) { $candidates += $candidate }
    }
    $candidates = @(Select-ActiveRankedModels $candidates)
    if ($candidates.Count -gt 0) { return [string]$candidates[0] }
    return $Preferred
}

function Parse-PercentNumber {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 1000.0 }
    $clean = ($Value -replace "[^0-9\.,]", "").Replace(",", ".")
    $n = 0.0
    if ([double]::TryParse($clean, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
        return $n
    }
    return 1000.0
}

function Select-ProBackendByQuota {
    # Check Gemini Pro quota via state file; if exhausted, prefer Codex backend
    try {
        $stateFile = Join-Path $script:DelegateHome "state.json"
        if (Test-Path -LiteralPath $stateFile) {
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            if ($state.profiles) {
                $bestBackend = "gemini"
                $bestUsed = 100.0
                foreach ($name in @($state.profileOrder)) {
                    $p = $state.profiles.$name
                    if (-not $p) { continue }
                    $used = 100.0
                    if ($p.PSObject.Properties["quotaUsedPercent"] -and $null -ne $p.quotaUsedPercent) {
                        $used = [double]$p.quotaUsedPercent
                    }
                    if ($used -lt $bestUsed) {
                        $bestUsed = $used
                    }
                }
                # If all Gemini profiles are >85% used, try Codex if available
                if ($bestUsed -gt 85.0) {
                    $codexStateFile = Join-Path $script:DelegateHome "codex-state.json"
                    if (Test-Path -LiteralPath $codexStateFile) {
                        $codexState = Get-Content -LiteralPath $codexStateFile -Raw | ConvertFrom-Json
                        if ($codexState.available -eq $true) { return "codex" }
                    }
                }
                return $bestBackend
            }
        }
    } catch {}
    return "gemini"
}

function Run-Verify {
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }
    $verifyPrompt = "Verify this claim or context: $Prompt`nReturn three fields only: verdict is correct, partly-correct, incorrect, or uncertain. reason is one short reason. check is one minimal verification step."

    # Verification runs on the strongest enabled model (Get-OrchestratorModel,
    # see DEV_CONTRACTS section 9) - a weak verifier is worse than none.
    $verifyModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { Get-OrchestratorModel }

    $verifySw = [System.Diagnostics.Stopwatch]::StartNew()
    $raw = & $MicroDelegate $verifyPrompt -TimeoutSec "$TimeoutSec" -Model $verifyModel 2>&1
    $code = $LASTEXITCODE
    $text = (($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    $verifyBackend = if ($verifyModel -like "gemini-*") { "gemini" } else { "opencode" }
    Write-DelegateUsageRecord -Stage "verify" -Mode "verify" -Provider (Get-UsageProviderName $verifyBackend) -Model $verifyModel -ElapsedMs ([int]$verifySw.ElapsedMilliseconds) -Ok ($code -eq 0)
    $script:FinalModel = $verifyModel
    $script:FinalProvider = Get-UsageProviderName $verifyBackend
    if ($Json) {
        [pscustomobject]@{
            delegate = "verify"
            model = $verifyModel
            output = $text
            exitCode = $code
        } | ConvertTo-Json -Depth 4
    } else {
        $text
    }
    Exit-Delegate $code
}

function Get-AdvisorExitCode {
    # Exit code of one advisor row, never throwing. Anything unreadable counts
    # as a failed advisor: a boost run must degrade to "fewer advisors", never
    # to a crash in front of the user.
    param($Row)
    $value = $null
    try { $value = $Row.exitCode } catch { return 1 }
    if ($null -eq $value) { return 1 }
    if ($value -is [array]) {
        $first = @($value) | Where-Object { $null -ne $_ } | Select-Object -First 1
        $value = $first
    }
    $parsed = 0
    if ([int]::TryParse([string]$value, [ref]$parsed)) { return $parsed }
    return 1
}

function Run-Boost {
    param([string]$Text, [int]$Count, [string]$SynthModelName)

    $boostSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Ignore trivial smoke tests
    if ($Text -match "^Reply exactly:.*") { return $false }

    $ParalDel = Join-Path $BinHome "ai-delegate-parallel.ps1"
    
    $topModels = @()
    $rankings = Read-ModelRankings
    if ($rankings -and $rankings.overall) {
        $topModels = @($rankings.overall | Where-Object { $_.model } | Select-Object -First ($Count + 3) | ForEach-Object { $_.model })
        $topModels = @(Select-ActiveRankedModels $topModels)
    }
    if ($topModels.Count -lt $Count) {
        $topModels = @("opencode/deepseek-v4-flash-free", "opencode/ling-3.0-flash-free", "opencode/nemotron-3-ultra-free")
    }
    
    $modelsToUse = @($topModels | Select-Object -First $Count)
    $explicitParam = $modelsToUse -join ","
    $maxPar = [Math]::Min($Count, $modelsToUse.Count)
    
    # ── Diverse prompting: each advisor gets a different perspective ──
    $perspectives = @(
        "Focus on correctness, edge cases, and error handling. Identify potential bugs.",
        "Focus on performance, efficiency, and scalability. Suggest optimizations.",
        "Focus on maintainability, clean architecture, and best practices. Suggest improvements."
    )
    $prompts = @()
    for ($k=0; $k -lt $Count; $k++) {
        $perspective = $perspectives[$k % $perspectives.Count]
        $advisorPrompt = Add-ExecutionLanguagePolicy "$perspective`n`nTASK:`n$Text"
        $prompts += $advisorPrompt
    }

    # ── Advisor fan-out: prompts travel as UTF-8 temp files (-PromptFile), never as
    # nested powershell.exe argv (PS 5.1 strips embedded quotes) - DEV_CONTRACTS 1. ──
    Ensure-DelegateDir $script:DelegateHome
    $advisorFiles = @()
    foreach ($p in $prompts) {
        $tf = Join-Path $script:DelegateHome ("prompt-boost-" + [Guid]::NewGuid().ToString("n") + ".txt")
        Write-Utf8NoBom -Path $tf -Text ([string]$p)
        $advisorFiles += $tf
    }
    $scriptArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ParalDel, "ask")
    foreach ($tf in $advisorFiles) { $scriptArgs += @("-PromptFile", $tf) }
    $scriptArgs += @("-Complexity", "deep", "-TimeoutSec", "$TimeoutSec", "-MaxParallel", "$maxPar", "-Json", "-ExplicitModels", $explicitParam)

    if (-not $Json) {
        [Console]::Error.WriteLine("[Fusion Synthesis] Launching $maxPar parallel advisors (diverse perspectives)...")
    }

    $env:CODEX_DELEGATE_BOOST_ACTIVE = "1"
    try {
        $raw = (& powershell @scriptArgs 2>&1 | Out-String).Trim()
    } finally {
        $env:CODEX_DELEGATE_BOOST_ACTIVE = "0"
        foreach ($tf in $advisorFiles) { Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue }
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return $false
    }

    try {
        # Flatten: a nested array here makes `$_.exitCode` a member-enumerated
        # Object[], and casting that to [int] threw a TERMINATING error - the
        # user then got a PowerShell stack trace instead of an answer.
        $jsonObjects = @()
        foreach ($parsed in @($raw | ConvertFrom-Json)) {
            if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
                foreach ($inner in $parsed) { $jsonObjects += $inner }
            } else {
                $jsonObjects += $parsed
            }
        }
        if (-not $jsonObjects -or $jsonObjects.Count -eq 0) {
            return $false
        }
    } catch {
        Write-DelegateMetric -Stage "boost" -Status "advisors-unparsable" -LatencyMs $boostSw.ElapsedMilliseconds -Extra "raw-length=$($raw.Length)"
        return $false
    }

    # Advisors that actually succeeded (exit 0, non-empty output). Identical error
    # strings must never be mistaken for consensus and returned as the answer.
    $okAdvisors = @($jsonObjects | Where-Object {
        $null -ne $_ -and (Get-AdvisorExitCode $_) -eq 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$_.output)
    })
    if ($okAdvisors.Count -eq 0) {
        Write-DelegateMetric -Stage "boost" -Status "error" -LatencyMs $boostSw.ElapsedMilliseconds -Extra "all-advisors-failed"
        return $false
    }

    # ── Early exit: only when ALL advisors succeeded and agree (first 500 chars) ──
    if ($okAdvisors.Count -ge 2 -and $okAdvisors.Count -eq $jsonObjects.Count) {
        $firstOutput = ""
        $allSame = $true
        foreach ($obj in $okAdvisors) {
            $outText = ""
            try {
                $inner = $obj.output | ConvertFrom-Json
                $outText = if ($inner.output) { $inner.output } else { $obj.output }
            } catch { $outText = $obj.output }
            $snippet = if ($outText.Length -gt 500) { $outText.Substring(0, 500) } else { $outText }
            if ([string]::IsNullOrWhiteSpace($firstOutput)) {
                $firstOutput = $snippet
            } elseif ($snippet -ne $firstOutput) {
                $allSame = $false
                break
            }
        }
        if ($allSame) {
            if (-not $Json) {
                [Console]::Error.WriteLine("[Fusion Synthesis] All advisors agree -- skipping synthesis.")
            }
            $firstFull = ""
            try {
                $inner = $okAdvisors[0].output | ConvertFrom-Json
                $firstFull = if ($inner.output) { $inner.output } else { $okAdvisors[0].output }
            } catch { $firstFull = $okAdvisors[0].output }
            Write-DelegateMetric -Stage "boost" -Status "early-exit" -LatencyMs $boostSw.ElapsedMilliseconds -Extra "advisors-agreed"
            $script:FinalModel = [string]$okAdvisors[0].model
            $script:FinalProvider = if ($script:FinalModel -like "gemini-*") { "gemini" } else { "opencode-cli" }
            return $firstFull
        }
    }

    if (-not $Json) {
        [Console]::Error.WriteLine("[Fusion Synthesis] Parallel advisors finished. Running Judge synthesis...")
    }

    $targetLanguage = Get-PreferredOutputLanguage $Text
    $synthPrompt = @"
You are the Fusion Judge. Below are solutions from $Count different AI advisors for the task below.
Each advisor had a different focus area. Resolve contradictions using the Judge Contract:
1. Consensus: What do they agree on?
2. Contradictions: What do they disagree on? Pick the best approach.
3. Unique Insights: What smart ideas did only one advisor have?
4. Blind Spots: What did they all miss?

Return the final user-facing answer only in $targetLanguage unless the task explicitly requires another language.
Provide the final production-ready code with strict token efficiency.

TASK:
$Text

"@
    
    $i = 1
    foreach ($obj in $okAdvisors) {
        $outputStr = ""
        try {
            $inner = $obj.output | ConvertFrom-Json
            if ($inner.output) { $outputStr = $inner.output } else { $outputStr = $obj.output }
        } catch { $outputStr = $obj.output }
        $perspective = $perspectives[($i - 1) % $perspectives.Count]
        $synthPrompt += "=== ADVISOR $i ($perspective) from $($obj.model) ===`n$outputStr`n`n"
        $i++
    }

    $synthPrompt += "`n=== FINAL ANSWER ==="

    $actualSynthModel = if (-not [string]::IsNullOrWhiteSpace($SynthModelName)) { $SynthModelName } else { Get-OrchestratorModel }
    $synthBackend = Select-Backend -Text $synthPrompt -ChosenModel $actualSynthModel

    # In-process synthesis via the standard choke point: no nested powershell.exe
    # argv (quote stripping, 32K command-line limit) - DEV_CONTRACTS section 1.
    $synthSw = [System.Diagnostics.Stopwatch]::StartNew()
    $synthResult = Invoke-Delegate -ChosenBackend $synthBackend -Text $synthPrompt -ChosenModel $actualSynthModel -EffectiveComplexity "deep"
    Write-DelegateUsageRecord -Stage "synthesis" -Mode (Get-DelegateUsageMode) -Provider (Get-UsageProviderName $synthBackend) -Model $actualSynthModel -ElapsedMs ([int]$synthSw.ElapsedMilliseconds) -Ok ($synthResult.exitCode -eq 0)
    $outStr = (($synthResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($synthResult.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($outStr)) {
        Write-DelegateMetric -Stage "boost" -Model $actualSynthModel -Status "synthesis-failed" -LatencyMs $boostSw.ElapsedMilliseconds -Extra "advisors=$Count"
        return $false
    }

    # Synthesis transcript goes to the runtime home (never the caller's CWD).
    try {
        Ensure-DelegateDir $script:DelegateHome
        $synthesisPath = Join-Path $script:DelegateHome ("synthesis-" + $script:DelegateRequestId + ".md")
        Write-Utf8NoBom -Path $synthesisPath -Text $outStr
        if (-not $Json) {
            [Console]::Error.WriteLine("[Fusion Synthesis] Complete. Final response auto-saved to $synthesisPath")
        }
    } catch {}

    Write-DelegateMetric -Stage "boost" -Model $actualSynthModel -Status "ok" -LatencyMs $boostSw.ElapsedMilliseconds -Extra "advisors=$Count"

    $script:FinalModel = $actualSynthModel
    $script:FinalProvider = Get-UsageProviderName $synthBackend

    $jsonObjects = $null
    $raw = $null
    [System.GC]::Collect()

    return $outStr
}

# Filter-ConversationalNoise → delegator-common.ps1 (improved version with less aggressive matching)

function Invoke-CritiqueCorrectionLoop {
    param(
        [string]$OriginalPrompt,
        [string]$InitialAnswer,
        [string]$Model,
        [string]$Backend,
        [string]$Complexity,
        [string[]]$MustHave
    )
    
    # Skip if answer is empty or trivial
    if ([string]::IsNullOrWhiteSpace($InitialAnswer) -or $InitialAnswer.Length -lt 50) { return $InitialAnswer }

    # The reviewer must be at least as strong as the author, otherwise it
    # invents defects in code it cannot follow and the refinement pass makes the
    # answer worse. gemini-flash-lite stays as the fallback for a machine with
    # no enabled OpenCode models.
    $critiqueModel = Get-StrongEnabledModel
    if ([string]::IsNullOrWhiteSpace($critiqueModel)) { $critiqueModel = "gemini-flash-lite-latest" }
    $constraintsText = if ($MustHave -and $MustHave.Count -gt 0) { "- " + ($MustHave -join "`n- ") } else { "none" }
    
    $critiquePrompt = @"
You are an expert AI code reviewer and validator.
Review the following generated answer against the original prompt and constraints.
If the answer is correct, matches all constraints, has no syntax/compilation errors, and is complete, reply with exactly 'OK' (no comments).
If there are bugs, errors, or missed constraints, list them as brief bullet points. DO NOT write code fixes, just list the defects.

ORIGINAL PROMPT:
$OriginalPrompt

MUST-HAVE CONSTRAINTS:
$constraintsText

GENERATED ANSWER:
$InitialAnswer
"@

    # 20s was tuned for flash-lite; the strong models measured on this machine
    # need 30-70s on an 8k prompt, and a timeout here silently returns the
    # unreviewed answer.
    $rawCritique = & $MicroDelegate $critiquePrompt -TimeoutSec 120 -Model $critiqueModel -Json 2>&1 | Out-String
    $parsedCritique = $null
    try {
        $parsedCritique = $rawCritique.Trim() | ConvertFrom-Json
    } catch {}

    if ($null -eq $parsedCritique -or $parsedCritique.exitCode -ne 0 -or $parsedCritique.output -match "failed|error|unavailable|exhausted") {
        return $InitialAnswer
    }

    $critiqueOutput = $parsedCritique.output.Trim()
    if ($critiqueOutput -match '^\s*OK\s*$') {
        return $InitialAnswer
    }

    [Console]::Error.WriteLine("[Self-Correction] Critique detected defects. Running refinement pass...")
    
    $refinePrompt = @"
You are a senior software developer. You need to correct your previous answer based on the following code review critique. Make sure to fix all defects and preserve all constraints.

ORIGINAL PROMPT:
$OriginalPrompt

PREVIOUS GENERATED ANSWER:
$InitialAnswer

CODE REVIEW CRITIQUE / DEFECTS TO FIX:
$critiqueOutput
"@

    $refineResult = Invoke-Delegate -ChosenBackend $Backend -Text $refinePrompt -ChosenModel $Model -EffectiveComplexity $Complexity
    if ($refineResult.exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($refineResult.output)) {
        return $refineResult.output
    }
    
    return $InitialAnswer
}

# ── Cache key variant ──────────────────────────────────────────────────────
# Everything that changes the SHAPE of the answer for one and the same prompt.
# Without it a -DiffOnly run (a unified diff) is served back to the next plain
# ask of the same question.
function Get-CacheVariant {
    $parts = @()
    if ($DiffOnly) { $parts += "diff" }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_DELEGATE_LANGUAGE)) {
        $parts += "lang=" + $env:CODEX_DELEGATE_LANGUAGE
    }
    return ($parts -join ",")
}

# ── `improve` ───────────────────────────────────────────────────────────────
# The only mode that raises the quality of what the IDE agent finally SAYS,
# instead of handing it a second opinion it has to merge on its own. The caller
# sends its task and its own draft answer; a strong free model reviews the draft
# and rewrites it only when the review found something real.
#
# Contract (docs/DEV_CONTRACTS.md section 8):
#   in   -PromptFile <task> -DraftFile <the agent's own answer> [-ContextFile "a;b"]
#   out  empty stdout  -> keep your draft
#        "##DELEGATOR_IMPROVE## {json}" as the first line, the improved answer after it
#   exit 0 improved | 3 keep | 2 bad input | 1 backend failure
# Cost: one model call when the draft is fine, two when it is not.

$script:ImproveTaskBudget = 8000
$script:ImproveDraftBudget = 24000
$script:ImproveContextBudget = 12000

function Read-ContextFiles {
    # Semicolon-separated list, same convention as -PromptFile. A path that does
    # not exist is reported on stderr and skipped, NOT fatal: the caller is a
    # weak IDE model that guesses paths, and failing the whole review would look
    # to it exactly like "your draft passed" (empty stdout).
    # $script:ImproveMissingContext counts them for the metric.
    param([string[]]$Entries, [int]$Budget)
    $chunks = @()
    $spent = 0
    foreach ($entry in @($Entries)) {
        foreach ($piece in ([string]$entry).Split(";")) {
            $path = $piece.Trim()
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            if (-not (Test-Path -LiteralPath $path)) {
                $script:ImproveMissingContext++
                [Console]::Error.WriteLine("[Delegator] improve: context file not found, ignored: $path")
                continue
            }
            if ($spent -ge $Budget) {
                [Console]::Error.WriteLine("[Delegator] improve: context budget reached, skipping $path")
                continue
            }
            $text = [System.IO.File]::ReadAllText($path, [System.Text.UTF8Encoding]::new($false))
            $room = $Budget - $spent
            if ($text.Length -gt $room) { $text = $text.Substring(0, $room) + "`n... [truncated]" }
            $spent += $text.Length
            $chunks += "=== FILE: $path ===`n$text"
        }
    }
    if ($chunks.Count -eq 0) { return "" }
    return ($chunks -join "`n`n")
}

function Get-CoreExecutable {
    # The runtime scripts live in <install>\runtime, the core next to them in
    # <install>. It carries a full Python, which is the only interpreter an
    # installed machine is guaranteed to have.
    $candidates = @(
        (Join-Path (Split-Path -Parent $PSScriptRoot) "delegator-core.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\Delegator\delegator-core.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return ""
}

function Get-MechanicalDefects {
    <#
      Defects nobody had to READ to find: code that does not compile, SQL that
      SQLite refuses to prepare against the schema stated in the task.

      Benchmark run #4 is the whole reason this exists. Both arms submitted a
      query with ROW_NUMBER() inside GROUP BY - SQLite will not even prepare it -
      the reviewer read it, called it correct, and `improve` returned the broken
      draft unchanged. A reviewer that only reads cannot catch that.

      Never throws and never blocks: no core, no Python, no answer - no defects.
    #>
    param([string]$Task, [string]$Draft, [string]$Rewrite = "", [switch]$WantRewriteDefects)

    $core = Get-CoreExecutable
    if ([string]::IsNullOrWhiteSpace($core)) { return @() }
    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 10)
    $tempDir = [System.IO.Path]::GetTempPath()
    $taskPath = Join-Path $tempDir "dg-lint-task-$stamp.txt"
    $draftPath = Join-Path $tempDir "dg-lint-draft-$stamp.txt"
    $resultPath = Join-Path $tempDir "dg-lint-result-$stamp.json"
    $rewritePath = Join-Path $tempDir "dg-lint-rewrite-$stamp.txt"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        [System.IO.File]::WriteAllText($taskPath, [string]$Task, $utf8)
        [System.IO.File]::WriteAllText($draftPath, [string]$Draft, $utf8)
        $arguments = @("--lint-draft", $taskPath, $draftPath, $resultPath)
        if ($WantRewriteDefects) {
            [System.IO.File]::WriteAllText($rewritePath, [string]$Rewrite, $utf8)
            $arguments += $rewritePath
        }
        $process = Start-Process -FilePath $core -ArgumentList $arguments -PassThru -WindowStyle Hidden
        $null = $process.Handle
        if (-not $process.WaitForExit(20000)) {
            try { $process.Kill() } catch { }
            return @()
        }
        if (-not (Test-Path -LiteralPath $resultPath)) { return @() }
        $payload = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $payload) { return @() }
        $found = if ($WantRewriteDefects) { $payload.rewriteDefects } else { $payload.defects }
        if ($null -eq $found) { return @() }
        return @($found | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    } catch {
        return @()
    } finally {
        foreach ($path in @($taskPath, $draftPath, $resultPath, $rewritePath)) {
            try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Get-ImproveVerdict {
    # First {...} block of the reviewer answer -> object, or $null.
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $start = $Raw.IndexOf("{")
    $end = $Raw.LastIndexOf("}")
    if ($start -lt 0 -or $end -le $start) { return $null }
    try { return ($Raw.Substring($start, $end - $start + 1) | ConvertFrom-Json) } catch { return $null }
}

function Get-SupportedDefects {
    <#
      Defects the reviewer could BACK UP with a concrete failing case.

      Measured on the 30-case internal bench: `improve` rewrote 10 of 30 drafts
      and 8 of those were already correct - about 29% verdict inflation. The
      reviewer calls major/wrong far too eagerly when it only has to assert
      something. A defect nobody can demonstrate is an opinion, and rewriting a
      correct answer on an opinion is how `improve` does damage.

      Accepts both shapes so an older or sloppier reviewer answer still parses:
      a bare string (kept only when it names a case inline) and
      {"defect": "...", "failingCase": "..."}.
    #>
    param($Defects)

    $supported = @()
    foreach ($entry in @($Defects)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) {
            # A bare string counts only when it actually shows the failure.
            $text = [string]$entry
            if ($text -match "(?i)(например|for example|e\.g\.|input|вход|=>|->)") { $supported += $text.Trim() }
            continue
        }
        $text = [string]$entry.defect
        if ([string]::IsNullOrWhiteSpace($text)) { $text = [string]$entry.what }
        $case = [string]$entry.failingCase
        if ([string]::IsNullOrWhiteSpace($case)) { $case = [string]$entry.failing }
        if ([string]::IsNullOrWhiteSpace($text) -or [string]::IsNullOrWhiteSpace($case)) { continue }
        $supported += ("{0} (падает на: {1})" -f $text.Trim(), $case.Trim())
    }
    return @($supported)
}

function Test-ImproveGuards {
    # Machine checks that a rewrite is not a downgrade. Returns "" when the
    # rewrite may be used, otherwise the reason it was rejected. Damaging a
    # correct draft is worse than failing to fix a wrong one, so every doubt
    # ends in KEEP.
    param([string]$Draft, [string]$Improved)
    if ([string]::IsNullOrWhiteSpace($Improved)) { return "empty" }
    if ($Draft.Length -gt 400 -and $Improved.Length -lt [int]($Draft.Length * 0.4)) { return "too-short" }
    $fence = [char]0x60 + "" + [char]0x60 + "" + [char]0x60
    $draftFences = ([regex]::Matches($Draft, [regex]::Escape($fence))).Count
    $newFences = ([regex]::Matches($Improved, [regex]::Escape($fence))).Count
    if ($draftFences -ge 2 -and $newFences -lt 2) { return "code-dropped" }
    if ($Improved -match '(?im)^\s*(i (can not|cannot|am unable)|sorry[,.]|as an ai\b)') { return "refusal" }
    return ""
}

function Run-Improve {
    $improveSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:ImproveMissingContext = 0
    # $ErrorActionPreference is "Stop" for this script, so Write-Error would be a
    # TERMINATING error and the exit code below would never run: the caller got
    # a PowerShell stack trace and exit 1 where the contract promises exit 2.
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        [Console]::Error.WriteLine("[Delegator] improve requires the task text: -PromptFile <file>")
        Exit-Delegate 2
    }
    if ([string]::IsNullOrWhiteSpace($DraftFile) -or -not (Test-Path -LiteralPath $DraftFile)) {
        [Console]::Error.WriteLine("[Delegator] improve requires the draft answer: -DraftFile <file>")
        Exit-Delegate 2
    }
    $draft = [System.IO.File]::ReadAllText($DraftFile, [System.Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($draft)) {
        [Console]::Error.WriteLine("[Delegator] improve: the draft file is empty")
        Exit-Delegate 2
    }

    # The internal review/rewrite calls must NOT inherit -Json: the providers
    # would answer with their envelope, and the verdict parser would read the
    # envelope's braces instead of the model's JSON - every draft would come back
    # "unparsable" and be kept. The switch is remembered for the final output and
    # cleared at script scope, where Invoke-Delegate reads it.
    $callerWantsJson = [bool]$Json
    Set-Variable -Name Json -Value $false -Scope Script

    $task = $Prompt
    if ($task.Length -gt $script:ImproveTaskBudget) { $task = $task.Substring(0, $script:ImproveTaskBudget) + "`n... [truncated]" }
    # A draft that does not fit is reviewed on a truncated copy, and a rewrite of
    # a truncated copy silently DELETES the rest of the caller's answer. Keep it
    # instead - the caller loses nothing.
    if ($draft.Length -gt $script:ImproveDraftBudget) {
        [Console]::Error.WriteLine("[Delegator] improve: draft is longer than $($script:ImproveDraftBudget) characters, keeping it unchanged")
        Write-DelegateMetric -Stage "improve" -Status "keep-draft-too-long" -LatencyMs $improveSw.ElapsedMilliseconds -Extra "chars=$($draft.Length)"
        Exit-Delegate 3
    }
    $draftForReview = $draft
    $context = ""
    if ($ContextFile -and @($ContextFile).Count -gt 0) {
        $context = Read-ContextFiles -Entries $ContextFile -Budget $script:ImproveContextBudget
    }
    $contextBlock = if ([string]::IsNullOrWhiteSpace($context)) { "(none provided)" } else { $context }

    # The reviewer is the strongest model available: a weaker one invents defects
    # in code it cannot follow, and the rewrite then makes things worse.
    # Strongest across BOTH providers, not just the Zen list (see the function).
    $reviewer = Get-StrongestReviewer
    $reviewModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { $reviewer.model }
    if ([string]::IsNullOrWhiteSpace($reviewModel)) { $reviewModel = "gemini-pro-latest" }
    $reviewBackend = Select-Backend -Text $task -ChosenModel $reviewModel
    $script:FinalModel = $reviewModel
    $script:FinalProvider = Get-UsageProviderName $reviewBackend
    $taskDomain = Get-TaskDomain $task

    # Facts, not opinions: code that does not compile and SQL that will not
    # prepare are found by running a compiler, not by reading. See §11.
    $mechanical = @(Get-MechanicalDefects -Task $task -Draft $draftForReview)
    $mechanicalBlock = if ($mechanical.Count -gt 0) {
        "The draft has these MECHANICAL defects, already proven by compiling it. They are facts, not opinions - never dispute them:`n- " + ($mechanical -join "`n- ")
    } else {
        "(none found by compiling the draft)"
    }

    $checkPrompt = @"
You are a strict technical reviewer. Another assistant produced the DRAFT ANSWER below for the TASK below.
Judge the draft on substance only: correctness, missed requirements, wrong APIs, broken logic, unsafe or non-working code.
Style, wording and formatting are NOT defects.

PROVEN DEFECTS:
$mechanicalBlock

Return strict minified JSON and nothing else:
{"verdict":"ok|minor|major|wrong","defects":[{"defect":"short factual defect","failingCase":"concrete input or scenario and the wrong result it produces"}],"confidence":0-100}
- ok    = correct and complete
- minor = cosmetic or optional improvements only
- major = real defects that change the outcome for the user
- wrong = the core answer is incorrect
EVERY defect MUST carry a failingCase: a concrete input, call or scenario where the draft
produces a wrong or missing result. If you cannot name one, it is not a defect - leave it out.
A defect you cannot demonstrate is an opinion, and it will be discarded.
List at most 5 defects, each short and checkable. Do not rewrite the answer here.

TASK:
$task

REPOSITORY CONTEXT:
$contextBlock

DRAFT ANSWER:
$draftForReview
"@

    # Falls over to the other backend rather than giving up: an exhausted
    # OpenCode free tier must not stop Delegator while the Google keys still
    # have quota.
    $checkResult = Invoke-DelegateAcrossBackends -ChosenBackend $reviewBackend -Text $checkPrompt -ChosenModel $reviewModel -EffectiveComplexity "deep"
    if ($checkResult.fellBack) {
        $reviewBackend = $checkResult.backend
        $reviewModel = $checkResult.model
        $script:FinalModel = $reviewModel
        $script:FinalProvider = Get-UsageProviderName $reviewBackend
    }
    $checkText = (($checkResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($checkResult.exitCode -ne 0) {
        Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "check-failed" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain
        [Console]::Error.WriteLine("[Delegator] improve: every backend failed, keeping your draft")
        Exit-Delegate 1
    }
    $verdictObj = Get-ImproveVerdict $checkText
    $verdict = if ($verdictObj -and $verdictObj.verdict) { ([string]$verdictObj.verdict).Trim().ToLowerInvariant() } else { "" }
    # Only defects the reviewer could demonstrate survive: see Get-SupportedDefects.
    $defects = @()
    $claimed = 0
    if ($verdictObj -and $verdictObj.defects) {
        $claimed = @($verdictObj.defects).Count
        $defects = @(Get-SupportedDefects $verdictObj.defects)
    }
    $unsupported = [math]::Max(0, $claimed - $defects.Count)
    if ($verdict -notin @("ok", "minor", "major", "wrong")) {
        # An unparsable verdict is not evidence of a defect - unless the compiler
        # already found one, and then the reviewer's opinion is not needed.
        if ($mechanical.Count -eq 0) {
            Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "verdict-unparsable" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain
            Exit-Delegate 3
        }
        $verdict = "major"
    }
    # A proven defect outranks the reviewer. Run #4: the reviewer said "ok" about
    # a query SQLite refuses to prepare, and the broken draft was returned as-is.
    $defects = @($mechanical + $defects | Select-Object -Unique)
    if ($mechanical.Count -gt 0 -and $verdict -in @("ok", "minor")) { $verdict = "major" }
    if ($verdict -in @("ok", "minor") -or $defects.Count -eq 0) {
        # `unsupported` is the tuning signal: how often the reviewer claimed a
        # defect it could not demonstrate. Watch it in delegate-metrics.jsonl.
        Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "keep-$verdict" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),unsupported=$unsupported,calls=1,ctxmissing=$($script:ImproveMissingContext)"
        if ($callerWantsJson) {
            [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = "keep"; output = "" } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    $defectList = "- " + ($defects -join "`n- ")
    $rewriteBody = @"
Rewrite the DRAFT ANSWER below so that every listed defect is fixed.
Keep everything that was already correct, keep the same structure, format and level of detail, and keep every constraint of the task.
Output the corrected answer only: no preamble, no explanation of the changes, no review notes.

TASK:
$task

REPOSITORY CONTEXT:
$contextBlock

DEFECTS TO FIX:
$defectList

DRAFT ANSWER:
$draftForReview
"@
    $rewritePrompt = Add-ExecutionLanguagePolicy $rewriteBody

    # Same failover on the second call: the free tier can run out between the
    # review and the rewrite, and half a delegation is worth nothing.
    $rewriteResult = Invoke-DelegateAcrossBackends -ChosenBackend $reviewBackend -Text $rewritePrompt -ChosenModel $reviewModel -EffectiveComplexity "deep"
    if ($rewriteResult.fellBack) {
        $reviewBackend = $rewriteResult.backend
        $reviewModel = $rewriteResult.model
        $script:FinalModel = $reviewModel
        $script:FinalProvider = Get-UsageProviderName $reviewBackend
    }
    $improved = Filter-ConversationalNoise ((($rewriteResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim())
    if ($rewriteResult.exitCode -ne 0) {
        Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "rewrite-failed" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=2,ctxmissing=$($script:ImproveMissingContext)"
        [Console]::Error.WriteLine("[Delegator] improve: the rewrite failed, keeping your draft")
        Exit-Delegate 1
    }
    # The rewrite gets the same mechanical treatment as the draft did. Benchmark
    # run #8: a 13/13 answer came back as 2/13 because the rewrite used
    # re.fullmatch and put `import re` in a SEPARATE block with a note to move
    # it. Nothing checked the rewrite at all - only the draft was ever linted.
    $rewriteProblems = @(Get-MechanicalDefects -Task $task -Draft $draft -Rewrite $improved -WantRewriteDefects)
    if ($rewriteProblems.Count -gt 0) {
        Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "guard-rewrite-broken" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=2,guard=fail,reason=$($rewriteProblems[0])"
        [Console]::Error.WriteLine("[Delegator] improve: rewrite is worse than the draft, keeping yours - $($rewriteProblems[0])")
        if ($callerWantsJson) {
            [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = "rewrite-broken"; output = "" } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    $guard = Test-ImproveGuards -Draft $draft -Improved $improved
    if (-not [string]::IsNullOrWhiteSpace($guard)) {
        Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "guard-$guard" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=2,guard=fail,ctxmissing=$($script:ImproveMissingContext)"
        [Console]::Error.WriteLine("[Delegator] improve: rewrite rejected by guard '$guard', keeping your draft")
        if ($callerWantsJson) {
            [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = $guard; output = "" } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    Write-DelegateMetric -Stage "improve" -Model $reviewModel -Backend $reviewBackend -Status "improved-$verdict" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=2,guard=pass,ctxmissing=$($script:ImproveMissingContext)"
    if ($callerWantsJson) {
        [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = "pass"; output = $improved } | ConvertTo-Json -Depth 4
    } else {
        $header = [pscustomobject]@{
            verdict = $verdict
            defects = $defects.Count
            model   = $reviewModel
        } | ConvertTo-Json -Compress
        Write-Output ("##DELEGATOR_IMPROVE## " + $header)
        Write-Output $improved
    }
    Exit-Delegate 0
}

function Run-Ask {
    $askSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }

    # ── Response cache lookup ──
    if ($Prompt -notmatch "^Reply exactly:" -and $Backend -eq "auto" -and [string]::IsNullOrWhiteSpace($Model)) {
        $promptHash = Get-PromptHash $Prompt -Variant (Get-CacheVariant)
        $cachedDomain = Get-TaskDomain $Prompt
        $cachedResponse = Find-CachedResponse -PromptHash $promptHash -Domain $cachedDomain
        if ($cachedResponse) {
            Write-DelegateMetric -Stage "cache-hit" -Status "ok" -LatencyMs $askSw.ElapsedMilliseconds -Domain $cachedDomain
            $cachedResponse
            return
        }
    }

    # Forced backend mode: skip planner/triage to avoid extra latency and duplicate timeouts.
    if ($Backend -ne "auto") {
        $forcedModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { Get-PreferredBackendModel -BackendName $Backend -Text $Prompt }
        $executionPrompt = Add-ExecutionLanguagePolicy $Prompt
        if ($DiffOnly) {
            $executionPrompt = $executionPrompt + "`n`nIMPORTANT SYSTEM RULE: You must return the output ONLY as a clean Unified Diff showing the edits. Do not write full files, only the diff block."
        }
        $direct = Invoke-Delegate -ChosenBackend $Backend -Text $executionPrompt -ChosenModel $forcedModel -EffectiveComplexity $Complexity
        if ($direct.exitCode -eq 0) {
            if (-not [string]::IsNullOrWhiteSpace($forcedModel)) {
                $script:FinalModel = [string]$forcedModel
                $script:FinalProvider = Get-UsageProviderName $Backend
            }
            $final = Filter-ConversationalNoise $direct.output
            $final
            return
        }
        if ($Backend -eq "puter") {
            Write-Warning "Puter backend failed; trying opencode fallback."
            $fallbackModel = Get-PreferredBackendModel -BackendName "opencode" -Text $Prompt
            if ([string]::IsNullOrWhiteSpace($fallbackModel)) { $fallbackModel = "opencode/deepseek-v4-flash-free" }
            $fallbackResult = Invoke-Delegate -ChosenBackend "opencode" -Text $executionPrompt -ChosenModel $fallbackModel -EffectiveComplexity $Complexity
            $final = Filter-ConversationalNoise $fallbackResult.output
            $final
            Exit-Delegate $fallbackResult.exitCode
        }
        $direct.output
        Exit-Delegate $direct.exitCode
    }

    # The planner and the triage stage cost one call each on the WEAKEST enabled
    # model and only decide routing. With an explicit -Model, or inside a boost
    # fan-out, the routing is already fixed, so both are pure latency and pure
    # risk of a rewritten prompt.
    $skipRouting = (-not [string]::IsNullOrWhiteSpace($Model)) -or ($env:CODEX_DELEGATE_BOOST_ACTIVE -eq "1") -or $NoPlanner
    $plan = if ($skipRouting) { $null } else { Read-DelegationPlan $Prompt }
    if ($plan -and $plan.mode -eq "parallel") {
        $planPromptCount = @($plan.prompts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
        if ($planPromptCount -ge 2) {
            Invoke-PlannedParallel -Plan $plan
            return
        }
        # Planner suggested parallel without enough prompts: fall through to single-solve.
    }

    $plannedModel = if ($plan -and -not [string]::IsNullOrWhiteSpace([string]$plan.model)) { [string]$plan.model } else { "" }
    $plannedComplexity = if ($plan -and $plan.complexity -in @("fast", "normal", "deep", "auto")) { [string]$plan.complexity } else { $Complexity }
    $plannedBackend = if ($plan -and $plan.backend -in @("auto", "gemini", "opencode")) { [string]$plan.backend } else { "auto" }
    $plannedPrompt = if ($plan -and $plan.prompts -and @($plan.prompts).Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]@($plan.prompts)[0])) { [string]@($plan.prompts)[0] } else { $Prompt }
    $plannedPreprocess = if ($plan -and $plan.preprocess -in @("none", "extract")) { [string]$plan.preprocess } else { "none" }
    $plannedVerify = [bool]($plan -and $plan.verify)
    $mustHave = @()
    if ($plan -and $plan.mustHave) { $mustHave = @($plan.mustHave | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ }) }

    $triage = $null
    if (-not $plan -and -not $skipRouting) {
        $triage = Invoke-StructuredTriage $plannedPrompt
        if ($triage) {
            if ($triage.mode -eq "parallel" -and $triage.PSObject.Properties["prompts"]) {
                $items = @($triage.prompts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($items.Count -ge 2) {
                    Invoke-ParallelDelegate -PromptList @($items | ForEach-Object { [string]$_ }) -Cx ([string]$triage.complexity) -AsJson ([bool]$Json) -NoDiverse ([bool]$NoDiverseModels)
                    Exit-Delegate $script:LastParallelExitCode
                }
            }
            if ($triage.complexity -in @("fast", "normal", "deep", "auto")) { $plannedComplexity = [string]$triage.complexity }
            if ($triage.backend -in @("auto", "gemini", "opencode")) { $plannedBackend = [string]$triage.backend }
            if ($triage.preprocess -in @("none", "extract")) { $plannedPreprocess = [string]$triage.preprocess }
            $plannedVerify = [bool]$triage.verify
            if ($triage.mustHave) { $mustHave = @($triage.mustHave | ForEach-Object { [string]$_ }) }
        } else {
            # Triage failed — use safe defaults: first ranked free model, normal complexity
            Write-DelegateMetric -Stage "triage-fallback" -Status "triage-null" -Domain (Get-TaskDomain $plannedPrompt)
            $plannedComplexity = "normal"
        }
    }

    # Compressing the prompt runs the WEAKEST enabled model over it and replaces
    # it with that model's summary. On a code task that throws away the very
    # thing the strong model was called for, so the bar is high: only really
    # long input, and never when the caller pinned the model (it knows what it
    # sent) or handed us its own draft to review.
    $extractLimit = 12000
    if ((-not $skipRouting) -and (($plannedPreprocess -eq "extract" -and $plannedPrompt.Length -gt 4000) -or ($plannedPrompt.Length -gt $extractLimit))) {
        $plannedPrompt = Invoke-ContextExtract -Text $plannedPrompt -MustHave $mustHave
    }
    if ($mustHave.Count -gt 0) {
        $plannedPrompt = "MUST-HAVE CONSTRAINTS:`n- " + ($mustHave -join "`n- ") + "`n`nTASK:`n" + $plannedPrompt
    }

    $taskDomain = Get-TaskDomain $plannedPrompt
    $isHeavyTask = $taskDomain -match "architecture|security|code_debug|context_analysis|math_algo|data_consistency"

    $chosenModel = if (-not [string]::IsNullOrWhiteSpace($plannedModel)) {
        $plannedModel
    } elseif ($plannedComplexity -eq "deep" -or $plannedVerify -or (Test-VisionContent $plannedPrompt)) {
        Select-RankedDelegateModel $plannedPrompt
    } else {
        ""
    }

    $forcedBackend = if ($Backend -ne "auto") { $Backend } elseif ($plannedBackend -ne "auto") { $plannedBackend } else { "auto" }
    if ($forcedBackend -ne "auto" -and [string]::IsNullOrWhiteSpace($Model) -and -not (Test-ModelMatchesBackend $chosenModel $forcedBackend)) {
        $chosenModel = Get-PreferredBackendModel -BackendName $forcedBackend -Text $plannedPrompt
    }

    # Strength floor, applied AFTER the backend correction on purpose: the
    # backend hint comes from the triage model and its "preferred model" for a
    # backend is a flash-class one, so running the floor earlier only to have it
    # overwritten here is exactly what happened the first time round.
    #
    # An empty (or flash-class) model means "let the backend decide", and the
    # backend decides small - the caller, often a fast IDE model, then gets an
    # answer from a model no stronger than itself. Everything deep, verified or
    # from a heavy domain is pinned to the strongest enabled model instead, and
    # the model decides the backend from there on. Vision is excluded: those ids
    # come from Get-PreferredVisionModel and must stay.
    if ([string]::IsNullOrWhiteSpace($Model) `
            -and ($plannedComplexity -eq "deep" -or $plannedVerify -or $isHeavyTask) `
            -and ([string]::IsNullOrWhiteSpace($chosenModel) -or $chosenModel -match "flash|lite|mini|tiny|nano") `
            -and -not (Test-VisionContent $plannedPrompt)) {
        $strongModel = Get-StrongEnabledModel
        if (-not [string]::IsNullOrWhiteSpace($strongModel) -and $strongModel -ne $chosenModel) {
            Write-DelegateMetric -Stage "strength-floor" -Model $strongModel -Status "ok" -Domain $taskDomain -Extra "was=$chosenModel"
            $chosenModel = $strongModel
            $plannedBackend = "auto"
        }
    }
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { $chosenModel }
    $hasVisionContent = Test-VisionContent $plannedPrompt
    if ($hasVisionContent -and -not (Test-ModelSupportsVision $effectiveModel)) {
        $visionModel = Get-PreferredVisionModel
        if (-not [string]::IsNullOrWhiteSpace($Model)) {
            Write-Error "The requested model '$Model' is text-only and cannot receive image/vision content. Use a supportsVision=true model such as '$visionModel'."
            Exit-Delegate 2
        }
        $chosenModel = $visionModel
        $effectiveModel = $visionModel
        $plannedBackend = "gemini"
    }
    $executionPrompt = Add-ExecutionLanguagePolicy $plannedPrompt
    if ($DiffOnly) {
        $executionPrompt = $executionPrompt + "`n`nIMPORTANT SYSTEM RULE: You must return the output ONLY as a clean Unified Diff showing the edits. Do not write full files, only the diff block."
    }

    # BOOST MODE can fan out multiple model calls.
    # Keep it explicit by default; auto-enable only for genuinely heavy flash-routed tasks.
    $boostEnabled = $Boost -or ($env:CODEX_DELEGATE_BOOST -eq "1")
    # "flash" alone missed lite/mini/tiny ids. An EMPTY model is deliberately not
    # weak here: after the strength floor above it only stays empty when nothing
    # is enabled, and fanning out to three advisors that cannot run helps nobody.
    $isFlash = $effectiveModel -match "flash|lite|mini|tiny|nano"

    # Auto-boost only when a weak model is selected for a heavy/deep task.
    if ($isFlash -and -not $NoBoost -and ($plannedComplexity -eq "deep" -or $isHeavyTask)) {
        $boostEnabled = $true
    }

    # Protection against infinite recursion in nested delegate calls
    if ($env:CODEX_DELEGATE_BOOST_ACTIVE -eq "1") {
        $boostEnabled = $false
    }

    if ($boostEnabled -and $plannedComplexity -in @("auto", "normal", "deep")) {
        # Heavy domains warrant Pro directly or a 3-advisor ensemble.
        $isHeavy = $isHeavyTask

        if ($isHeavy) {
            # Heavy task -> try Gemini Pro directly first.
            $proBackend = Select-ProBackendByQuota
            $proModel = "gemini-pro-latest"
            $proResult = Invoke-Delegate -ChosenBackend $proBackend -Text $executionPrompt -ChosenModel $proModel -EffectiveComplexity "deep"
            if ($proResult.exitCode -eq 0 -and $proResult.output -notmatch "RESOURCE_EXHAUSTED|quota|limit exceeded|All Gemini profiles failed") {
                $script:FinalModel = $proModel
                $script:FinalProvider = Get-UsageProviderName $proBackend
                $final = Filter-ConversationalNoise $proResult.output
                if ($plannedVerify) {
                    $final = Invoke-CritiqueCorrectionLoop -OriginalPrompt $plannedPrompt -InitialAnswer $final -Model $proModel -Backend $proBackend -Complexity "deep" -MustHave $mustHave
                }
                $final
                return
            }
            # Pro unavailable (quota) -> 3-advisor ensemble, synthesis on the orchestrator model.
            $res = Run-Boost -Text $plannedPrompt -Count 3 -SynthModelName (Get-OrchestratorModel)
            if ($res) {
                $final = Filter-ConversationalNoise $res
                $final
                return
            }
        } else {
            # Light task -> 2-advisor ensemble, synthesis on the orchestrator model.
            $res = Run-Boost -Text $plannedPrompt -Count 2 -SynthModelName (Get-OrchestratorModel)
            if ($res) {
                $final = Filter-ConversationalNoise $res
                $final
                return
            }
        }
    }

    $first = if ($plannedBackend -ne "auto") { $plannedBackend } else { Select-Backend -Text $plannedPrompt -ChosenModel $chosenModel }
    $second = if ($first -eq "opencode") { "gemini" } else { "opencode" }
    if ($hasVisionContent -and $first -eq "opencode") {
        Write-Error "Vision/image content cannot be delegated to text-only OpenCode/OpenRouter models. Use a supportsVision=true model."
        Exit-Delegate 2
    }

    $solveSw = [System.Diagnostics.Stopwatch]::StartNew()
    $firstResult = Invoke-DelegateWithRetry -ChosenBackend $first -Text $executionPrompt -ChosenModel $chosenModel -EffectiveComplexity $plannedComplexity
    if ($firstResult.exitCode -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($effectiveModel)) {
            $script:FinalModel = [string]$effectiveModel
            $script:FinalProvider = Get-UsageProviderName $first
        }
        $final = Filter-ConversationalNoise $firstResult.output
        Write-DelegateMetric -Stage "solve" -Model $effectiveModel -Backend $first -LatencyMs $solveSw.ElapsedMilliseconds -Status "ok" -Domain $taskDomain

        # ── Confidence check: skip verify if cheap model answer is high-confidence ──
        if ($plannedVerify -and -not (Test-ResponseConfidence -Response $final -Domain $taskDomain -OriginalPrompt $plannedPrompt)) {
            $final = Invoke-CritiqueCorrectionLoop -OriginalPrompt $plannedPrompt -InitialAnswer $final -Model $effectiveModel -Backend $first -Complexity $plannedComplexity -MustHave $mustHave
        } elseif ($plannedVerify) {
            Write-DelegateMetric -Stage "verify-skip" -Status "high-confidence" -Domain $taskDomain
        }

        # ── Cache the response ──
        if ($Backend -eq "auto" -and [string]::IsNullOrWhiteSpace($Model) -and $Prompt -notmatch "^Reply exactly:") {
            $cacheHash = Get-PromptHash $Prompt -Variant (Get-CacheVariant)
            Add-CachedResponse -PromptHash $cacheHash -Response $final -Model $effectiveModel -Domain $taskDomain
        }

        $final
        return
    }

    # Note: $Backend is always "auto" here (forced-backend path exits at line ~832).

    if (-not [string]::IsNullOrWhiteSpace($Model)) {
        $firstResult.output
        Exit-Delegate $firstResult.exitCode
    }

    if ($hasVisionContent -and $second -eq "opencode") {
        $firstResult.output
        Exit-Delegate $firstResult.exitCode
    }
    Write-Warning "Primary delegate '$first' failed; trying '$second'."
    $secondResult = Invoke-Delegate -ChosenBackend $second -Text $executionPrompt -EffectiveComplexity $plannedComplexity
    if ($secondResult.exitCode -eq 0) {
        $script:FinalProvider = Get-UsageProviderName $second
    }
    $final = Filter-ConversationalNoise $secondResult.output
    $fallbackOk = ($secondResult.exitCode -eq 0)
    Write-DelegateMetric -Stage "solve-fallback" -Backend $second -LatencyMs $solveSw.ElapsedMilliseconds -Status $(if ($fallbackOk) { "ok" } else { "failed" }) -Domain $taskDomain
    if ($fallbackOk -and $plannedVerify -and -not (Test-ResponseConfidence -Response $final -Domain $taskDomain -OriginalPrompt $plannedPrompt)) {
        $final = Invoke-CritiqueCorrectionLoop -OriginalPrompt $plannedPrompt -InitialAnswer $final -Model $effectiveModel -Backend $second -Complexity $plannedComplexity -MustHave $mustHave
    }

    # Cache the fallback response - only when it IS a response. Both backends
    # failing used to store "All enabled Delegator ... failed" under the prompt
    # hash, and every identical question was then answered from the cache with
    # that error text for the next 24 hours (seen live 2026-08-12).
    if ($fallbackOk -and $Backend -eq "auto" -and [string]::IsNullOrWhiteSpace($Model) -and $Prompt -notmatch "^Reply exactly:") {
        $cacheHash = Get-PromptHash $Prompt -Variant (Get-CacheVariant)
        Add-CachedResponse -PromptHash $cacheHash -Response $final -Model $effectiveModel -Domain $taskDomain
    }

    $final
    Exit-Delegate $secondResult.exitCode
}

# ── `usage` subcommand: plain-text savings summary from usage.jsonl ──
function Run-Usage {
    $windowDays = [Math]::Max(1, $Days)
    $usagePath = $script:DelegateUsageLogFile
    if (-not (Test-Path -LiteralPath $usagePath)) {
        Write-Output "No usage data recorded yet ($usagePath)."
        exit 0
    }
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$windowDays)
    $lines = @()
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new($false, "Global\DelegatorUsageLog")
        $null = $mutex.WaitOne(3000)
        $lines = @([System.IO.File]::ReadAllLines($usagePath))
    } catch {
        $lines = @(Get-Content -LiteralPath $usagePath -ErrorAction SilentlyContinue)
    } finally {
        if ($null -ne $mutex) {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    }

    $records = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $r = $null
        try { $r = $line | ConvertFrom-Json } catch { continue }
        if ($null -eq $r) { continue }
        $ts = [datetime]::MinValue
        $parsedTs = [datetime]::TryParse([string]$r.ts,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$ts)
        if (-not $parsedTs -or $ts -lt $cutoff) { continue }
        $records += $r
    }
    if ($records.Count -eq 0) {
        Write-Output "No usage records in the last $windowDays day(s)."
        exit 0
    }

    $requestIds = @{}
    $noIdCount = 0
    $pt = 0.0; $ct = 0.0; $tt = 0.0; $cost = 0.0
    $byProvider = @{}
    $byModel = @{}
    foreach ($r in $records) {
        $rid = [string]$r.requestId
        if ([string]::IsNullOrWhiteSpace($rid)) { $noIdCount++ } else { $requestIds[$rid] = $true }
        $rtt = Get-UsageNumber $r "totalTokens"
        $pt += Get-UsageNumber $r "promptTokens"
        $ct += Get-UsageNumber $r "completionTokens"
        $tt += $rtt
        $cost += Get-UsageNumber $r "cost"
        $prov = [string]$r.provider
        if ([string]::IsNullOrWhiteSpace($prov)) { $prov = "unknown" }
        if (-not $byProvider.ContainsKey($prov)) { $byProvider[$prov] = @{ calls = 0; tokens = 0.0 } }
        $byProvider[$prov].calls++
        $byProvider[$prov].tokens += $rtt
        $modelName = [string]$r.model
        if ([string]::IsNullOrWhiteSpace($modelName)) { $modelName = "unknown" }
        if (-not $byModel.ContainsKey($modelName)) { $byModel[$modelName] = @{ calls = 0; tokens = 0.0 } }
        $byModel[$modelName].calls++
        $byModel[$modelName].tokens += $rtt
    }
    $requestCount = @($requestIds.Keys).Count + $noIdCount

    Write-Output ("Delegator usage - last {0} day(s)" -f $windowDays)
    Write-Output ("Requests: {0}" -f $requestCount)
    Write-Output ("Total tokens: {0} (prompt {1}, completion {2})" -f [long]$tt, [long]$pt, [long]$ct)
    Write-Output ("Reported cost: {0}" -f [Math]::Round($cost, 4))
    Write-Output "Tokens by provider:"
    foreach ($k in @($byProvider.Keys | Sort-Object { $byProvider[$_].tokens } -Descending)) {
        Write-Output ("  {0}: {1} tokens ({2} calls)" -f $k, [long]$byProvider[$k].tokens, $byProvider[$k].calls)
    }
    Write-Output "Top models:"
    foreach ($k in @($byModel.Keys | Sort-Object { $byModel[$_].tokens } -Descending | Select-Object -First 5)) {
        Write-Output ("  {0}: {1} tokens ({2} calls)" -f $k, [long]$byModel[$k].tokens, $byModel[$k].calls)
    }
    exit 0
}

# The finally block guarantees the per-request usage file is aggregated/removed and
# the ##DELEGATOR_USAGE## marker (when requested) is the LAST stdout line, on every
# exit path including `exit` inside the Run-* handlers.
try {
switch ($Command) {
    "ask" { Run-Ask }
    "delegate" { Run-Ask }
    "boost" { $Boost = $true; Run-Ask }
    "improve" { Run-Improve }
    "micro" { Run-Micro }
    "verify" { Run-Verify }
    "plan" { Run-Plan }
    "triage" { Run-Triage }
    "extract" { Run-Extract }
    "parallel" { Run-Parallel }
    "ui" { Run-UI }
    "policy" { Run-Policy }
    "usage" { Run-Usage }
    "status" {
        & $GeminiDelegate "status" "-Json"
    }
    "models" {
        $rankings = Read-ModelRankings
        if ($rankings -and $rankings.overall) {
            Write-Output "Model order: intelligence + programming usefulness"
            $seen = @{}
            foreach ($row in @($rankings.overall)) {
                $name = [string]$row.model
                if (-not [string]::IsNullOrWhiteSpace($name) -and -not [bool](Get-ModelSettingValue $name "disabled")) {
                    $seen[$name] = $true
                    Write-Output ("- {0}" -f $name)
                }
            }
            $extras = @(
                "opencode/deepseek-v4-flash-free",
                "opencode/nemotron-3-ultra-free",
                "opencode/laguna-s-2.1-free",
                "opencode/ling-3.0-flash-free",
                "opencode/mimo-v2.5-free",
                "opencode/north-mini-code-free"
            )
            $missing = @($extras | Where-Object { -not $seen.ContainsKey($_) -and -not [bool](Get-ModelSettingValue $_ "disabled") })
            if ($missing.Count -gt 0) {
                Write-Output "Enabled extra free models (unranked yet):"
                foreach ($name in $missing) {
                    Write-Output ("- {0}" -f $name)
                }
            }
            $disabledExtras = @($extras | Where-Object { [bool](Get-ModelSettingValue $_ "disabled") })
            if ($disabledExtras.Count -gt 0) {
                Write-Output "Temporarily unavailable upstream:"
                foreach ($name in $disabledExtras) {
                    Write-Output ("- {0} [disabled]" -f $name)
                }
            }
        } else {
            Write-Output "Gemini routing: native generateContent with DPAPI accounts stored by Delegator; system environment keys are ignored"
            Write-Output "Gemini API catalog: gemini-pro-latest, gemini-flash-latest, gemini-flash-lite-latest"
            Write-Output "OpenCode default models: opencode/deepseek-v4-flash-free, opencode/nemotron-3-ultra-free, opencode/laguna-s-2.1-free, opencode/ling-3.0-flash-free, opencode/mimo-v2.5-free, opencode/north-mini-code-free (Big Pickle is available but disabled by default)"
        }
    }
}
} finally {
    Complete-DelegateUsage
}
exit 0

param(
    [Parameter(Position = 0)]
    [ValidateSet("assist", "ask", "delegate", "boost", "improve", "micro", "verify", "plan", "parallel", "ui", "status", "models", "policy", "triage", "extract", "usage", "ping")]
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

    # The model that is CALLING us, as its own provider names it, including any
    # reasoning-effort suffix (`gemini-3.7-flash-low`, `claude-opus-5`).
    # DEV_CONTRACTS §13: it decides whether this request is an economy case
    # (we match the caller, so take the work off it) or an amplification case
    # (we are clearly stronger, so spend on quality). Omitted -> routed exactly
    # as before §13. Env fallback: DELEGATOR_CALLER_MODEL.
    [string]$CallerModel,

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
        "--callermodel" { if ($i + 1 -lt $rawPrompts.Count) { $CallerModel = [string]$rawPrompts[++$i] }; continue }
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

function Test-ErrorClassIsQualitySignal {
    <#
      Does a failure of this class say anything about the MODEL?

      The rule is CORRELATION. A class every candidate in the ladder suffers
      identically is a fact about the environment, the account or the prompt, and
      attributing it to models demotes the whole pool at once. That did not matter
      while a run wrote ONE usage record; since 0.7.2 it writes one per rung, so
      an offline laptop marks every enabled model in a single delegation.

      - rate_limit, auth  - time-bounded ACCOUNT states, already tracked precisely
        and WITH AN EXPIRY in cooldowns.json / google-api-usage.json (G29).
      - network           - the machine or the proxy is down. Every rung reports
        `unable to connect`; none of them was ever reached.
      - context_overflow  - a statement about the PROMPT. One oversized
        -ContextFile makes every model in the pool look broken.

      Health has no expiry: a sample only leaves when twelve newer calls of that
      model push it out. So a demotion earned during a two-minute outage outlives
      it by days, and nothing prints health, so nobody would see why the strength
      floor had quietly inverted into a weakness floor.

      server / timeout / not_found / content_policy / unknown DO count. They can
      be correlated too, but they are also exactly the per-model failures N3 exists
      to catch, and their cooldowns are short.

      A record with no errorClass at all counts: everything written before 0.7.2
      lacks the field, and dropping those would erase the router's memory on
      upgrade.
    #>
    param([string]$ErrorClass)
    return ([string]$ErrorClass -notin @("rate_limit", "auth", "network", "context_overflow"))
}

# Below this many samples a failure rate is an anecdote, not a rate. Kept next to
# the health helpers because Test-ModelAffordable is the only reader.
$script:DelegateMinHealthSamples = 3

function Clear-ModelLatencyCache {
    # usage.jsonl is read once per process. Tests write a log per case, so they
    # need to drop the memo; nothing in production calls this.
    $script:ModelLatencyStats = $null
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
            if (-not $isOk) {
                $errorClass = ""
                try { $errorClass = [string]$row.errorClass } catch {}
                # Not a sample at all, rather than a successful one: a quota day
                # is silence about the model, not evidence in its favour.
                if (-not (Test-ErrorClassIsQualitySignal $errorClass)) { continue }
            }
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
    if ($null -eq $health.p75Ms) {
        # No successful call in the window, so there is no latency to judge -
        # only a failure rate, and a rate over one or two samples is not a rate.
        # The four-sample floor above exists for exactly that reason and this
        # branch used to bypass it: ONE failure with no success beside it read as
        # failRate 1.0 and the model was dropped.
        #
        # That was survivable while a run wrote a single usage record. Since the
        # ladder writes one per rung (section 2.1), a single provider outage marks
        # every rung it touched, each with one failure and no success - so one bad
        # run demoted the whole pool and Get-StrongEnabledModel fell through to the
        # FASTEST model. Measured here: a 23-rung ladder left every model
        # samples=1, failRate=1, affordable=False.
        if ($health.samples -lt $script:DelegateMinHealthSamples) { return $true }
        return ($health.failRate -lt 0.5)
    }
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
    # Strength of one model id on the DPR scale: the Zen catalog when it carries
    # the id (it is written from the same ratings table), otherwise the shipped
    # model-ratings.json directly. The catalog only ever holds `opencode/*` Zen
    # aliases, so WITHOUT the ratings lookup every other provider - including
    # agentrouter/claude-opus-5, the strongest model the user owns - fell back to
    # a flat neutral score and could never reach the deep pool.
    #
    # An unrated model gets DelegateUnratedDpr (normal tier) rather than 0 or a
    # guess: measured health then decides whether it is worth trying.
    param([string]$ModelId, [hashtable]$Catalog)
    if ($Catalog -and $Catalog.ContainsKey($ModelId)) { return [int]$Catalog[$ModelId] }
    $rating = Get-DelegatorModelRating $ModelId
    if ($null -ne $rating) { return [int]$rating }
    return [int]$script:DelegateUnratedDpr
}

# ── Caller strength (DEV_CONTRACTS §13) ──────────────────────────────────────
# A reasoning-effort suffix is NOT a different model in the ratings table, but it
# is a different model in practice. `model-ratings.json` carries one row per
# model, and the longest-substring lookup therefore scores
# `gemini-3.7-flash-low` exactly like `gemini-3.7-flash` - 152, seventh of 196,
# above claude-opus-4-8. An agent running that model at low effort is nothing
# like that number, and routing it as if it were would hand it the ECONOMY path
# when what it needs is amplification.
#
# The penalty lives here rather than in the table on purpose (I10): the table is
# a snapshot of a published index and must never be hand-edited, and the index
# publishes one figure per model, not one per effort level. This is an explicit,
# reviewable correction sitting on top of it - and it applies ONLY to the caller.
# The models Delegator answers with always run at their own default effort.
$script:DelegateEffortPenalty = @{
    "minimal" = 35
    "low"     = 25
    "medium"  = 12
    "high"    = 0
    "xhigh"   = 0
    "max"     = 0
}

function Get-CallerEffortPenalty {
    # DPR points to subtract for a trailing reasoning-effort token, 0 when the id
    # carries none. Recognised only at the END of the id: `gpt-5.3-codex-high` is
    # an effort level, `low-latency-v2` is a model name.
    param([string]$ModelId)
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return 0 }
    if ([string]$ModelId -match '(?i)[-_:\s]((?:x)?high|minimal|low|medium|max)$') {
        $token = $Matches[1].ToLowerInvariant()
        if ($script:DelegateEffortPenalty.ContainsKey($token)) {
            return [int]$script:DelegateEffortPenalty[$token]
        }
    }
    return 0
}

function Get-CallerDpr {
    <#
      The DPR of the model that called us, effort-adjusted, or 0 for "did not
      say". Zero is not a low score - it is the absence of a comparison, and the
      router routes an undeclared caller exactly as it did before §13 existed.

      Precedence: -CallerModel, then DELEGATOR_CALLER_MODEL. An id we have no row
      for stays 0: guessing a number for an unknown model would make the router
      act on a fabrication, and `unrated` (100) is a deliberate MID value that
      would read as a weak caller and trigger amplification nobody asked for.
    #>
    param([string]$ModelId = "")
    if ([string]::IsNullOrWhiteSpace($ModelId)) { $ModelId = [string]$env:DELEGATOR_CALLER_MODEL }
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return 0 }
    $rating = Get-DelegatorModelRating $ModelId
    if ($null -eq $rating) { return 0 }
    $score = [int]$rating - (Get-CallerEffortPenalty $ModelId)
    if ($score -lt 1) { $score = 1 }
    return $score
}

function Get-CallerRatingConfidence {
    # Confidence of the CALLER's row, resolved the same way as its score so the
    # two always describe the same row. §13.6.
    param([string]$ModelId = "")
    if ([string]::IsNullOrWhiteSpace($ModelId)) { $ModelId = [string]$env:DELEGATOR_CALLER_MODEL }
    return (Get-DelegatorRatingConfidence $ModelId)
}

function Get-BestAvailableDpr {
    # DPR of the strongest model we can actually reach right now - the same pick
    # Get-StrongEnabledModel makes, so the router compares the caller against the
    # model that would really answer, not against the best row in the table.
    # 0 when nothing is enabled or nothing is rated: no comparison is possible.
    $web = Get-WebBestStrength
    $best = Get-StrongEnabledModel
    if ([string]::IsNullOrWhiteSpace($best)) { return $web }
    $rating = Get-DelegatorModelRating $best
    if ($null -eq $rating) {
        $strengths = Get-ZenCatalogStrengthMap
        if ($strengths -and $strengths.ContainsKey($best)) { return [math]::Max($web, [int]$strengths[$best]) }
        return $web
    }
    return [math]::Max($web, [int]$rating)
}

function Get-RecentHardFailedModels {
    # Models whose LAST recorded call failed for a reason about the PROVIDER (network,
    # auth) within the last 30 minutes, and has not succeeded since. Health ignores those
    # classes on purpose (they say nothing about answer quality), so nothing else stopped
    # the strength floor from picking a provider that was refusing every call.
    $result = @{}
    $usageFile = Join-Path $script:DelegateHome "usage.jsonl"
    if (-not (Test-Path -LiteralPath $usageFile)) { return $result }
    $last = @{}
    try {
        $lines = @([System.IO.File]::ReadAllLines($usageFile))
        if ($lines.Count -gt 400) { $lines = @($lines[($lines.Count - 400)..($lines.Count - 1)]) }
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $null
            try { $row = $line | ConvertFrom-Json } catch { continue }
            $id = [string]$row.model
            if ([string]::IsNullOrWhiteSpace($id)) { continue }
            $last[$id] = $row
        }
    } catch {}
    $cutoff = [DateTimeOffset]::UtcNow.AddMinutes(-30)
    foreach ($id in @($last.Keys)) {
        $row = $last[$id]
        $isOk = $true
        try { if ($row.PSObject.Properties["ok"] -and $null -ne $row.ok) { $isOk = [bool]$row.ok } } catch {}
        if ($isOk) { continue }
        $errorClass = ""
        try { $errorClass = [string]$row.errorClass } catch {}
        if ($errorClass -notin @("network", "auth")) { continue }
        $when = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$row.ts, [ref]$when)) { continue }
        if ($when -lt $cutoff) { continue }
        $result[$id] = $true
    }
    return $result
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
    $hardFailed = Get-RecentHardFailedModels
    if ($hardFailed.Count -gt 0) {
        $healthy = @($enabled | Where-Object { -not $hardFailed.ContainsKey($_) })
        if ($healthy.Count -gt 0) { $enabled = $healthy }
    }
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

function Select-AffordableRankedModels {
    <#
      Keeps the candidates whose own record says they can still deliver
      (Test-ModelAffordable), and the WHOLE list when none can: the caller must
      always be left with something to try.

      Cooldowns alone were not enough. A `server` failure buys a 60-second
      cooldown, so a model the provider is currently failing walks straight back
      to the front of the order - which is how `-ping` spent 90 s on
      `gemini-flash-latest` while Google was answering 503 for it and
      `gemini-flash-lite-latest` answered in 3.2 s. Health looks at the last 12
      calls instead of the last minute.
    #>
    param([string[]]$Models)
    $list = @(@($Models) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ })
    if ($list.Count -le 1) { return $list }
    $budget = Get-LatencyBudgetMs
    $affordable = @($list | Where-Object { Test-ModelAffordable -ModelId $_ -BudgetMs $budget })
    if ($affordable.Count -gt 0) { return $affordable }
    return $list
}

function Get-BackendFallbackModel {
    <#
      The backend's pick when there are no rankings to consult.

      N6: `<RT>\model-rankings.json` has never shipped, so on a normal install
      this is not a rare fallback - it is the ONLY branch. It used to return a
      literal model id, which meant Delegator probed a model the user may never
      have enabled: `-ping` called `opencode/deepseek-v4-flash-free` on a machine
      whose list holds `orcarouter/deepseek/deepseek-v4-flash-free` and not that
      one, so the answer was "никто не ответил" while the enabled models were
      fine.

      The literal stays as a PREFERENCE - only when the user actually enabled
      it. Otherwise the enabled list, and the ORDER matters: this function is the
      backend CORRECTION, the one N4 describes as overwriting a strong pick with
      a flash one, so it must keep reaching for something cheap and quick. Taking
      the strongest enabled model instead would make `-ping` probe a 156-point
      reasoner to hear the word PONG.

      Hence: flash-class models first, strongest within each group (I10 - a model
      with no rating counts as 100, never 0), and cooling-down models pushed
      aside by Select-ActiveRankedModels. That is a tie-break, not the
      strength-first ORDERING N3 measured as harmful.
    #>
    param([string]$BackendName, [string[]]$Enabled)
    $preferred = ""
    if ($BackendName -eq "opencode") { $preferred = "opencode/deepseek-v4-flash-free" }

    $list = @(@($Enabled) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { [string]$_ })
    if ($list.Count -eq 0) { return $preferred }

    # The names providers give their small models. Matching on the id is what
    # the runtime already does for the same question (G31).
    $quick = "(?i)(flash|lite|mini|fast|lightning|turbo|haiku|small)"
    $rest = @($list | Where-Object { $_ -ne $preferred } | Sort-Object -Descending -Property @{
        Expression = {
            $dpr = Get-DelegatorModelRating $_
            $score = if ($null -eq $dpr) { 100 } else { [int]$dpr }
            # Every quick model outranks every heavy one; strength orders within.
            if ($_ -match $quick) { $score + 1000 } else { $score }
        }
    })
    $ordered = @()
    if ($list -contains $preferred) { $ordered += $preferred }
    $ordered += $rest
    $active = @(Select-AffordableRankedModels @(Select-ActiveRankedModels $ordered))
    if ($active.Count -gt 0) { return [string]$active[0] }
    return $preferred
}

function Get-PreferredBackendModel {
    param([string]$BackendName, [string]$Text)
    if ($BackendName -eq "gemini") {
        $enabledGemini = @(Get-DelegatorEnabledModels "enabled_gemini_models")
        $order = if ($Text.Length -gt 4000 -or $Text -match "architecture|security|debug|root cause|migration|refactor") {
            # Heavy work: strongest by version number, not "pro first".
            @(Get-EnabledGeminiModelsByStrength)
        } else {
            @("gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest")
        }
        $selectedGemini = @(Select-ActiveRankedModels @($order | Where-Object { $enabledGemini -contains $_ }))
        $selectedGemini = @(Select-AffordableRankedModels $selectedGemini)
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
        return (Get-BackendFallbackModel -BackendName $BackendName -Enabled $enabledForBackend)
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
    $domainCandidates = @(Select-AffordableRankedModels @(Select-ActiveRankedModels $domainCandidates))
    if ($domainCandidates.Count -gt 0) { return [string]$domainCandidates[0] }
    $overallCandidates = @()
    foreach ($row in @($rankings.overall)) {
        $m = [string]$row.model
        if ((Test-ModelMatchesBackend $m $BackendName) -and
            ($enabledForBackend.Count -eq 0 -or $enabledForBackend -contains $m)) { $overallCandidates += $m }
    }
    $overallCandidates = @(Select-AffordableRankedModels @(Select-ActiveRankedModels $overallCandidates))
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
        [string]$EffectiveComplexity = "",

        # Which STAGE of the request this provider call serves (DEV_CONTRACTS
        # section 2.1: answer|triage|advisor|synthesis|verify|micro|plan|parallel).
        # Both provider scripts have always READ $env:DELEGATOR_USAGE_STAGE and
        # nothing ever WROTE it, so every call in usage.jsonl claimed to be the
        # final answer: 450 rows that cannot tell a 1.8 s triage from a 224 s
        # rewrite. No router can be tuned on a log that cannot see modes.
        [string]$Stage = ""
    )

    # The hook tells the agent to allow 10 minutes. Rungs that each take their full timeout added up
    # to 2 hours once (solve-fallback, measured): past the deadline the ladder stops asking.
    $callTimeout = $TimeoutSec
    if ($null -ne $script:AssistDeadline) {
        $left = [int]($script:AssistDeadline - (Get-Date)).TotalSeconds
        if ($left -lt 15) {
            [Console]::Error.WriteLine("[Delegator] the time budget for this request is over, skipping '$ChosenModel'")
            return [pscustomobject]@{ exitCode = 124; output = "Delegator: the time budget for this request is over." }
        }
        $callTimeout = [math]::Min([int]$TimeoutSec, $left)
    }
    $cx = if (-not [string]::IsNullOrWhiteSpace($EffectiveComplexity)) { $EffectiveComplexity } else { $Complexity }
    $effectiveModel = if (-not [string]::IsNullOrWhiteSpace($ChosenModel)) { $ChosenModel } else { $Model }
    # Set for the provider child and restored afterwards: a nested call (an
    # advisor inside boost) must not leak its stage onto the caller's next call.
    $previousStage = $env:DELEGATOR_USAGE_STAGE
    $env:DELEGATOR_USAGE_STAGE = if ([string]::IsNullOrWhiteSpace($Stage)) { $previousStage } else { $Stage }
    try {
        $delegateParams = @{ Command = "ask"; Prompt = $Text; Complexity = $cx; TimeoutSec = $callTimeout }
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
    } finally {
        $env:DELEGATOR_USAGE_STAGE = $previousStage
    }
}

function Get-GeminiAliasVersion {
    # What `gemini-<family>-latest` resolves to now, from the GUI's config.json
    # (`gemini_alias_versions`: flash / pro / flash-lite -> 3.8 / 3.1 / 3.5).
    # 0 when it was never read.
    param([string]$Family)
    if ([string]::IsNullOrWhiteSpace($Family)) { return 0.0 }
    if ($null -eq $script:GeminiAliasVersions) {
        $script:GeminiAliasVersions = @{}
        try {
            if (Test-Path -LiteralPath $script:DelegatorAppConfigFile) {
                $config = Get-Content -LiteralPath $script:DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                $prop = $config.PSObject.Properties["gemini_alias_versions"]
                if ($prop -and $prop.Value) {
                    foreach ($entry in $prop.Value.PSObject.Properties) {
                        $script:GeminiAliasVersions[[string]$entry.Name] = [double]$entry.Value
                    }
                }
            }
        } catch {}
    }
    if ($script:GeminiAliasVersions.ContainsKey($Family)) { return [double]$script:GeminiAliasVersions[$Family] }
    return 0.0
}

function Get-GeminiModelScore {
    <#
      Ranks a Google model id. Higher is stronger. The order is the owner's rule,
      for the API keys and the web door alike:

        1. Argon, when it is enabled.
        2. Flash, but only while its number is ABOVE Pro's.
        3. Pro.
        4. Flash, when its number is not above Pro's (between Pro and Flash-Lite).
        5. Flash-Lite.

      Inside a tier the higher version number wins. An explicitly VERSIONED id
      outranks a `-latest` alias of the same number, because an alias is a moving
      target. A family whose number is unknown (no catalog read yet) takes the
      tier alone, and Flash then counts as above Pro (the old default).
    #>
    param([string]$ModelId)

    $id = ([string]$ModelId).ToLowerInvariant()
    $family = if ($id -match "flash-?lite" -or $id -match "\blite\b") { "flash-lite" }
              elseif ($id -match "argon") { "argon" }
              elseif ($id -match "\bpro\b") { "pro" }
              else { "flash" }
    $generation = 0.0
    if ($id -match "gemini-(\d+(?:\.\d+)?)") { $generation = [double]$Matches[1] }
    # A `-latest` alias has no number of its own: the GUI's catalog read supplies it.
    $number = $generation
    if ($number -le 0 -and $family -ne "argon") { $number = Get-GeminiAliasVersion $family }
    $proNumber = Get-GeminiAliasVersion "pro"
    if ($generation -gt 0 -and $family -eq "pro") { $proNumber = $generation }

    $tier = switch ($family) {
        "argon"      { 5 }
        "flash-lite" { 1 }
        "pro"        { 3 }
        default      {
            if ($proNumber -le 0 -or $number -gt $proNumber) { 4 } else { 2 }
        }
    }
    $base = $tier * 1000
    if ($number -le 0) { return $base }
    # The -latest alias is one point below the versioned id of the same number.
    $penalty = if ($generation -gt 0) { 0 } else { 1 }
    return $base + [int]([math]::Round($number * 10)) - $penalty
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

function Test-HeavyTaskText {
    # The same domains the strength floor pins to the strongest model. A free route
    # is never allowed to answer or review these (owner's rule, 2026-10-26).
    param([string]$Text)
    return ((Get-TaskDomain $Text) -match "architecture|security|code_debug|context_analysis|math_algo|data_consistency")
}

function Test-FreeModelId {
    # `openrouter/openrouter/free`, `orcarouter/free`, `tencent/hy3-free`, `x:free`, ...
    param([string]$ModelId)
    return ([string]$ModelId -match "(?i)(^|[-/:])free$")
}

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
    $custom = @($enabled | Where-Object {
        $parts = ([string]$_).Split("/", 2)
        $parts.Count -eq 2 -and -not [string]::IsNullOrWhiteSpace($parts[1]) -and $builtIn -notcontains $parts[0]
    })
    # ORDER BY MEASURED HEALTH, not by the alphabet. `Sort-Object` put
    # `agentrouter/claude-...` first for no reason but its name, so a model that
    # had just failed twice was still asked first and the healthy sibling was
    # reached only after two timeouts.
    #
    # The scores are computed FIRST and sorted by property name afterwards: a
    # Sort-Object script block runs in a child scope where a helper can fail to
    # resolve, and this is the hot path of `improve` under
    # $ErrorActionPreference = "Stop" — a throw here would take the whole call
    # down. Anything unknown scores as healthy, so a fresh install still tries
    # the user's own provider first.
    $scored = @()
    foreach ($id in $custom) {
        $name = [string]$id
        $health = $null
        try { $health = Get-ModelHealth $name } catch { $health = $null }
        $cooling = $false
        try { $cooling = [bool](Test-ModelCoolingDown $name) } catch { $cooling = $false }
        $scored += [pscustomobject]@{
            id = $name
            cooling = if ($cooling) { 1 } else { 0 }
            failRate = if ($null -ne $health) { [double]$health.failRate } else { 0.0 }
            p75 = if ($null -ne $health -and $null -ne $health.p75Ms) { [int]$health.p75Ms } else { 0 }
        }
    }
    return @($scored | Sort-Object -Property cooling, failRate, p75, id | ForEach-Object { $_.id })
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
        [string]$EffectiveComplexity = "",
        [string]$Stage = ""
    )

    $result = Invoke-Delegate -ChosenBackend $ChosenBackend -Text $Text -ChosenModel $ChosenModel -EffectiveComplexity $EffectiveComplexity -Stage $Stage
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
    # Only when the failed model was itself a custom one: a Gemini failure must not
    # send the call through the AgentRouter/OpenCode routes first (run l8xb).
    $custom = @(if ($ChosenBackend -eq "opencode") { Get-CustomProviderModels | Where-Object { $_ -ne $ChosenModel } })
    foreach ($sibling in @($custom | Select-Object -First 2)) {
        [Console]::Error.WriteLine("[Delegator] $ChosenModel failed, trying $sibling")
        Write-DelegateMetric -Stage "failover" -Model $sibling -Backend "opencode" -Status "same-provider" -Extra "was=$ChosenModel"
        $retry = Invoke-Delegate -ChosenBackend "opencode" -Text $Text -ChosenModel $sibling -EffectiveComplexity $EffectiveComplexity -Stage $Stage
        if ($retry.exitCode -eq 0) {
            return [pscustomobject]@{
                exitCode = 0; output = $retry.output; backend = "opencode"
                model = $sibling; fellBack = $true
            }
        }
    }

    $otherBackend = if ($ChosenBackend -eq "opencode") { "gemini" } else { "opencode" }
    # A failed Gemini model is followed by the OTHER Gemini models first (flash-lite
    # answered where flash was overloaded), and only then by the opencode routes.
    $geminiNext = if ($ChosenBackend -eq "gemini") { @(Get-EnabledGeminiModelsByStrength -Exclude @($ChosenModel) | Select-Object -First 2) } else { @() }
    # Up to two models on the other side. Google meters each model separately,
    # so "pro is out of quota" must not read as "Google is out of quota".
    $candidates = if ($otherBackend -eq "gemini") {
        @(Get-EnabledGeminiModelsByStrength | Select-Object -First 2)
    } else {
        $first = Get-StrongEnabledModel
        $second = if ([string]::IsNullOrWhiteSpace($first)) { "" } else { Get-StrongEnabledModel -Exclude @($first) }
        @(@($first, $second) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($candidates.Count -eq 0 -and $geminiNext.Count -eq 0) {
        return [pscustomobject]@{
            exitCode = $result.exitCode; output = $result.output; backend = $ChosenBackend
            model = $ChosenModel; fellBack = $false
        }
    }

    # Last rung: the universal free route, whichever side we ended up on. When
    # both providers are rate-limited this is the only thing left that answers.
    $universal = Get-UniversalFreeModel
    if ((Test-HeavyTaskText $Text)) { $universal = "" }
    if (-not [string]::IsNullOrWhiteSpace($universal) -and $candidates -notcontains $universal) {
        $candidates = @($candidates) + $universal
    }

    $lastRetry = $null
    # `openrouter/*` is served by the opencode side regardless of which backend we
    # failed over FROM; the Gemini-next models always stay on Gemini.
    $plan = @($geminiNext | ForEach-Object { [pscustomobject]@{ model = $_; backend = "gemini" } }) +
        @($candidates | ForEach-Object { [pscustomobject]@{ model = $_; backend = $(if ($_ -like "openrouter/*") { "opencode" } else { $otherBackend }) } })
    foreach ($step in $plan) {
        $otherModel = [string]$step.model
        $useBackend = [string]$step.backend
        [Console]::Error.WriteLine("[Delegator] $ChosenBackend failed, retrying on $useBackend ($otherModel)")
        Write-DelegateMetric -Stage "failover" -Model $otherModel -Backend $useBackend -Status "from-$ChosenBackend" -Extra "was=$ChosenModel"
        $lastRetry = Invoke-Delegate -ChosenBackend $useBackend -Text $Text -ChosenModel $otherModel -EffectiveComplexity $EffectiveComplexity -Stage $Stage
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
    $res = Invoke-Delegate -ChosenBackend $triageBackend -Text $triagePrompt -ChosenModel $triageModel -EffectiveComplexity "fast" -Stage "triage"
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
    $res = Invoke-Delegate -ChosenBackend $extractBackend -Text $extractPrompt -ChosenModel $extractModel -EffectiveComplexity "fast" -Stage "triage"
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

function Get-PingAdvice {
    <#
      What to tell the user to DO, chosen from the failure classes that were
      actually observed. The old text named all three usual causes every time -
      "квота, ключ или сеть" - which on a provider outage sends someone to check
      an API key that is perfectly fine, and, worse, reads as "your setup is
      broken" when nothing of theirs is.

      No classes at all (nothing was recorded) keeps the old generic wording:
      guessing out loud is honest when there is genuinely nothing to go on.
    #>
    param([string[]]$Classes)
    $set = @(@($Classes) |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() })
    $out = New-Object System.Collections.Generic.List[string]
    if ($set.Count -eq 0) {
        $out.Add("Обычно это дневная квота провайдера, отсутствующий ключ или нет сети.")
        $out.Add("Загляните в окне Delegator во вкладку «API»: разделы «Ключи» и «Модели».")
        return $out.ToArray()
    }
    if ($set -contains "auth") {
        $out.Add("Ключ не принят - откройте вкладку «API», раздел «Ключи».")
    }
    if ($set -contains "rate_limit") {
        $out.Add("Похоже на дневную квоту: она обнулится сама, а пока помогут другие модели во вкладке «API», раздел «Модели».")
    }
    if ($set -contains "network") {
        # G98: a proxy that has stopped tunnelling looks EXACTLY like this, and
        # the user has no other hint that egress is the problem.
        $out.Add("До провайдера не достучаться. Если настроен прокси, проверьте его во вкладке «Прокси»: сломанный прокси выглядит точно так же, как умершие модели.")
    }
    if ($out.Count -eq 0) {
        # Only server / timeout / unknown: the models were reached, they just
        # did not deliver. Nothing of the user's is broken.
        $out.Add("Похоже на временные неполадки у провайдера, а не на вашу настройку.")
        $out.Add("Если это надолго, эти модели можно снять во вкладке «API», раздел «Модели» - перебор сразу пойдёт по остальным.")
    }
    return $out.ToArray()
}

function Get-PingFailureReason {
    <#
      Why one probe model did not answer, in the words of the person who typed
      `-ping`. Returns "" when nothing was recorded for it.

      The provider scripts already CLASSIFY every rung: `attempt_failed` in
      runs.jsonl carries `errorClass`, `statusCode` and `errorPreview` (I21,
      G82). `-ping` used to throw all of that away and print three guesses -
      "квота, ключ или сеть". On the run that prompted this fix all three were
      wrong: Google was answering 503 "experiencing high demand" for one model
      while another Gemini model answered in 3.2 s.

      Read from the tail only. The file is append-only and a probe writes its
      records seconds ago, so a few hundred lines always covers it; parsing the
      whole log would make a status command O(history).
    #>
    param([string]$ModelName, [datetime]$Since)
    $none = [pscustomobject]@{ reason = ""; class = "" }
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $none }
    $record = $null
    try {
        if (-not (Test-Path -LiteralPath $script:DelegateRunsFile)) { return $none }
        foreach ($line in @(Get-Content -LiteralPath $script:DelegateRunsFile -Tail 400 -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $row = $null
            try { $row = $line | ConvertFrom-Json } catch { continue }
            if (-not $row) { continue }
            if ([string]$row.event -ne "attempt_failed") { continue }
            if ([string]$row.model -ne $ModelName) { continue }
            try { if ([datetime]$row.timestamp -lt $Since) { continue } } catch { continue }
            $record = $row
        }
    } catch {
        return $none
    }
    if (-not $record) { return $none }

    $status = 0
    try { $status = [int]$record.statusCode } catch {}
    $class = ""
    try { $class = [string]$record.errorClass } catch {}
    $reason = switch ($class) {
        "rate_limit"       { "лимит запросов или дневная квота" }
        "auth"             { "ключ не принят" }
        "network"          { "до провайдера не достучаться" }
        "context_overflow" { "запрос слишком длинный" }
        "timeout"          { "не ответила вовремя" }
        "server"           { "провайдер вернул ошибку" }
        default            { "не ответила" }
    }
    if ($status -gt 0) { $reason += " ($status)" }
    $preview = ""
    try { $preview = ([string]$record.errorPreview).Trim() } catch {}
    # The provider's own sentence is the useful half - "This model is currently
    # experiencing high demand" explains more than any class name. A JSON blob
    # is not: those start with '{' and are the CLI's raw envelope.
    if (-not [string]::IsNullOrWhiteSpace($preview) -and -not $preview.StartsWith("{")) {
        $preview = ($preview -replace '\s+', ' ')
        if ($preview.Length -gt 110) { $preview = $preview.Substring(0, 110).TrimEnd() + "..." }
        $reason += ": $preview"
    }
    return [pscustomobject]@{ reason = $reason; class = $class }
}

function Format-PingReport {
    <#
      The user-visible answer to `-ping`, built from facts that are already
      known. Split out from Run-Ping so the wording can be tested without a
      network call - this text is the whole product of the command, and the one
      thing it must never do is claim to work when nothing answered.

      Russian on purpose: everything else the runtime prints goes to an agent,
      this goes to the person who typed `-ping`.
    #>
    param(
        [string]$RuntimeHome = "",
        # Empty when the core did not answer on 127.0.0.1:1380.
        [string]$CoreVersion = "",
        [int]$GeminiModels = 0,
        [int]$OtherModels = 0,
        # Empty when the agent did not pass -CallerModel.
        [string]$Caller = "",
        # Empty when the live probe brought nothing back.
        [string]$AnswerModel = "",
        # Everything the probe called, in order - the failure text is useless
        # without it ("никто не ответил" from WHOM?).
        [string[]]$TriedModels = @(),
        # Parallel to $TriedModels: why each one did not answer, already phrased
        # for the user (Get-PingFailureReason). Empty entries are allowed - a
        # provider that died before writing a record leaves nothing to report.
        [string[]]$TriedReasons = @(),
        # The raw errorClass values behind those reasons. The ADVICE is chosen
        # from these, never guessed: sending someone to the «API» keys over
        # a provider's 503 is worse than saying nothing.
        [string[]]$FailureClasses = @(),
        [double]$Seconds = 0,
        [int]$ExitCode = 0
    )

    $lines = New-Object System.Collections.Generic.List[string]
    # Not measured, and deliberately not pretending to be: an agent can only
    # know the verb from the instruction file, so this output existing at all
    # IS the proof that the file reached the session (G45: at session start).
    $lines.Add("Delegator: инструкции дошли до этого чата.")
    $lines.Add("  Иначе агент не знал бы про -ping - эта команда описана только в них.")
    if (-not [string]::IsNullOrWhiteSpace($RuntimeHome)) {
        $lines.Add("  Runtime: $RuntimeHome")
    }
    if ([string]::IsNullOrWhiteSpace($CoreVersion)) {
        $lines.Add("  Ядро: не отвечает на 127.0.0.1:1380 - окно Delegator закрыто или ядро не поднялось")
    } else {
        $lines.Add("  Ядро: отвечает, версия $CoreVersion")
    }
    $total = $GeminiModels + $OtherModels
    $lines.Add("  Моделей включено: $total (Gemini $GeminiModels, через OpenCode $OtherModels)")
    if ([string]::IsNullOrWhiteSpace($Caller)) {
        $lines.Add("  Ваша модель: агент не передал -CallerModel - маршрутизация будет как до 0.8")
    } else {
        $lines.Add("  Ваша модель: $Caller")
    }

    $elapsed = [math]::Round($Seconds, 1)
    if (-not [string]::IsNullOrWhiteSpace($AnswerModel)) {
        $lines.Add("  Проверка связи: ответила $AnswerModel за $elapsed с")
        $lines.Add("Итог: Delegator подключён и работает.")
    } else {
        $lines.Add("  Проверка связи: ответа нет за $elapsed с (код $ExitCode)")
        $tried = @($TriedModels)
        $reasons = @($TriedReasons)
        $known = @($reasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($tried.Count -gt 0 -and $known.Count -eq 0) {
            # Nothing was recorded for any of them: one line, as before.
            $lines.Add("  Пробовали: " + ($tried -join ", "))
        } elseif ($tried.Count -gt 0) {
            $lines.Add("  Пробовали:")
            for ($i = 0; $i -lt $tried.Count; $i++) {
                $why = if ($i -lt $reasons.Count) { [string]$reasons[$i] } else { "" }
                if ([string]::IsNullOrWhiteSpace($why)) {
                    $lines.Add("    " + $tried[$i])
                } else {
                    $lines.Add("    " + $tried[$i] + " - " + $why)
                }
            }
        }
        $lines.Add("Итог: инструкции на месте, но ответить сейчас никто не смог.")
        foreach ($advice in (Get-PingAdvice $FailureClasses)) { $lines.Add("  " + $advice) }
        $lines.Add("  Настоящая задача при этом может пройти: у неё длиннее перебор моделей, чем у -ping.")
    }
    return $lines.ToArray()
}

function Get-PingBackendModels {
    # The first two models a backend would use for the probe, in its own preference order.
    param([string]$BackendName, [string]$Text)
    $picked = @()
    $first = Get-PreferredBackendModel $BackendName $Text
    if (-not [string]::IsNullOrWhiteSpace($first)) { $picked += $first }
    if ($BackendName -eq "gemini") {
        foreach ($name in @("gemini-flash-latest", "gemini-flash-lite-latest", "gemini-pro-latest")) {
            if ($picked.Count -ge 2) { break }
            if ($name -ne $first -and @(Get-DelegatorEnabledModels "enabled_gemini_models") -contains $name) { $picked += $name }
        }
    } else {
        foreach ($name in @(Get-DelegatorEnabledModels "enabled_opencode_models")) {
            if ($picked.Count -ge 2) { break }
            if ($name -ne $first -and $name -notlike "openrouter/*") { $picked += $name }
        }
    }
    return ,$picked
}

function Run-Ping {
    <#
      One command a user can type in their IDE chat to see whether Delegator is
      there FOR THAT CHAT and whether it can still answer. The second half is
      measured with a real delegation down the normal routing path - a
      reachability check that never calls a model would go on saying "работает"
      through an entire quota outage.

      ALWAYS exits 0. Any other code means "Delegator could not help" under the
      hook contract, and the agent would then hide the report that explains why.
    #>
    # A ping is a self-test, never work the caller receives: `ping` is not in
    # SAVED_STAGES, so its tokens are booked as spent (DEV_CONTRACTS section 3).
    $probe = "Ответь одним словом: PONG"
    # Long enough for a cold OpenCode CLI (listing models alone takes ~13 s), and a PER-CALL budget.
    $script:TimeoutSec = 60
    # The whole walk: no new call starts after this many seconds.
    $PingBudgetSec = 150

    $coreVersion = ""
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:1380/health" -TimeoutSec 5
        if ($health -and $health.ok) { $coreVersion = [string]$health.version }
    } catch {
        # Down is one of the two answers this command exists to give.
    }

    $caller = $CallerModel
    if ([string]::IsNullOrWhiteSpace($caller)) { $caller = $env:DELEGATOR_CALLER_MODEL }

    # AT MOST FOUR CALLS within PingBudgetSec, two per backend. Deliberately NOT
    # Invoke-DelegateAcrossBackends: its ladder walks up to six models with no
    # overall cap - measured at over four minutes for a "status check". A real task
    # is allowed to be that patient; a status line is not.
    $primary = Select-Backend $probe
    $secondary = "opencode"
    if ($primary -eq "opencode") { $secondary = "gemini" }
    # Two models per backend, interleaved, so a 503 on one model does not read as "nobody answers":
    # the first answer wins, and the whole walk stops at PingBudgetSec (see the loop below).
    $plan = @()
    $perBackend = @{}
    foreach ($backend in @($primary, $secondary)) {
        $perBackend[$backend] = @(Get-PingBackendModels $backend $probe)
        if ($perBackend[$backend].Count -eq 0 -and $backend -eq $primary -and -not [string]::IsNullOrWhiteSpace($Model)) {
            $perBackend[$backend] = @($Model)
        }
    }
    for ($rung = 0; $rung -lt 2; $rung++) {
        foreach ($backend in @($primary, $secondary)) {
            if ($perBackend[$backend].Count -gt $rung) { $plan += ,@($backend, [string]$perBackend[$backend][$rung]) }
        }
    }

    $probeStarted = Get-Date
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $answered = ""
    $tried = @()
    $code = 1
    # A model in cooldown is not called (its provider already failed it, and a status line should not
    # spend the budget on it). The report says so, with the time the cooldown ends, instead of "no answer".
    $cooldownData = Get-DelegateCooldowns
    $skippedReason = @{}
    foreach ($step in $plan) {
        if ($watch.Elapsed.TotalSeconds -ge $PingBudgetSec) { break }
        $tried += [string]$step[1]
        if (Test-ModelCoolingDown -ModelName ([string]$step[1]) -Cooldowns $cooldownData) {
            $row = $cooldownData.models.PSObject.Properties[[string]$step[1]].Value
            $until = [datetime]::Parse([string]$row.until, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal).ToLocalTime()
            $skippedReason[[string]$step[1]] = "в cooldown до {0} ({1}), не вызывался" -f $until.ToString("HH:mm"), [string]$row.reason
            continue
        }
        $result = $null
        try {
            $result = Invoke-Delegate -ChosenBackend $step[0] -Text $probe -ChosenModel $step[1] -EffectiveComplexity "fast" -Stage "ping"
        } catch {
            # Under $ErrorActionPreference = "Stop" (G19) a provider script that
            # dies takes this one with it, and the user would get a PowerShell
            # stack where the report should be. A throw is just another way of
            # saying "this one did not answer".
        }
        if ($result) {
            $code = [int]$result.exitCode
            $text = ""
            if ($result.output) { $text = ([string]$result.output).Trim() }
            if ($code -eq 0 -and -not [string]::IsNullOrWhiteSpace($text)) {
                $answered = [string]$step[1]
                break
            }
        }
    }
    $watch.Stop()

    # The provider already wrote WHY each rung failed; read it back rather than
    # guessing in the report (see Get-PingFailureReason).
    $reasons = @()
    $classes = @()
    if ([string]::IsNullOrWhiteSpace($answered)) {
        foreach ($model in $tried) {
            if ($skippedReason.ContainsKey([string]$model)) {
                $reasons += [string]$skippedReason[[string]$model]
                continue
            }
            $failure = Get-PingFailureReason -ModelName $model -Since $probeStarted
            $reasons += [string]$failure.reason
            if (-not [string]::IsNullOrWhiteSpace([string]$failure.class)) {
                $classes += [string]$failure.class
            }
        }
    }

    $report = Format-PingReport `
        -RuntimeHome $BinHome `
        -CoreVersion $coreVersion `
        -GeminiModels @(Get-DelegatorEnabledModels "enabled_gemini_models").Count `
        -OtherModels @(Get-DelegatorEnabledModels "enabled_opencode_models").Count `
        -Caller $caller `
        -AnswerModel $answered `
        -TriedModels $tried `
        -TriedReasons $reasons `
        -FailureClasses $classes `
        -Seconds $watch.Elapsed.TotalSeconds `
        -ExitCode $code
    foreach ($line in $report) { Write-Output $line }
    $webLine = Format-WebDoorsLine (Get-WebDoorsState)
    if (-not [string]::IsNullOrWhiteSpace($webLine)) { Write-Output $webLine }
    # The probe above asks API models only. "Nobody could answer" is not the whole truth when a web door
    # is up, and that is where real tasks go first.
    if ([string]::IsNullOrWhiteSpace($answered) -and (Test-WebDoorsUp)) {
        Write-Output "Модели по API сейчас не отвечают, но задачи пойдут через Web."
    }
    Exit-Delegate 0
}

function Format-WebDoorsLine {
    # One line for -ping: which web doors are on and what is in their way. Empty when none is on.
    param($State)
    if ($null -eq $State) { return "" }
    $parts = @()
    foreach ($door in @($State.doors | Where-Object { $_.enabled })) {
        $note = if (-not $State.connected) { "нет расширения" }
                elseif ($door.auth -eq "signed_out") { "нужен вход" }
                elseif ([int]$door.resting_sec -gt 0) { "пауза $([math]::Ceiling([int]$door.resting_sec / 60)) мин" }
                elseif ($door.auth -eq "signed_in") { "готов" }
                else { "вход не проверен" }
        $parts += "$($door.label): $note"
    }
    if ($parts.Count -eq 0) { return "" }
    return "Web: " + ($parts -join ", ")
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

function Get-BoostAdvisorModels {
    <#
      The advisors a `boost` convenes: the strongest models the user actually
      ENABLED, ordered exactly the way Get-StrongEnabledModel orders its single
      pick, filtered by the same measured health.

      Why it is not a constant list. `model-rankings.json` never ships (N6), so
      the ranking branch above never fires and a hardcoded triple was the real
      advisor pool. Two of its three ids were not enabled here, the nested
      `ask -Model X` refuses anything outside the GUI allowlist (I8 defending
      itself), and boost failed 3 times out of 3 on this machine.

      What this honestly buys: the STRONGEST advisor now equals the ordinary
      single-model pick, and no advisor is weaker than something the user chose.
      It cannot promise "no worse than answering once" - a top-N by strength
      includes weaker members by definition, and the synthesis step is what is
      supposed to make the set worth more than its best member.

      Returns an EMPTY array when nothing is enabled. The caller falls back to a
      single answer; inventing ids would only reproduce the bug.
    #>
    # -Enabled exists for tests: the allowlist is read from %APPDATA%\...\config.json,
    # which DELEGATOR_RUNTIME_HOME does not redirect, so a suite cannot otherwise
    # control the one input that matters.
    param([int]$Count = 3, [string[]]$Exclude = @(), [string[]]$Enabled)
    if ($Count -lt 1) { return @() }
    $enabled = if ($PSBoundParameters.ContainsKey("Enabled")) { @($Enabled) }
    else { @(Get-DelegatorEnabledModels "enabled_opencode_models") }
    $enabled = @($enabled | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Exclude.Count -gt 0) { $enabled = @($enabled | Where-Object { $Exclude -notcontains $_ }) }
    if ($enabled.Count -eq 0) { return @() }

    $strengths = Get-ZenCatalogStrengthMap
    $ordered = @($enabled | Sort-Object `
        @{ Expression = { Get-ModelStrengthScore -ModelId $_ -Catalog $strengths }; Descending = $true }, `
        @{ Expression = { [string]$_ }; Descending = $false })
    $ordered = @(Select-ActiveRankedModels $ordered)
    if ($ordered.Count -eq 0) { return @() }

    # Health filters, it does not decide: an advisor that is merely slow is still
    # a second opinion, and dropping every unhealthy id could empty the panel.
    $budget = Get-LatencyBudgetMs
    $healthy = @($ordered | Where-Object { Test-ModelAffordable -ModelId $_ -BudgetMs $budget })
    if ($healthy.Count -ge $Count) { return @($healthy | Select-Object -First $Count) }
    $rest = @($ordered | Where-Object { $healthy -notcontains $_ })
    return @(@($healthy) + @($rest) | Select-Object -First $Count)
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
        # `model-rankings.json` does not ship and is absent on every install (N6),
        # so this branch is the ONLY one that ever runs, and it used to hand back
        # a hardcoded triple. Measured on the owner's machine: two of those three
        # ids are not in `enabled_opencode_models`, the nested `ask -Model X`
        # refuses them ("not enabled in the Delegator GUI"), and every boost this
        # machine has ever run ended `all-advisors-failed` - all three records in
        # delegate-metrics.jsonl, including one from a §13 `amplify` route. The
        # one tier that is supposed to ADD something was firing into a pipeline
        # that could not succeed.
        $topModels = @(Get-BoostAdvisorModels -Count $Count)
    }
    if ($topModels.Count -eq 0) {
        Write-DelegateMetric -Stage "boost" -Status "no-advisors" -LatencyMs $boostSw.ElapsedMilliseconds
        [Console]::Error.WriteLine("[Delegator] boost: нет включённых моделей для консилиума, отвечаем одной")
        return $false
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
    $synthResult = Invoke-Delegate -ChosenBackend $synthBackend -Text $synthPrompt -ChosenModel $actualSynthModel -EffectiveComplexity "deep" -Stage "synthesis"
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

    $refineResult = Invoke-Delegate -ChosenBackend $Backend -Text $refinePrompt -ChosenModel $Model -EffectiveComplexity $Complexity -Stage "verify"
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
$script:AssistBudgetSec = 540   # the hook tells the agent to allow 10 minutes per call
$script:ImproveBudgetSec = 240  # the caller already has an answer; a review is worth only so much wait
$script:ImproveDraftBudget = 24000
$script:ImproveContextBudget = 12000
# The re-ask carries the reviewer's OWN unreadable reply back to it. A review is
# a verdict plus at most five short defects, so anything past this is prose the
# reformat does not need - and the whole point of the second call is that it is
# cheap.
$script:ImproveReaskBudget = 6000
# Section 12: false means run §11 only and never ask a model for an opinion.
# Run-Assist sets it from the router; a direct `improve` call keeps the review.
$script:ImproveModelReview = $true

$script:ContextBinarySkipped = 0
$script:BinaryExtensions = @(
    ".exe", ".dll", ".sys", ".msi", ".so", ".dylib", ".bin", ".obj", ".o", ".lib", ".pdb", ".class", ".jar",
    ".zip", ".7z", ".rar", ".gz", ".tar", ".xz", ".bz2", ".cab", ".iso",
    ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".ico", ".webp", ".tif", ".tiff", ".psd",
    ".mp3", ".wav", ".flac", ".ogg", ".mp4", ".mkv", ".avi", ".mov", ".webm",
    ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".ttf", ".otf", ".woff", ".woff2",
    ".db", ".sqlite", ".pyc", ".apk", ".aab", ".dex", ".wasm"
)

function Test-TextFile {
    # True when the file can travel inside a prompt as text. A binary (an .exe, an
    # archive, a picture) read as UTF-8 is mojibake that wastes the budget and
    # makes the model answer about noise, so it must never be inlined.
    param([string]$Path)
    if ($script:BinaryExtensions -contains [System.IO.Path]::GetExtension($Path).ToLowerInvariant()) { return $false }
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] 8192
            $read = $stream.Read($buffer, 0, $buffer.Length)
        } finally { $stream.Dispose() }
        for ($i = 0; $i -lt $read; $i++) { if ($buffer[$i] -eq 0) { return $false } }
    } catch { return $false }
    return $true
}

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
            if (-not (Test-TextFile $path)) {
                $script:ContextBinarySkipped++
                [Console]::Error.WriteLine("[Delegator] context file is not text, it can only go as a web attachment: $path")
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

function Get-JsonObjectCandidates {
    <#
      Every BALANCED {...} region of a text, in order, ignoring braces and quotes
      that live inside a JSON string.

      The predecessor took IndexOf("{") .. LastIndexOf("}") and handed the slice
      to ConvertFrom-Json. That is correct only when the object is the sole thing
      in the answer. It broke on all three shapes reviewers actually produce: a
      closing sentence containing braces, a schema example printed before the
      real verdict, and a defect whose text quotes a brace. Measured on this
      machine: 32 of 228 `improve` runs ended `verdict-unparsable`.
    #>
    param([string]$Raw)
    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Raw)) { return @() }
    $depth = 0
    $start = -1
    $inString = $false
    $escaped = $false
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $ch = $Raw[$i]
        if ($inString) {
            if ($escaped) { $escaped = $false; continue }
            if ($ch -eq '\') { $escaped = $true; continue }
            if ($ch -eq '"') { $inString = $false }
            continue
        }
        if ($ch -eq '"') { $inString = $true; continue }
        if ($ch -eq '{') {
            if ($depth -eq 0) { $start = $i }
            $depth++
            continue
        }
        if ($ch -eq '}' -and $depth -gt 0) {
            $depth--
            if ($depth -eq 0 -and $start -ge 0) {
                $found.Add($Raw.Substring($start, $i - $start + 1))
                $start = -1
            }
        }
    }
    return @($found)
}

function Get-ImproveVerdict {
    <#
      The reviewer's verdict object, or $null. Adds `parseMode`:
        json     - a real JSON object was parsed
        salvaged - the JSON was broken, but the reviewer named its verdict in a
                   way only one of the four words fits

      Candidate order matters. A reviewer that echoes the schema before answering
      produces TWO objects with a `verdict` key, and only the second one carries a
      real value, so an object whose verdict is one of the four always wins.

      A salvaged object carries NO defects on purpose: section 11a says a defect
      must come with a demonstration, and text we could not even parse is not a
      demonstration. `ok`/`minor` then keeps the draft (the cheap correct answer),
      and `major`/`wrong` with zero defects also keeps it.
    #>
    param([string]$Raw)
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }

    $candidates = @(Get-JsonObjectCandidates $Raw)
    # The scanner reads every `"` as a JSON delimiter, which prose is not: ONE
    # unpaired quote in the reviewer's preamble ("prints 5\" without escaping")
    # leaves it inside a string for the rest of the text and it returns nothing
    # for an answer that plainly contains a valid object. The old whole-slice
    # parse handled exactly that shape, so it stays as the second attempt rather
    # than being replaced - dropping straight to salvage LOSES the defects and
    # was a regression against the parser this function replaced.
    if ($candidates.Count -eq 0) {
        $start = $Raw.IndexOf("{")
        $end = $Raw.LastIndexOf("}")
        if ($start -ge 0 -and $end -gt $start) { $candidates = @($Raw.Substring($start, $end - $start + 1)) }
    }

    $valid = @("ok", "minor", "major", "wrong")
    $withValidVerdict = $null
    $withVerdictKey = $null
    $anyObject = $null
    foreach ($candidate in $candidates) {
        $obj = $null
        try { $obj = $candidate | ConvertFrom-Json } catch { continue }
        if ($null -eq $obj) { continue }
        if ($null -eq $anyObject) { $anyObject = $obj }
        $hasKey = $false
        try { $hasKey = @($obj.PSObject.Properties.Name) -contains "verdict" } catch {}
        if (-not $hasKey) { continue }
        if ($null -eq $withVerdictKey) { $withVerdictKey = $obj }
        if (([string]$obj.verdict).Trim().ToLowerInvariant() -in $valid) {
            $withValidVerdict = $obj
            break
        }
    }
    $chosen = if ($withValidVerdict) { $withValidVerdict }
    elseif ($withVerdictKey) { $withVerdictKey }
    else { $anyObject }
    if ($null -ne $chosen) {
        Add-Member -InputObject $chosen -NotePropertyName "parseMode" -NotePropertyValue "json" -Force
        return $chosen
    }

    # Nothing parsed. The verdict FIELD must still be present - a reviewer that
    # merely wrote "the draft is ok" in prose has not returned a verdict, and
    # reading one out of prose is how a keep silently becomes a rewrite.
    #
    # `(?![|/])` rejects the SCHEMA the check prompt itself printed. Without it
    # `"verdict":"ok|minor|major|wrong"` salvages as `ok`, which is usable enough
    # to suppress the one re-ask that exists for precisely this case: the review
    # is then reported as a clean `ok` the reviewer never gave.
    if ($Raw -match '(?i)"?\bverdict"?\s*[:=]\s*"?\s*(ok|minor|major|wrong)\b(?![|/])') {
        return [pscustomobject]@{
            verdict    = $Matches[1].ToLowerInvariant()
            defects    = @()
            confidence = $null
            parseMode  = "salvaged"
        }
    }
    return $null
}

function Test-ShouldReaskVerdict {
    <#
      Is one extra, bounded call worth it?

      Only when the reviewer SAID something we could not turn into a verdict.
      Empty output is a backend failure, not a formatting failure, and asking a
      silent model twice buys nothing but latency.
    #>
    param([string]$RawText, $Parsed)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $false }
    if ($null -eq $Parsed) { return $true }
    $value = ""
    try { $value = ([string]$Parsed.verdict).Trim().ToLowerInvariant() } catch {}
    return ($value -notin @("ok", "minor", "major", "wrong"))
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

function Get-RouterDecision {
    <#
      Asks the core which mode this request deserves. Pure function of the two
      texts; the core answers from `delegator_core/router.py` in a few
      milliseconds and cannot touch the network.

      A router that can fail is a router every caller has to guard, so every
      failure path returns the same shape with mode=delegate and tier=fallback:
      "answer it" is what Delegator did for every request before the router
      existed, and it is never destructive.
    #>
    param([string]$Task, [string]$Draft, [int]$ContextFiles = 0, [int]$CallerDpr = 0, [int]$BestDpr = 0,
        [string]$CallerConfidence = "", [string]$BestConfidence = "")

    $fallback = [pscustomobject]@{
        mode = "delegate"; reason = "router-unavailable"; confidence = 0.0
        complexity = "auto"; escalate = $false; tier = "fallback"; routerVersion = "0"
        callerTier = "unknown"; callerDpr = $CallerDpr; bestDpr = $BestDpr; modelReview = $true
    }
    # The running core answers in milliseconds; spawning the frozen exe costs 1.4 s (measured). The exe
    # stays for the agents that call us while the GUI, and so the core, is not up.
    try {
        $body = @{
            task = [string]$Task; draft = [string]$Draft; contextFiles = $ContextFiles
            callerDpr = $CallerDpr; bestDpr = $BestDpr
            callerConfidence = [string]$CallerConfidence; bestConfidence = [string]$BestConfidence
        } | ConvertTo-Json -Depth 4 -Compress
        $reply = Invoke-WebRequest -Uri "http://127.0.0.1:1380/api/route" -Method Post -TimeoutSec 2 -UseBasicParsing `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -ContentType "application/json; charset=utf-8"
        $decision = [System.Text.Encoding]::UTF8.GetString($reply.RawContentStream.ToArray()) | ConvertFrom-Json
        if ($decision -and -not [string]::IsNullOrWhiteSpace([string]$decision.mode)) { return $decision }
    } catch {}

    $core = Get-CoreExecutable
    if ([string]::IsNullOrWhiteSpace($core)) { return $fallback }

    $stamp = [guid]::NewGuid().ToString("N").Substring(0, 10)
    $tempDir = [System.IO.Path]::GetTempPath()
    $requestPath = Join-Path $tempDir "dg-route-req-$stamp.json"
    $decisionPath = Join-Path $tempDir "dg-route-out-$stamp.json"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        $payload = @{
            task = [string]$Task; draft = [string]$Draft; contextFiles = $ContextFiles
            callerDpr = $CallerDpr; bestDpr = $BestDpr
            callerConfidence = [string]$CallerConfidence; bestConfidence = [string]$BestConfidence
        }
        [System.IO.File]::WriteAllText($requestPath, ($payload | ConvertTo-Json -Depth 4 -Compress), $utf8)
        $process = Start-Process -FilePath $core -ArgumentList @("--route", $requestPath, $decisionPath) `
            -PassThru -WindowStyle Hidden
        # Without caching the handle first, ExitCode is $null after a timed wait.
        $null = $process.Handle
        if (-not $process.WaitForExit(8000)) {
            try { $process.Kill() } catch { }
            return $fallback
        }
        if (-not (Test-Path -LiteralPath $decisionPath)) { return $fallback }
        $decision = Get-Content -LiteralPath $decisionPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $decision -or [string]::IsNullOrWhiteSpace([string]$decision.mode)) { return $fallback }
        return $decision
    } catch {
        return $fallback
    } finally {
        foreach ($path in @($requestPath, $decisionPath)) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-RouterDecision {
    # The audit trail: every decision, with the features it was made from, so a
    # rule that looks clever and measures badly can be found later. Never fatal.
    param($Decision, [string]$Mode, [int]$ElapsedMs)
    try {
        $line = @{
            ts = (Get-Date).ToUniversalTime().ToString("o")
            requestId = $script:DelegateRequestId
            client = $env:DELEGATOR_CLIENT
            mode = $Mode
            reason = [string]$Decision.reason
            confidence = [double]$Decision.confidence
            tier = [string]$Decision.tier
            routerVersion = [string]$Decision.routerVersion
            routeMs = $ElapsedMs
            features = $Decision.features
            # Marked, not dropped: a learned router must be able to exclude
            # benchmark traffic later without re-deriving which lines it was.
            bench = (Test-DelegatorBenchmarkActive)
        } | ConvertTo-Json -Depth 5 -Compress
        $path = Join-Path $script:DelegateHome "router-decisions.jsonl"
        $stream = New-Object System.IO.StreamWriter($path, $true, (New-Object System.Text.UTF8Encoding $false))
        try { $stream.WriteLine($line) } finally { $stream.Dispose() }
    } catch { }
}

function Get-EscalatedMode {
    <#
      TIER 2. The rules said what they think and admitted they are unsure
      (`escalate`); one fast model gets to overrule them, and only then.

      Three properties make this safe to put on the critical path:
        * it runs ONLY when tier 1 asked for it, so a confident rule is never
          delayed by a network call;
        * it is capped hard (20 s) and anything it says that is not one of the
          four modes is discarded — the tier-1 answer is the fallback, so a dead
          provider costs latency and never correctness;
        * the weakest enabled model is used deliberately: this is a four-way
          classification of one paragraph, not the work itself.
      Set DELEGATOR_ROUTER_TIER2=off to skip it entirely.
    #>
    param([string]$Task, [bool]$HasDraft, [string]$Fallback)

    if ($env:DELEGATOR_ROUTER_TIER2 -eq "off") { return $Fallback }
    $head = if ($Task.Length -gt 1200) { $Task.Substring(0, 1200) } else { $Task }
    $draftLine = if ($HasDraft) { "У пользователя УЖЕ есть готовый ответ на эту задачу." }
                 else { "Готового ответа нет — задачу нужно решить." }
    $prompt = @"
Ты — маршрутизатор. Выбери ОДИН режим работы и ответь РОВНО ОДНИМ словом, без пояснений.

improve  — перепроверить и при необходимости исправить уже готовый ответ (только если ответ есть).
delegate — решить задачу самому, одной сильной моделью.
boost    — собрать несколько моделей и судью: только для действительно трудных, многосоставных вопросов.
keep     — ничего не делать: ответ уже есть и он тривиален, либо вмешательство не окупится.

$draftLine

ЗАДАЧА:
$head

Ответ (одно слово):
"@
    $previousTimeout = $script:TimeoutSec
    try {
        $script:TimeoutSec = 20
        $fastModel = Get-FastEnabledOpenCodeModel
        $backend = if ([string]::IsNullOrWhiteSpace($fastModel)) { "auto" } else { "opencode" }
        $result = Invoke-Delegate -ChosenBackend $backend -Text $prompt -ChosenModel $fastModel `
            -EffectiveComplexity "fast" -Stage "triage"
        if ($null -eq $result -or $result.exitCode -ne 0) { return $Fallback }
        $answer = (($result.output | Out-String) -replace "[^A-Za-z]", " ").ToLowerInvariant()
        # Word membership, not a regex: the answer is one word, and a word
        # boundary escaped through three layers is exactly the kind of detail
        # that silently turns a guard into a no-op (see the tier bug below).
        $words = @($answer -split "\s+" | Where-Object { $_ })
        foreach ($candidate in @("improve", "delegate", "boost", "keep")) {
            if ($words -contains $candidate) { return $candidate }
        }
        return $Fallback
    } catch {
        return $Fallback
    } finally {
        $script:TimeoutSec = $previousTimeout
    }
}

function Run-Assist {
    <#
      ONE DOOR. The IDE agent stops choosing a verb: it hands over the task, and
      the draft it already wrote if it has one, and Delegator decides what to do.

      Why this exists: the mode used to be picked by the IDE agent from prose in
      the hook text, which is the party least able to pick it — measured on this
      machine as 228 improve calls of which 109 had nothing to fix, agents that
      never called improve at all, and a benchmark whose Delegator arm could
      only ever be `improve`.

      Stdout contract is unchanged per mode, because agents parse it:
        * improve -> `##DELEGATOR_IMPROVE## {json}` + the corrected answer (exit 0),
          or exit 3 with nothing when the draft stands;
        * delegate/boost -> the answer itself (exit 0);
        * keep -> exit 3, nothing on stdout.
      The chosen mode and its reason go to stderr and to router-decisions.jsonl.
    #>
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        [Console]::Error.WriteLine("[Delegator] assist requires the task text: -PromptFile <file>")
        Exit-Delegate 2
    }
    $script:AssistDeadline = (Get-Date).AddSeconds($script:AssistBudgetSec)
    # The router already decided what this request is. The planner and triage behind it would each spend
    # a call on the weakest enabled model to decide it again, and the extract stage would summarise the
    # task with that same model before the strong one sees it.
    $script:NoPlanner = $true

    $draftText = ""
    if (-not [string]::IsNullOrWhiteSpace($DraftFile) -and (Test-Path -LiteralPath $DraftFile)) {
        try { $draftText = [System.IO.File]::ReadAllText($DraftFile, (New-Object System.Text.UTF8Encoding $false)) } catch { $draftText = "" }
    }
    $contextCount = if ($ContextFile) { @($ContextFile).Count } else { 0 }

    # Coding benchmark, Delegator arm: when the user's Web checkbox is on, EVERY
    # assist goes to the web chat, whatever the router would have said. The router
    # may answer `keep` to a strong caller, and a benchmark of "the model boosted by
    # Delegator" that never delegates measures nothing. Invoke-WebDelegation returns
    # $null when the checkbox is off or the extension is not connected - then the
    # ordinary ladder below runs, with its model fallbacks, unchanged.
    if (Test-DelegatorBenchmarkActive) {
        $webPrompt = $Prompt
        $script:ContextBinarySkipped = 0
        if ($contextCount -gt 0) {
            $webContext = Read-ContextFiles -Entries $ContextFile -Budget 60000
            if (-not [string]::IsNullOrWhiteSpace($webContext)) { $webPrompt += "`n`nFILES THE CALLER READ:`n$webContext" }
        }
        if (-not [string]::IsNullOrWhiteSpace($draftText)) {
            $webPrompt += "`n`nTHE CALLER'S CURRENT DRAFT (improve it where it is wrong, slow or weak; reply with the COMPLETE improved solution, not a diff):`n$draftText"
        }
        # A binary file goes to Gemini Web as an attachment (Invoke-WebDelegation). Only without Gemini Web
        # (the other doors take text only) would the task be answered without the file: then the ordinary
        # ladder runs instead of the web chat.
        $geminiWebOn = $false
        try { $geminiWebOn = [bool]((Get-Content -LiteralPath $script:DelegatorAppConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json).gemini_web_enabled) } catch {}
        if ($script:ContextBinarySkipped -gt 0 -and -not $geminiWebOn) {
            [Console]::Error.WriteLine("[Delegator] Web: a non-text file needs Gemini Web for attachment, the task is not sent to the web chat")
            $script:WebTried = $true
            $webAnswer = $null
        } else {
        # "medium": the highest level thinks for more than 8 minutes on a whole-solver prompt, and a
        # benchmark task has 15 minutes in total.
        # Set AFTER the call: Invoke-WebDelegation returns at once when WebTried is already set, so setting
        # it first made this door switch itself off (found 2026-10-27: no web call in any benchmark run).
        $webAnswer = Invoke-WebDelegation $webPrompt -WebReasoning "medium" -WebTimeout 570
        $script:WebTried = $true
        }
        if ($null -ne $webAnswer) {
            Write-DelegateMetric -Stage "route" -Status "web-benchmark" -LatencyMs 0 -Extra "reason=benchmark-web"
            [Console]::Error.WriteLine("[Delegator] режим: web (бенчмарк)")
            $webAnswer
            return
        }
    }

    # DEV_CONTRACTS section 13. Both numbers, or neither: one of them alone is not
    # a comparison, and the router reads 0 as "not declared", never as "weak".
    $callerDpr = Get-CallerDpr $CallerModel
    $bestDpr = 0
    $callerConfidence = ""
    $bestConfidence = ""
    if ($callerDpr -gt 0) {
        $bestDpr = Get-BestAvailableDpr
        $callerConfidence = Get-CallerRatingConfidence $CallerModel
        $bestConfidence = Get-DelegatorRatingConfidence (Get-StrongEnabledModel)
    }

    $routeSw = [System.Diagnostics.Stopwatch]::StartNew()
    $decision = Get-RouterDecision -Task $Prompt -Draft $draftText -ContextFiles $contextCount `
        -CallerDpr $callerDpr -BestDpr $bestDpr `
        -CallerConfidence $callerConfidence -BestConfidence $bestConfidence
    $routeSw.Stop()
    $mode = [string]$decision.mode
    if ($mode -notin @("improve", "delegate", "boost", "keep")) { $mode = "delegate" }
    $callerTier = [string]$decision.callerTier
    if ([string]::IsNullOrWhiteSpace($callerTier)) { $callerTier = "unknown" }
    # `improve` runs its MODEL review only when a model opinion can be trusted
    # against this caller (G34). Read once here so Run-Improve cannot forget it.
    $script:ImproveModelReview = $true
    if ($decision.PSObject.Properties.Name -contains "modelReview") {
        try { $script:ImproveModelReview = [bool]$decision.modelReview } catch {}
    }
    $tier = [string]$decision.tier
    # A tier-2 model may refine an uncertain rule, but it knows nothing about who
    # is calling: letting it overrule the quality guard would undo the one promise
    # section 13 makes to a strong caller.
    if ($callerTier -eq "guard") { $decision.escalate = $false }
    # With a web door up the fast model has nothing to decide: every mode it could pick ends in the same
    # web chat, and it would spend up to 20 s of the caller's wait first.
    if ($decision.escalate -and $decision.tier -eq "rules" -and -not (Test-WebDoorsUp)) {
        # The rules are unsure: let one fast model have the last word.
        $escalated = Get-EscalatedMode -Task $Prompt -HasDraft (-not [string]::IsNullOrWhiteSpace($draftText)) -Fallback $mode
        if ($escalated -ne $mode) {
            [Console]::Error.WriteLine("[Delegator] быстрая модель изменила режим: $mode -> $escalated")
            $mode = $escalated
            $tier = "model"
        } else {
            $tier = "model-agreed"
        }
    }
    # A mode that needs a draft cannot run without one, whatever the router said.
    if ($mode -eq "improve" -and [string]::IsNullOrWhiteSpace($draftText)) { $mode = "delegate" }

    if ($decision.PSObject.Properties.Name -contains "tier") { $decision.tier = $tier }
    Write-RouterDecision -Decision $decision -Mode $mode -ElapsedMs $routeSw.ElapsedMilliseconds
    Write-DelegateMetric -Stage "route" -Status $mode -LatencyMs $routeSw.ElapsedMilliseconds `
        -Extra ("reason={0};tier={1};conf={2};caller={3};callerDpr={4};bestDpr={5}" -f `
            $decision.reason, $decision.tier, $decision.confidence, $callerTier, $callerDpr, $bestDpr)
    [Console]::Error.WriteLine("[Delegator] режим: $mode ($($decision.reason), $($routeSw.ElapsedMilliseconds) мс)")
    if ($callerTier -ne "unknown") {
        $callerNote = switch ($callerTier) {
            "amplify" { "усиливаем ответ: вызвавшая модель $callerDpr, наша лучшая $bestDpr" }
            "guard" { "бережём качество: вызвавшая модель $callerDpr сильнее нашей лучшей $bestDpr" }
            default { "паритет: вызвавшая модель $callerDpr ($callerConfidence), наша лучшая $bestDpr ($bestConfidence)" }
        }
        [Console]::Error.WriteLine("[Delegator] $callerNote")
    }

    # Owner's rule, 2026-10-26: a caller that NAMED itself but has no usable rating
    # cannot be compared with any delegate, so a delegate can only make its answer
    # worse. Keep it. `improve` stays: it checks the draft and does not replace it.
    if ($mode -ne "improve" -and -not [string]::IsNullOrWhiteSpace($CallerModel) -and $callerDpr -le 0) {
        # The router's judgement about the TASK still holds: a design question is worth two opinions
        # whoever asks. Only the comparison with the caller is off the table.
        if ($mode -eq "boost") { $script:Boost = $true }
        $mode = "keep"
    }

    switch ($mode) {
        "improve" { Run-Improve }
        "boost" { $script:Boost = $true; Run-Ask }
        "keep" {
            # The web chat costs the caller no tokens and no API quota, and it is the strongest model it offers.
            # Before keeping the caller's own answer, try it - web only, no ladder. Nothing answered: keep.
            $keepPrompt = $Prompt
            if ($ContextFile -and @($ContextFile).Count -gt 0) {
                $keepContext = Read-ContextFiles -Entries $ContextFile -Budget 60000
                if (-not [string]::IsNullOrWhiteSpace($keepContext)) { $keepPrompt += "`n`nFILES THE CALLER READ:`n$keepContext" }
            }
            $keepWeb = Get-WebOrCachedAnswer -Text $keepPrompt -Started ([System.Diagnostics.Stopwatch]::StartNew())
            if ($null -ne $keepWeb) {
                Write-DelegateMetric -Stage "route" -Status "web-keep" -LatencyMs 0 -Extra "reason=keep-web-first"
                [Console]::Error.WriteLine("[Delegator] режим: web (вместо keep)")
                $keepWeb
                Exit-Delegate 0
            }
            # Nothing to do that would not cost more than it returns. Exit 3 is
            # the same "keep your own answer" the improve contract already uses,
            # so an agent needs no new branch.
            Exit-Delegate 3
        }
        default { Run-Ask }
    }
}

function Invoke-ImproveCall {
    # One review or rewrite call: the web chat when it is up (the strongest model, no API quota), and the
    # usual failover ladder when it is not or it fails. Same shape as Invoke-DelegateAcrossBackends.
    param([string]$Text, [string]$ApiBackend, [string]$ApiModel, [string]$Cx, [string]$CallStage, [string]$Reasoning = "")
    if (Test-WebDoorsUp) {
        $answer = Invoke-WebTurn -Text $Text -Reasoning $Reasoning -Timeout 180
        if ($null -ne $answer) {
            $script:ImproveWebModel = [string]$script:FinalModel
            return [pscustomobject]@{ exitCode = 0; output = $answer; backend = $ApiBackend; model = $ApiModel; fellBack = $false }
        }
    }
    return Invoke-DelegateAcrossBackends -ChosenBackend $ApiBackend -Text $Text -ChosenModel $ApiModel -EffectiveComplexity $Cx -Stage $CallStage
}

function Run-Improve {
    $improveSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:ImproveMissingContext = 0
    $script:ImproveWebModel = ""
    # The caller already holds a usable answer, so a review is worth only so much of its wait. Measured:
    # 158-734 s. Past this budget the calls stop, and the caller keeps its draft.
    $improveDeadline = (Get-Date).AddSeconds($script:ImproveBudgetSec)
    if ($null -eq $script:AssistDeadline -or $improveDeadline -lt $script:AssistDeadline) { $script:AssistDeadline = $improveDeadline }
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
    # A draft that carries code is reviewed by a free route only at the cost of a
    # wrong verdict: the 2026-10-26 benchmark lost 146 s to an empty openrouter/free
    # reply on a «refactoring» review. Any code draft counts as heavy here, whatever
    # domain the task was classified into.
    $draftCarriesCode = [bool]($draftForReview -match '```|\bdef\s|\bclass\s|\bfunction\s|#include|\bpublic\s+static\b')
    $improveViaWeb = Test-WebDoorsUp
    if (-not $improveViaWeb -and [string]::IsNullOrWhiteSpace($Model) -and (Test-FreeModelId $reviewer.model) -and ((Test-HeavyTaskText $task) -or $draftCarriesCode)) {
        # A free route reviewing a heavy task only rewrites the draft for the worse
        # (benchmark 2026-10-26: check-failed on openrouter/free). Keep the draft.
        Exit-Delegate 3
    }
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

    # ── Mechanical-only review (section 13) ──
    # The caller is stronger than anything we can reach. Two things follow, and
    # both are refusals to spend:
    #
    #   * No model REVIEW. G34, measured: a reviewer weaker than the thing it
    #     reviews invents defects it cannot justify. §11 survives because it
    #     COMPILES the draft - those defects are facts, and they cost nothing.
    #   * No model REWRITE either. §11b would guarantee the rewrite clears the
    #     proven defect, but it guarantees nothing about the rest of the answer,
    #     and handing a 110-rated model an Opus draft to edit is the one trade
    #     this mode exists to refuse. The proven defects go back on stderr; the
    #     caller is the best rewriter in the room and now has facts it lacked.
    #
    # Zero model calls either way, which is the honest form of "economy" when we
    # have nothing strong enough to earn its keep. Handing the defects back as
    # DATA rather than as stderr prose needs P5 (a machine-readable first line).
    if (-not $script:ImproveModelReview) {
        $mechStatus = if ($mechanical.Count -eq 0) { "keep-mechanical-clean" } else { "keep-mechanical-defects" }
        Write-DelegateMetric -Stage "improve" -Backend $reviewBackend -Status $mechStatus -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($mechanical.Count),calls=0,review=mechanical,ctxmissing=$($script:ImproveMissingContext)"
        if ($mechanical.Count -eq 0) {
            [Console]::Error.WriteLine("[Delegator] improve: механическая проверка дефектов не нашла, ваш ответ сильнее нашего лучшего — оставляем как есть")
        } else {
            [Console]::Error.WriteLine("[Delegator] improve: доказанные дефекты (проверено запуском), правьте сами — наша лучшая модель слабее вашей:")
            foreach ($item in $mechanical) { [Console]::Error.WriteLine("  - $item") }
        }
        if ($callerWantsJson) {
            [pscustomobject]@{
                delegate = "improve"; verdict = $(if ($mechanical.Count -eq 0) { "ok" } else { "major" })
                model = ""; defects = @($mechanical); guard = "mechanical-only"; output = ""
            } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    # Falls over to the other backend rather than giving up: an exhausted
    # OpenCode free tier must not stop Delegator while the Google keys still
    # have quota.
    #
    # Stage "review", NOT "verify": `verify` is a SAVED stage (DEV_CONTRACTS §3)
    # and also the name of the user-facing `verify` command. This call produces
    # nothing the caller ever sees - only the rewrite does - so booking its output
    # as a saving credited Delegator with work nobody received. Internal stages
    # are spent, never saved.
    # Through the web the review and the rewrite are one turn: a second turn would repeat all of the
    # context and the wait, for an answer the reviewer has already worked out.
    $webCorrected = ""
    $reviewPrompt = $checkPrompt
    if ($improveViaWeb) {
        $reviewPrompt = $checkPrompt.Replace("Do not rewrite the answer here.", "Do not rewrite the answer inside the JSON.") + @"


If and only if your verdict is major or wrong: after the JSON object write a line containing exactly @@CORRECTED@@ and then the complete corrected answer, fixing every defect you listed, keeping everything that was already correct, the same structure and level of detail, with no preamble and no review notes.
"@
    }
    $checkResult = Invoke-ImproveCall -Text $reviewPrompt -ApiBackend $reviewBackend -ApiModel $reviewModel -Cx "deep" -CallStage "review"
    if ($checkResult.fellBack) {
        $reviewBackend = $checkResult.backend
        $reviewModel = $checkResult.model
        $script:FinalModel = $reviewModel
        $script:FinalProvider = Get-UsageProviderName $reviewBackend
    }
    $checkText = (($checkResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $correctedAt = $checkText.IndexOf("@@CORRECTED@@")
    if ($correctedAt -ge 0) {
        $webCorrected = $checkText.Substring($correctedAt + "@@CORRECTED@@".Length).Trim()
        $checkText = $checkText.Substring(0, $correctedAt).Trim()
    }
    if ($checkResult.exitCode -ne 0) {
        Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "check-failed" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain
        [Console]::Error.WriteLine("[Delegator] improve: every backend failed, keeping your draft")
        Exit-Delegate 1
    }
    $verdictObj = Get-ImproveVerdict $checkText
    $reviewCalls = 1
    $reasked = 0

    # ── One bounded, TARGETED re-ask ──
    # The reviewer answered; we just could not read it. Repeating the review
    # would only produce the same unreadable answer, so the second call is a
    # different, much smaller question: restate YOUR OWN review as the schema.
    # Bounded at one - a model that cannot produce four characters of JSON twice
    # will not produce them on the third try, and `improve` must not turn into an
    # open-ended loop against a free tier.
    if (Test-ShouldReaskVerdict -RawText $checkText -Parsed $verdictObj) {
        $reviewNote = $checkText
        if ($reviewNote.Length -gt $script:ImproveReaskBudget) {
            $reviewNote = $reviewNote.Substring(0, $script:ImproveReaskBudget) + "`n... [truncated]"
        }
        # The schema is DESCRIBED, never printed as a complete object. A reviewer
        # that echoes its instructions would hand back a parseable verdict we
        # wrote ourselves, and Get-ImproveVerdict takes the first candidate whose
        # verdict is one of the four - so the example would BE the answer.
        $reaskPrompt = @"
Your previous reply was meant to be one JSON object and could not be parsed.
Do not review anything again. Restate the review you already gave, unchanged, as strict minified JSON and nothing else.
The object has exactly three keys:
- verdict: one of the four words ok, minor, major, wrong
- defects: a list of objects, each with a "defect" string and a "failingCase" string
- confidence: an integer from 0 to 100
No prose, no code fence, no explanation, no second object, no copy of these instructions.
Drop any defect you cannot give a concrete failingCase for.
If your review did not actually find a defect, use verdict ok and an empty defects list.

YOUR PREVIOUS REPLY:
$reviewNote
"@
        $reaskResult = Invoke-ImproveCall -Text $reaskPrompt -ApiBackend $reviewBackend -ApiModel $reviewModel -Cx "fast" -CallStage "review" -Reasoning "low"
        $reviewCalls++
        $reasked = 1
        if ($reaskResult.fellBack) {
            $reviewBackend = $reaskResult.backend
            $reviewModel = $reaskResult.model
            $script:FinalModel = $reviewModel
            $script:FinalProvider = Get-UsageProviderName $reviewBackend
        }
        if ($reaskResult.exitCode -eq 0) {
            $reaskText = (($reaskResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim()
            $reaskObj = Get-ImproveVerdict $reaskText
            # Only when the second try produced something USABLE. A re-ask that
            # is also unreadable must leave the first result in place, not
            # replace a $null with a different $null.
            if (-not (Test-ShouldReaskVerdict -RawText $reaskText -Parsed $reaskObj)) {
                $verdictObj = $reaskObj
            }
        }
    }

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
            Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "verdict-unparsable" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "calls=$reviewCalls,reask=$reasked,ctxmissing=$($script:ImproveMissingContext)"
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
        Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "keep-$verdict" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),unsupported=$unsupported,calls=$reviewCalls,reask=$reasked,parse=$($verdictObj.parseMode),ctxmissing=$($script:ImproveMissingContext)"
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
    # A correction that came with the review carries the reviewer's own defects: no second turn then.
    $rewriteResult = if (-not [string]::IsNullOrWhiteSpace($webCorrected)) {
        [pscustomobject]@{ exitCode = 0; output = $webCorrected; backend = $reviewBackend; model = $reviewModel; fellBack = $false }
    } else {
        Invoke-ImproveCall -Text $rewritePrompt -ApiBackend $reviewBackend -ApiModel $reviewModel -Cx "deep" -CallStage "improve"
    }
    if ($rewriteResult.fellBack) {
        $reviewBackend = $rewriteResult.backend
        $reviewModel = $rewriteResult.model
        $script:FinalModel = $reviewModel
        $script:FinalProvider = Get-UsageProviderName $reviewBackend
    }
    $improved = Filter-ConversationalNoise ((($rewriteResult.output | ForEach-Object { [string]$_ }) -join "`n").Trim())
    if ($rewriteResult.exitCode -ne 0) {
        Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "rewrite-failed" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=$(($reviewCalls + 1)),reask=$reasked,parse=$($verdictObj.parseMode),ctxmissing=$($script:ImproveMissingContext)"
        [Console]::Error.WriteLine("[Delegator] improve: the rewrite failed, keeping your draft")
        Exit-Delegate 1
    }
    # The rewrite gets the same mechanical treatment as the draft did. Benchmark
    # run #8: a 13/13 answer came back as 2/13 because the rewrite used
    # re.fullmatch and put `import re` in a SEPARATE block with a note to move
    # it. Nothing checked the rewrite at all - only the draft was ever linted.
    $rewriteProblems = @(Get-MechanicalDefects -Task $task -Draft $draft -Rewrite $improved -WantRewriteDefects)
    if ($rewriteProblems.Count -gt 0) {
        Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "guard-rewrite-broken" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=$(($reviewCalls + 1)),reask=$reasked,parse=$($verdictObj.parseMode),guard=fail,reason=$($rewriteProblems[0])"
        [Console]::Error.WriteLine("[Delegator] improve: rewrite is worse than the draft, keeping yours - $($rewriteProblems[0])")
        if ($callerWantsJson) {
            [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = "rewrite-broken"; output = "" } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    $guard = Test-ImproveGuards -Draft $draft -Improved $improved
    if (-not [string]::IsNullOrWhiteSpace($guard)) {
        Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "guard-$guard" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=$(($reviewCalls + 1)),reask=$reasked,parse=$($verdictObj.parseMode),guard=fail,ctxmissing=$($script:ImproveMissingContext)"
        [Console]::Error.WriteLine("[Delegator] improve: rewrite rejected by guard '$guard', keeping your draft")
        if ($callerWantsJson) {
            [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = $guard; output = "" } | ConvertTo-Json -Depth 4
        }
        Exit-Delegate 3
    }

    Write-DelegateMetric -Stage "improve" -Model $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel }) -Backend $(if ($script:ImproveWebModel) { "web" } else { $reviewBackend }) -Status "improved-$verdict" -LatencyMs $improveSw.ElapsedMilliseconds -Domain $taskDomain -Extra "defects=$($defects.Count),calls=$(($reviewCalls + 1)),reask=$reasked,parse=$($verdictObj.parseMode),guard=pass,ctxmissing=$($script:ImproveMissingContext)"
    if ($callerWantsJson) {
        [pscustomobject]@{ delegate = "improve"; verdict = $verdict; model = $reviewModel; defects = $defects; guard = "pass"; output = $improved } | ConvertTo-Json -Depth 4
    } else {
        $header = [pscustomobject]@{
            verdict = $verdict
            defects = $defects.Count
            model   = $(if ($script:ImproveWebModel) { $script:ImproveWebModel } else { $reviewModel })
        } | ConvertTo-Json -Compress
        Write-Output ("##DELEGATOR_IMPROVE## " + $header)
        Write-Output $improved
    }
    Exit-Delegate 0
}

function Get-AttachmentMime {
    # Gemini's upload decides by the page's accept list; the mime only labels the File the page receives.
    param([string]$Path)
    switch ([System.IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".webp" { return "image/webp" }
        ".gif" { return "image/gif" }
        ".heic" { return "image/heic" }
        ".heif" { return "image/heif" }
        ".pdf" { return "application/pdf" }
        default { return "application/octet-stream" }
    }
}

function Invoke-WebDelegation {
    <#
      The «Web» integration (the second column of the «Интеграция» tab): when it is switched
      on and the Chrome extension is connected, a plain delegation goes to the
      user's own signed-in web chat - the strongest model it offers at its
      highest reasoning level - as ONE call.

      One call on purpose. Everything the normal path wraps around a model
      (planner, triage, extract, boost fan-out, critique loop) is one more web
      turn of tens of seconds each; with a model this strong the extra rounds
      cost far more than they could ever improve.

      Returns the answer text, or $null when the web path is not applicable or
      failed - the caller then simply runs the ordinary ladder.
    #>
    param([string]$Text, [string]$WebReasoning = "", [int]$WebTimeout = 300)

    # The benchmark door already tried the web chat (and its model ladder) for this call; a second
    # try would only repeat the wait - measured: two 500 s timeouts back to back.
    if (-not (Test-WebEligible $Text)) { return $null }
    # Text files are already inside $Text (Run-Ask). The other files go to Gemini as attachments; the other doors carry text only.
    $binaryFiles = @(Get-BinaryContextFiles)
    # Text that talks about a picture is refused only when no picture goes along: Gemini Web takes the
    # attachment, so a picture question with its file attached is a web question.
    if ((Test-VisionContent $Text) -and $binaryFiles.Count -eq 0) { return $null }
    if (-not (Test-WebDoorsUp)) { return $null }

    # Attachments for Gemini (name, mime, base64). Without Gemini a binary file cannot go along: the usual models answer.
    $fileList = @()
    if ($binaryFiles.Count -gt 0) {
        $geminiDoor = @((Get-WebDoorsState).doors | Where-Object { $_.id -eq "gemini" -and $_.enabled })
        if ($geminiDoor.Count -eq 0) {
            [Console]::Error.WriteLine("[Delegator] Web: a non-text file needs Gemini Web for attachment, using the usual models")
            return $null
        }
        $attachedBytes = 0
        foreach ($cp in $binaryFiles) { $attachedBytes += (Get-Item -LiteralPath $cp).Length }
        if ($attachedBytes -gt 12MB) {
            [Console]::Error.WriteLine("[Delegator] Web: attachments are over 12 MB, using the usual models")
            return $null
        }
        foreach ($cp in $binaryFiles) {
            $fileList += @{
                name = [System.IO.Path]::GetFileName($cp)
                mime = Get-AttachmentMime $cp
                data_base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($cp))
            }
        }
    }

    $light = [string]::IsNullOrWhiteSpace($WebReasoning) -and $fileList.Count -eq 0 -and (Test-LightWebTask $Text)
    return Invoke-WebTurn -Text (Add-ExecutionLanguagePolicy $Text) -Reasoning $WebReasoning -Files $fileList -Timeout $WebTimeout -Light:$light
}

function Test-WebEligible {
    param([string]$Text)
    if ($script:WebTried) { return $false }
    if ($Backend -ne "auto" -or -not [string]::IsNullOrWhiteSpace($Model)) { return $false }
    if ($env:CODEX_DELEGATE_BOOST_ACTIVE -eq "1") { return $false }
    if ($Text -match "^Reply exactly:") { return $false }
    return $true
}

function Get-BinaryContextFiles {
    $found = @()
    foreach ($entry in @($ContextFile)) {
        foreach ($piece in ([string]$entry).Split(";")) {
            $cp = $piece.Trim()
            if ($cp -and (Test-Path -LiteralPath $cp -PathType Leaf) -and -not (Test-TextFile $cp)) { $found += $cp }
        }
    }
    return $found
}

function Test-LightWebTask {
    # A short plain question needs no top reasoning level: Argon at «Высокий» thought 33 s before
    # saying one word (measured). Only short text with no code and no heavy-task words qualifies.
    param([string]$Text)
    if ($Text.Length -gt 1200) { return $false }
    if ($Text -match '```|\bdef\s|\bclass\s|\bfunction\s|#include') { return $false }
    return -not (Test-HeavyTaskText $Text)
}

function Get-WebDoorsState {
    # Read once per run: a request's route does not change while it is being decided.
    if ($script:WebDoorsRead) { return $script:WebDoorsState }
    $script:WebDoorsRead = $true
    $script:WebDoorsState = $null
    try { $script:WebDoorsState = Invoke-RestMethod -Uri "http://127.0.0.1:1380/api/web/doors" -TimeoutSec 3 } catch {}
    return $script:WebDoorsState
}

function Get-WebBestStrength {
    # DPR of the strongest door that could answer now; 0 when none. Only the state already known or
    # cheaply read: never a wait for the extension.
    $state = Get-WebDoorsState
    if ($null -eq $state -or $state.paused) { return 0 }
    $usable = @($state.doors | Where-Object { $_.enabled -and [int]$_.resting_sec -eq 0 })
    if ($usable.Count -eq 0) { return 0 }
    return [int](($usable | Measure-Object -Property strength -Maximum).Maximum)
}

function Test-WebDoorsUp {
    # True when at least one door can take a turn. An idle MV3 service worker sleeps and its 30 s alarm
    # wakes it, so a recently seen extension is worth waiting for. One not seen for minutes means Chrome
    # is closed: waiting for it spent 50 s of every request on nothing.
    if ($null -ne $script:WebUp) { return $script:WebUp }
    $script:WebUp = $false
    $state = Get-WebDoorsState
    if ($null -eq $state -or $state.paused) { return $false }
    $usable = @($state.doors | Where-Object { $_.enabled -and ($_.auth -ne "signed_out" -or [int]$_.resting_sec -eq 0) })
    if ($usable.Count -eq 0) { return $false }
    if ($state.connected) { $script:WebUp = $true; return $true }
    $patience = if ($null -eq $state.seen_age) { 8 } elseif ([double]$state.seen_age -le 300) { 35 } else { 0 }
    for ($wait = 0; $wait -lt $patience; $wait++) {
        Start-Sleep -Seconds 1
        try {
            if ((Invoke-RestMethod -Uri "http://127.0.0.1:1380/api/web/doors" -TimeoutSec 3).connected) {
                $script:WebUp = $true
                return $true
            }
        } catch {}
    }
    [Console]::Error.WriteLine("[Delegator] Web: the Chrome extension is not connected, using the usual models")
    Write-DelegateMetric -Stage "web" -Backend "web" -Status "not-connected"
    return $false
}

function Invoke-WebTurn {
    # One turn through the core's race. The caller decided that the web is the right place for it.
    param([string]$Text, [string]$Reasoning = "", [array]$Files = @(), [int]$Timeout = 300, [switch]$Light)
    $webSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if ($null -ne $script:AssistDeadline) {
            $left = [int]($script:AssistDeadline - (Get-Date)).TotalSeconds
            if ($left -lt 30) { return $null }
            $Timeout = [math]::Min($Timeout, $left)
        }
        $ask = @{ text = $Text; timeout_sec = $Timeout; files = @($Files); light = [bool]$Light }
        if (-not [string]::IsNullOrWhiteSpace($Reasoning)) { $ask.reasoning = $Reasoning }
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(($ask | ConvertTo-Json -Compress))
        # Decoded as UTF-8 by hand: the Core's JSON carries no charset, and 5.1
        # reads such a body as Latin-1 (I3) - every Cyrillic letter became two.
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:1380/api/web/ask" -Method Post -Body $bytes `
            -ContentType "application/json; charset=utf-8" -TimeoutSec ($Timeout + 40) -UseBasicParsing
        $reply = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json
        $answer = [string]$reply.text
        if ([string]::IsNullOrWhiteSpace($answer)) { throw "empty answer" }
        $used = [string]$reply.model
        $script:FinalModel = $used
        $script:FinalProvider = "web"
        # The line the owner reads in the IDE to confirm WHICH model answered.
        [Console]::Error.WriteLine("[Delegator] Web: ответила модель '$used' ($($reply.provider)) за $([math]::Round($webSw.Elapsed.TotalSeconds, 1)) с")
        Write-DelegateMetric -Stage "web" -Model $used -Backend "web" -LatencyMs $webSw.ElapsedMilliseconds -Status "ok" -Extra "door=$($reply.door)"
        return $answer
    } catch {
        $why = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $why = $_.ErrorDetails.Message }
        [Console]::Error.WriteLine("[Delegator] Web failed ($why), using the usual models")
        Write-DelegateMetric -Stage "web" -Backend "web" -LatencyMs $webSw.ElapsedMilliseconds -Status "failed"
        return $null
    }
}

function Invoke-WebBoost {
    # A task the router judged worth more than one opinion: the two strongest doors answer it at once,
    # and the strongest of them reconciles the two. Null when fewer than two doors can take it, and the
    # caller then asks one door as usual.
    param([string]$Text)
    if (-not (Test-WebEligible $Text)) { return $null }
    if ((Test-VisionContent $Text) -or @(Get-BinaryContextFiles).Count -gt 0) { return $null }
    if (-not (Test-WebDoorsUp)) { return $null }
    $ready = @((Get-WebDoorsState).doors | Where-Object { $_.enabled -and [int]$_.resting_sec -eq 0 })
    if ($ready.Count -lt 2) { return $null }
    $webSw = [System.Diagnostics.Stopwatch]::StartNew()
    $policy = Add-ExecutionLanguagePolicy $Text
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ text = $policy; size = 2; timeout_sec = 240 } | ConvertTo-Json -Compress))
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:1380/api/web/panel" -Method Post -Body $bytes `
            -ContentType "application/json; charset=utf-8" -TimeoutSec 280 -UseBasicParsing
        $answers = @(([System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray()) | ConvertFrom-Json).answers)
    } catch {
        [Console]::Error.WriteLine("[Delegator] Web panel failed, asking one door")
        return $null
    }
    if ($answers.Count -eq 0) { return $null }
    $script:FinalProvider = "web"
    $script:FinalModel = [string]$answers[0].model
    if ($answers.Count -eq 1) {
        Write-DelegateMetric -Stage "web-boost" -Model $script:FinalModel -Backend "web" -LatencyMs $webSw.ElapsedMilliseconds -Status "one-answer"
        return [string]$answers[0].text
    }
    $judgePrompt = @"
Two strong assistants answered the TASK below independently. Write the single best final answer.
Check where they disagree and work out which is right. Keep what is correct from either, drop what is wrong or unsupported, and do not average a correct claim with a wrong one.
Output the final answer only: no comparison, no mention of the two answers.

TASK:
$Text

ANSWER A:
$($answers[0].text)

ANSWER B:
$($answers[1].text)
"@
    $final = Invoke-WebTurn -Text (Add-ExecutionLanguagePolicy $judgePrompt) -Timeout 180
    $status = if ($null -ne $final) { "reconciled" } else { "judge-failed" }
    Write-DelegateMetric -Stage "web-boost" -Model $script:FinalModel -Backend "web" -LatencyMs $webSw.ElapsedMilliseconds -Status $status
    [Console]::Error.WriteLine("[Delegator] Web boost: $($answers[0].door) + $($answers[1].door), $status, $([math]::Round($webSw.Elapsed.TotalSeconds, 1)) с")
    # The judge failed: the strongest door's own answer still stands.
    if ($null -ne $final) { return $final }
    return [string]$answers[0].text
}

function Get-WebOrCachedAnswer {
    # The cache in front of the web: an identical question costs nothing the second time, on any route.
    # A very short prompt is left out, because "continue" means something else in every conversation.
    param([string]$Text, [System.Diagnostics.Stopwatch]$Started)
    # With an attachment the key would not cover the question: "what is on this screenshot?" must not
    # get yesterday's screenshot.
    $cacheable = $Text -notmatch "^Reply exactly:" -and $Backend -eq "auto" -and [string]::IsNullOrWhiteSpace($Model) -and $Text.Length -ge 60 -and @(Get-BinaryContextFiles).Count -eq 0
    $hash = ""
    $domain = ""
    if ($cacheable) {
        $hash = Get-PromptHash $Text -Variant (Get-CacheVariant)
        $domain = Get-TaskDomain $Text
        $hit = Find-CachedResponse -PromptHash $hash -Domain $domain
        if ($hit) {
            [Console]::Error.WriteLine("[Delegator] ответ из кэша")
            Write-DelegateMetric -Stage "cache-hit" -Status "ok" -LatencyMs $Started.ElapsedMilliseconds -Domain $domain
            return $hit
        }
    }
    $answer = if ($script:Boost) { Invoke-WebBoost $Text } else { $null }
    if ($null -eq $answer) { $answer = Invoke-WebDelegation $Text }
    if ($null -ne $answer -and $cacheable) {
        Add-CachedResponse -PromptHash $hash -Response $answer -Model $script:FinalModel -Domain $domain
    }
    return $answer
}

function Run-Ask {
    $askSw = [System.Diagnostics.Stopwatch]::StartNew()
    if ([string]::IsNullOrWhiteSpace($Prompt)) {
        if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
        $Prompt = [Console]::In.ReadToEnd()
    }

    # The caller's text -ContextFile files reach the model here, as they already do on the
    # improve and benchmark doors. Before this no plain-path door read them: the web chat
    # answered "no attachment" (G115). A binary file is still refused by Invoke-WebDelegation.
    if ($ContextFile -and @($ContextFile).Count -gt 0) {
        $askContext = Read-ContextFiles -Entries $ContextFile -Budget 60000
        if (-not [string]::IsNullOrWhiteSpace($askContext)) {
            $Prompt = $Prompt + "`n`nFILES THE CALLER READ:`n$askContext"
        }
    }

    $webOrCached = Get-WebOrCachedAnswer -Text $Prompt -Started $askSw
    if ($null -ne $webOrCached) {
        $webOrCached
        return
    }
    # Only the web chat can take a binary file. The ladder would answer about a file it never saw:
    # asked for a picture's colour, it said «Отсутствует» with full confidence (measured).
    if ($Backend -eq "auto" -and [string]::IsNullOrWhiteSpace($Model) -and @(Get-BinaryContextFiles).Count -gt 0 -and (Test-WebDoorsUp)) {
        [Console]::Error.WriteLine("[Delegator] the attached file could not be delivered, no answer rather than a wrong one")
        Write-DelegateMetric -Stage "web" -Backend "web" -LatencyMs $askSw.ElapsedMilliseconds -Status "attachment-undelivered"
        Exit-Delegate 1
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
            # The strongest enabled Gemini model that is NOT in cooldown. The
            # cooldown is only ever set after the model failed on EVERY key (the
            # provider script rotates keys on 429 first), so while Pro is out of
            # quota that is the newest Flash - a newer generation than the
            # `pro-latest` alias, which still resolves to 3.1.
            $proModel = Get-StrongEnabledGeminiModel
            if ([string]::IsNullOrWhiteSpace($proModel)) { $proModel = "gemini-pro-latest" }
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

# Dot-sourcing loads the functions WITHOUT running a command - the same guard
# opencode-delegate.ps1 already uses. It exists so tests/ps can unit-test the pure
# helpers of the largest script in the product; without it `. ai-delegate.ps1`
# falls through to the default command ("ask") and makes a network call.
if ($MyInvocation.InvocationName -eq ".") { return }

# The finally block guarantees the per-request usage file is aggregated/removed and
# the ##DELEGATOR_USAGE## marker (when requested) is the LAST stdout line, on every
# exit path including `exit` inside the Run-* handlers.
try {
switch ($Command) {
    "assist" { Run-Assist }
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
    "ping" { Run-Ping }
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

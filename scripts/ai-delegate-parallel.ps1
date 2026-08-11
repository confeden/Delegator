param(
    [Parameter(Position = 0)]
    [string]$Command = "ask",
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$PromptsAndFlags
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom

$prompts = @()
$promptFiles = @()
$complexity = "auto"
$timeoutSec = 180
$maxParallel = 4
$json = $false
$noDiverseModels = $false
$explicitModels = $null
for ($i = 0; $i -lt $PromptsAndFlags.Length; $i++) {
    $arg = $PromptsAndFlags[$i]
    switch -Regex ($arg) {
        '^-{1,2}Complexity$' { $complexity = $PromptsAndFlags[++$i]; continue }
        '^-{1,2}TimeoutSec$' { $timeoutSec = [int]$PromptsAndFlags[++$i]; continue }
        '^-{1,2}MaxParallel$' { $maxParallel = [int]$PromptsAndFlags[++$i]; continue }
        '^-{1,2}PromptFile$' { if ($i + 1 -lt $PromptsAndFlags.Length) { $promptFiles += [string]$PromptsAndFlags[++$i] }; continue }
        '^-{1,2}Json$' { $json = $true; continue }
        '^-{1,2}NoDiverseModels$' { $noDiverseModels = $true; continue }
        '^-{1,2}ExplicitModels$' { $explicitModels = $PromptsAndFlags[++$i]; continue }
        '^-' { continue }
        default { $prompts += $arg }
    }
}
# -PromptFile transport (DEV_CONTRACTS section 1): repeatable, each UTF-8 file is
# one prompt, used alongside any positional prompts.
foreach ($pf in $promptFiles) {
    if ([string]::IsNullOrWhiteSpace($pf)) { continue }
    if (-not (Test-Path -LiteralPath $pf)) { throw "Prompt file not found: $pf" }
    $prompts += ,([System.IO.File]::ReadAllText($pf, [System.Text.UTF8Encoding]::new($false)))
}
if ($prompts.Count -eq 0) { throw "No prompts provided for parallel execution." }

$defaultPool = @(
    "gemini-flash-lite-latest",
    "opencode/deepseek-v4-flash-free",
    "opencode/ling-3.0-flash-free"
)
$models = if ($explicitModels) { @($explicitModels -split ",") } else {
    @(for ($i = 0; $i -lt $prompts.Count; $i++) {
        if ($noDiverseModels) { $defaultPool[0] } else { $defaultPool[$i % $defaultPool.Count] }
    })
}

$entryPoint = Join-Path $PSScriptRoot "ai-delegate.ps1"
$jobs = @()
for ($i = 0; $i -lt $prompts.Count; $i++) {
    while (@($jobs | Where-Object State -eq Running).Count -ge [Math]::Max(1, $maxParallel)) {
        Wait-Job -Job $jobs -Any -Timeout 1 | Out-Null
    }
    $model = $models[$i % $models.Count]
    $jobs += Start-Job -ScriptBlock {
        param($cmd, $text, $cx, $limit, $target, $asJson, $runtimeHome)
        if ($runtimeHome) { $env:DELEGATOR_RUNTIME_HOME = $runtimeHome }
        # Nested dispatcher runs must never emit the usage marker; the top-level
        # request owner aggregates the shared DELEGATOR_USAGE_FILE instead.
        $env:DELEGATOR_EMIT_USAGE = "0"
        # In-process invocation with real named parameters: ai-delegate.ps1 is an
        # advanced script, so `--Flag` argv tokens fail parameter binding.
        $callParams = @{
            Command    = "ask"
            PromptArg  = $text
            Complexity = $cx
            TimeoutSec = [int]$limit
            NoPlanner  = $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$target)) { $callParams.Model = $target }
        if ($asJson) { $callParams.Json = $true }
        try {
            $output = & $cmd @callParams 2>&1 | Out-String
            $code = $LASTEXITCODE
            if ($null -eq $code) { $code = 0 }
        } catch {
            $output = $_.Exception.Message
            $code = 1
        }
        [pscustomobject]@{ model = $target; output = ([string]$output).Trim(); exitCode = $code }
    } -ArgumentList $entryPoint, $prompts[$i], $complexity, $timeoutSec, $model, $json, $env:DELEGATOR_RUNTIME_HOME
}

$results = @()
foreach ($job in $jobs) {
    Wait-Job $job -Timeout ($timeoutSec + 10) | Out-Null
    $row = Receive-Job $job
    if ($row) { $results += $row } else { $results += [pscustomobject]@{ model = "unknown"; output = "Timed out"; exitCode = 124 } }
    Remove-Job $job -Force
}

if ($json) {
    $results | ConvertTo-Json -Depth 8
} else {
    for ($i = 0; $i -lt $results.Count; $i++) {
        Write-Output "=== SUB-TASK $($i + 1) (Model: $($results[$i].model)) ==="
        Write-Output $results[$i].output
        Write-Output ""
    }
}

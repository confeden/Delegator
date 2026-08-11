param(
    [Parameter(Position = 0)]
    [string]$Prompt,
    [int]$TimeoutSec = 45,
    [switch]$Json,

    # UTF-8 text file containing the full prompt (DEV_CONTRACTS section 1).
    # Precedence: -PromptFile > stdin > positional prompt.
    [string]$PromptFile
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $Utf8NoBom
[Console]::OutputEncoding = $Utf8NoBom
$MicroDelegate = Join-Path $PSScriptRoot "ai-delegate-micro.ps1"
$PlanModel = "opencode/deepseek-v4-flash-free"

if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
    $Prompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.UTF8Encoding]::new($false))
}
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
    $Prompt = [Console]::In.ReadToEnd()
}
if ([string]::IsNullOrWhiteSpace($Prompt)) { throw "Prompt is required." }

$PlanPrompt = @"
Analyze this programming or system task. Decide whether it can be split into independent parallel sub-tasks.
Return strict minified JSON only:
{"mode":"parallel|single","prompts":["..."],"complexity":"fast|normal|deep","backend":"auto|gemini|opencode","preprocess":"none|extract","verify":true,"reason":"short"}
Use parallel only for 2 to 4 genuinely independent sub-tasks. Preserve every explicit constraint.

TASK:
$Prompt
"@

try {
    $result = & $MicroDelegate -Prompt $PlanPrompt -TimeoutSec $TimeoutSec -Model $PlanModel -Json 2>&1 | Out-String
    $clean = $result.Trim()
    $start = $clean.IndexOf("{")
    $end = $clean.LastIndexOf("}")
    if ($start -ge 0 -and $end -gt $start) {
        Write-Output $clean.Substring($start, $end - $start + 1)
        exit 0
    }
} catch {}

@{
    mode = "single"
    prompts = @($Prompt)
    complexity = "normal"
    backend = "auto"
    preprocess = "none"
    verify = $false
    reason = "Planning model was unavailable"
} | ConvertTo-Json -Compress

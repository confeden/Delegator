param(
    [Parameter(Position = 0)]
    [string]$Prompt,

    [int]$TimeoutSec = 45,
    [string]$Model,
    [switch]$Async,
    [switch]$Json,

    # UTF-8 text file containing the full prompt (DEV_CONTRACTS section 1).
    # Precedence: -PromptFile > stdin > positional prompt.
    [string]$PromptFile
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "delegator-common.ps1")
$Utf8NoBom = Initialize-DelegateEncoding

$BinHome = $script:DelegateBinHome
$OpenCodeDelegate = Join-Path $BinHome "opencode-delegate.ps1"
$GeminiDelegate = Join-Path $BinHome "gemini-delegate.ps1"
$SettingsFile = $script:DelegateRouterSettingsFile

# Read-Settings uses local path (same as Read-RouterSettings in common)
function Read-Settings {
    return Read-RouterSettings
}

function Shorten-Text {
    param([string]$Text, [int]$Max)
    if ([string]::IsNullOrEmpty($Text) -or $Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "`n...[truncated]"
}

# Get-PreferredOutputLanguage, Get-PrimaryDelegateSkillPolicy, Add-ExecutionLanguagePolicy → delegator-common.ps1

function Get-BackendForModel {
    param([string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return "opencode" }
    if ($ModelName -like "gemini-*") { return "gemini" }
    return "opencode"
}

function Get-DelegateCommand {
    param([string]$BackendName)
    switch ($BackendName) {
        "gemini" { return $GeminiDelegate }
        default { return $OpenCodeDelegate }
    }
}

if (-not [string]::IsNullOrWhiteSpace($PromptFile)) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { throw "Prompt file not found: $PromptFile" }
    $Prompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.UTF8Encoding]::new($false))
}
if ([string]::IsNullOrWhiteSpace($Prompt)) {
    if (-not [Console]::IsInputRedirected) { throw "Prompt is required." }
    $Prompt = [Console]::In.ReadToEnd()
}

# Standalone invocations get their own request id (DEV_CONTRACTS section 2.2);
# when the dispatcher spawned us the id is already present in the environment.
if ([string]::IsNullOrWhiteSpace($env:DELEGATOR_REQUEST_ID)) {
    $env:DELEGATOR_REQUEST_ID = "r-" + [Guid]::NewGuid().ToString("n").Substring(0, 8)
}

if ([string]::IsNullOrWhiteSpace($env:CODEX_DELEGATE_LANGUAGE) -and -not [string]::IsNullOrWhiteSpace($Prompt)) {
    $env:CODEX_DELEGATE_LANGUAGE = Get-PreferredOutputLanguage $Prompt
}

$settings = Read-Settings
$microModel = if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $Model
} elseif ($settings -and $settings.microModel) {
    [string]$settings.microModel
} else {
    "opencode/deepseek-v4-flash-free"
}
$maxPromptChars = if ($settings -and $settings.microMaxPromptChars) { [int]$settings.microMaxPromptChars } else { 100000 }
$maxAnswerChars = if ($settings -and $settings.microMaxAnswerChars) { [int]$settings.microMaxAnswerChars } else { 1600 }

if ($Async) {
    $runId = [Guid]::NewGuid().ToString("n")
    $delegateHome = if ($env:DELEGATOR_RUNTIME_HOME) {
        $env:DELEGATOR_RUNTIME_HOME
    } elseif ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime"
    } else {
        Join-Path $env:APPDATA "DelegatorWin\runtime"
    }
    $promptFile = Join-Path $delegateHome ("micro-prompt-" + $runId + ".txt")
    $outputFile = Join-Path $delegateHome ("micro-output-" + $runId + ".txt")
    $errorFile = Join-Path $delegateHome ("micro-error-" + $runId + ".txt")
    New-Item -ItemType Directory -Force -Path $delegateHome | Out-Null
    [System.IO.File]::WriteAllText($promptFile, $Prompt, [System.Text.UTF8Encoding]::new($false))

    $scriptText = @"
`$ErrorActionPreference = "Continue"
`$prompt = [System.IO.File]::ReadAllText('$($promptFile.Replace("'","''"))', [System.Text.UTF8Encoding]::new(`$false))
Remove-Item -LiteralPath '$($promptFile.Replace("'","''"))' -Force -ErrorAction SilentlyContinue
& '$PSCommandPath' `$prompt -TimeoutSec $TimeoutSec -Model '$($microModel.Replace("'","''"))' > '$($outputFile.Replace("'","''"))' 2> '$($errorFile.Replace("'","''"))'
exit `$LASTEXITCODE
"@
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($scriptText))
    $proc = Start-Process -FilePath powershell.exe -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) -WindowStyle Hidden -PassThru
    $result = [pscustomobject]@{
        delegate = "micro-async"
        model = $microModel
        pid = $proc.Id
        outputFile = $outputFile
        errorFile = $errorFile
    }
    if ($Json) { $result | ConvertTo-Json -Depth 4 } else { $result | ConvertTo-Json -Depth 4 }
    exit 0
}

$task = Shorten-Text -Text $Prompt -Max $maxPromptChars
$looksStructured = (
    $task -match '(?im)^LANGUAGE POLICY:' -or
    $task -match '(?im)^TASK:' -or
    $task -match '(?im)^CURRENT USER MESSAGE:' -or
    $task -match '(?im)^USER MESSAGE:' -or
    $task -match '(?im)^USER REQUEST:' -or
    $task -match '(?im)^OUTPUT RULES:' -or
    $task -match '(?im)^Answer only in English\.'
)
$microPrompt = if ($looksStructured) { $task } else { Add-ExecutionLanguagePolicy $task }
$backend = Get-BackendForModel $microModel
$delegateCmd = Get-DelegateCommand $backend

$oldAgent = $env:CODEX_OPENCODE_AGENT
$setOpenCodeAgent = ($backend -eq "opencode")
if ($setOpenCodeAgent) { $env:CODEX_OPENCODE_AGENT = "delegate-text" }
$microSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $output = & $delegateCmd ask $microPrompt -Complexity fast -TimeoutSec $TimeoutSec -Model $microModel 2>&1
    $code = $LASTEXITCODE
} finally {
    if ($setOpenCodeAgent) {
        if ($null -eq $oldAgent) { Remove-Item Env:\CODEX_OPENCODE_AGENT -ErrorAction SilentlyContinue } else { $env:CODEX_OPENCODE_AGENT = $oldAgent }
    }
}
$text = (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
if ($text.Length -gt $maxAnswerChars) {
    $text = $text.Substring(0, $maxAnswerChars) + "`n...[truncated]"
}

# Usage accounting (DEV_CONTRACTS section 2): token fields stay null here - the
# provider script records the exact split for the same request id.
$microProvider = if ($backend -eq "gemini") { "gemini" } else { "opencode-cli" }
Write-DelegateUsageRecord -Stage "micro" -Mode "micro" -Provider $microProvider -Model $microModel -ElapsedMs ([int]$microSw.ElapsedMilliseconds) -Ok ($code -eq 0)

if ($Json) {
    [pscustomobject]@{
        delegate = "micro"
        model = $microModel
        output = $text
        exitCode = $code
    } | ConvertTo-Json -Depth 4
} else {
    $text
}
exit $code

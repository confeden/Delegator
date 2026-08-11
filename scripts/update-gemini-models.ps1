param(
    [string]$DelegateHome = $(if ($env:DELEGATOR_RUNTIME_HOME) { $env:DELEGATOR_RUNTIME_HOME } else { Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime" })
)

$ErrorActionPreference = "Stop"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$updatedAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")

$catalog = @(
    "gemini-pro-latest",
    "gemini-flash-latest",
    "gemini-flash-lite-latest"
)

# Native generateContent-compatible catalog. Per-user model enablement remains
# controlled by the DPAPI-backed Delegator GUI config.
$active = @(
    [pscustomobject]@{ id = "gemini-pro-latest"; score = 95.0; timeout = 180; tier = "pro" },
    [pscustomobject]@{ id = "gemini-flash-latest"; score = 93.0; timeout = 120; tier = "flash" },
    [pscustomobject]@{ id = "gemini-flash-lite-latest"; score = 88.0; timeout = 75; tier = "lite" }
)
$activeIds = @($active.id)
$deprecated = @()

$rankingPath = Join-Path $DelegateHome "model-rankings.json"
$settingsPath = Join-Path $DelegateHome "delegate-model-settings.json"
foreach ($path in @($rankingPath, $settingsPath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "Required Delegator config is missing: $path" }
    Copy-Item -LiteralPath $path -Destination "$path.bak-$timestamp"
}

function Sync-GeminiRankingRows {
    param([object[]]$Rows)
    $result = @($Rows | Where-Object {
        -not ([string]$_.model).StartsWith("gemini-", [StringComparison]::OrdinalIgnoreCase)
    })
    foreach ($model in $active) {
        $result += [pscustomobject][ordered]@{
            model = $model.id
            name = $model.id
            kind = "gemini"
            score = $model.score
        }
    }
    return $result
}

$rankings = Get-Content -LiteralPath $rankingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$rankings.overall = @(Sync-GeminiRankingRows @($rankings.overall))
foreach ($property in $rankings.domains.PSObject.Properties) {
    $property.Value = @(Sync-GeminiRankingRows @($property.Value))
}
$rankings.version = [Math]::Max([int]$rankings.version, 19)
$rankings.updatedAt = $updatedAt
$rankings.sourceBenchmark = "Google latest aliases + Delegator native API routing 2026-08-03"
$note = "Gemini routes through DPAPI keys stored by Delegator; system keys and Gemini CLI profiles are not used."
if (@($rankings.sourceNotes) -notcontains $note) { $rankings.sourceNotes = @($note) + @($rankings.sourceNotes) }

$settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($id in $catalog) {
    $activeModel = $active | Where-Object id -eq $id | Select-Object -First 1
    $isActive = $null -ne $activeModel
    $entry = [pscustomobject][ordered]@{
        enabled = $isActive
        disabled = -not $isActive
        idleTimeoutSec = if ($isActive) { $activeModel.timeout } else { 120 }
        preferDomains = if ($isActive -and $activeModel.tier -eq "lite") { @("micro", "quick_check", "summarization") } else { @("universal", "architecture", "reasoning", "code_edge_cases", "long_context", "refactoring") }
        avoidDomains = if ($isActive -and $activeModel.tier -eq "lite") { @("security", "architecture", "math_algo") } else { @() }
        notes = "Official generateContent-compatible model routed through Delegator-owned DPAPI keys."
        capabilitySource = "Google Gemini model docs + native generateContent protocol 2026-08-02"
        inputModalities = @("text", "image", "video", "audio", "pdf")
        outputModalities = @("text")
        contentModes = @("text", "image", "video", "audio", "pdf")
        supportsVision = $true
        supportsImageOutput = $false
        supportsRawBinary = $false
        executionPath = "google-api-direct"
        protocol = "Native Gemini API models.generateContent with Delegator DPAPI key rotation"
    }
    if ($settings.models.PSObject.Properties[$id]) {
        $settings.models.PSObject.Properties[$id].Value = $entry
    } else {
        $settings.models | Add-Member -NotePropertyName $id -NotePropertyValue $entry
    }
}

foreach ($id in $deprecated) {
    if (-not $settings.models.PSObject.Properties[$id]) { continue }
    $entry = $settings.models.PSObject.Properties[$id].Value
    if ($entry.PSObject.Properties["enabled"]) { $entry.enabled = $false } else { $entry | Add-Member -NotePropertyName enabled -NotePropertyValue $false }
    if ($entry.PSObject.Properties["disabled"]) { $entry.disabled = $true } else { $entry | Add-Member -NotePropertyName disabled -NotePropertyValue $true }
    if ($entry.PSObject.Properties["notes"]) { $entry.notes = "Disabled: shut down by Google; use the stable replacement." } else { $entry | Add-Member -NotePropertyName notes -NotePropertyValue "Disabled: shut down by Google; use the stable replacement." }
}
$settings.version = [Math]::Max([int]$settings.version, 13)
$settings.updatedAt = $updatedAt

[IO.File]::WriteAllText($rankingPath, ($rankings | ConvertTo-Json -Depth 100), $utf8NoBom)
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 100), $utf8NoBom)

Write-Output "Gemini API delegate catalog: $($catalog.Count)"
Write-Output "Gemini native API routing pool: $($activeIds.Count)"
foreach ($id in $activeIds) { Write-Output "- $id" }
Write-Output "Updated: $rankingPath"
Write-Output "Updated: $settingsPath"

param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "Programs\Delegator"),
    [switch]$Background
)

$ErrorActionPreference = "Stop"
$guiPath = Join-Path $InstallRoot "delegator.exe"
if (-not (Test-Path -LiteralPath $guiPath)) {
    throw "Installed GUI not found: $guiPath"
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $guiPath
$startInfo.WorkingDirectory = $InstallRoot
$startInfo.UseShellExecute = $false
if ($Background) { $startInfo.ArgumentList.Add("--background") }
$startInfo.Environment["PATH"] = (Join-Path $env:WINDIR "System32")
$startInfo.Environment.Remove("PYTHONHOME") | Out-Null
$startInfo.Environment.Remove("PYTHONPATH") | Out-Null
$startInfo.Environment.Remove("DELEGATOR_CORE_PYTHON") | Out-Null

$process = [System.Diagnostics.Process]::Start($startInfo)
$health = $null
for ($attempt = 0; $attempt -lt 40 -and $null -eq $health; $attempt++) {
    Start-Sleep -Milliseconds 500
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:1380/health" -TimeoutSec 2
    } catch {
        # Core extraction and startup can take a few seconds.
    }
}

if ($null -eq $health) {
    throw "Installed Core did not become healthy. GUI PID: $($process.Id)"
}

Write-Output "Installed GUI PID: $($process.Id)"
Write-Output "Started with PATH containing only Windows System32; no Python overrides were set."
Write-Output ($health | ConvertTo-Json -Compress -Depth 8)

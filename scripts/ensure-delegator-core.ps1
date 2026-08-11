$ErrorActionPreference = "Stop"

$coreRoot = if ($env:DELEGATOR_CORE_ROOT) {
    $env:DELEGATOR_CORE_ROOT
} else {
    Split-Path $PSScriptRoot -Parent
}

$standaloneCore = Join-Path $coreRoot "delegator-core.exe"

$serverScript = Join-Path $coreRoot "run_server.py"
$healthUrl = if ($env:DELEGATOR_CORE_HEALTH_URL) {
    $env:DELEGATOR_CORE_HEALTH_URL
} else {
    "http://127.0.0.1:1380/health"
}

function Test-DelegatorCoreHealthy {
    try {
        $response = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 3
        return ($response.ok -eq $true)
    } catch {
        return $false
    }
}

if (Test-DelegatorCoreHealthy) {
    exit 0
}

if (Test-Path -LiteralPath $standaloneCore) {
    $runtimeDir = Join-Path $coreRoot "runtime"
    $runtimeHome = if ($env:DELEGATOR_RUNTIME_HOME) { $env:DELEGATOR_RUNTIME_HOME } else { Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime" }
    $coreHome = if ($env:DELEGATOR_CORE_HOME) { $env:DELEGATOR_CORE_HOME } else { Join-Path $env:LOCALAPPDATA "DelegatorWin\core" }
    $delegateCmd = Join-Path $runtimeDir "ai-delegate.cmd"
    $env:DELEGATOR_RUNTIME_DIR = $runtimeDir
    $env:DELEGATOR_RUNTIME_HOME = $runtimeHome
    $env:DELEGATOR_CORE_HOME = $coreHome
    $env:DELEGATOR_CORE_DELEGATE_CMD = $delegateCmd
    Start-Process -FilePath $standaloneCore -WorkingDirectory $coreRoot -WindowStyle Hidden
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-DelegatorCoreHealthy) { exit 0 }
    }
    throw "Standalone Delegator core did not become healthy: $healthUrl"
}

function Resolve-DelegatorPython {
    $candidates = @()
    if ($env:DELEGATOR_CORE_PYTHON) {
        $candidates += $env:DELEGATOR_CORE_PYTHON
    }
    $candidates += (Join-Path $coreRoot ".venv312\Scripts\python.exe")
    $candidates += (Join-Path $coreRoot ".venv\Scripts\python.exe")

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $probe = & $candidate -c "import fastapi, uvicorn, pydantic_core; print('ok')" 2>$null
        if ($LASTEXITCODE -eq 0 -and (($probe -join "`n") -match "ok")) {
            return $candidate
        }
    }

    $fallback = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($fallback) {
        $probe = & $fallback.Source -c "import fastapi, uvicorn, pydantic_core; print('ok')" 2>$null
        if ($LASTEXITCODE -eq 0 -and (($probe -join "`n") -match "ok")) {
            return $fallback.Source
        }
    }

    throw "Delegator core python runtime with FastAPI/Uvicorn/Pydantic was not found."
}

$pythonExe = Resolve-DelegatorPython

if (-not (Test-Path -LiteralPath $pythonExe)) {
    throw "Delegator core python runtime not found: $pythonExe"
}

if (-not (Test-Path -LiteralPath $serverScript)) {
    throw "Delegator core server script not found: $serverScript"
}

Start-Process -FilePath $pythonExe -ArgumentList "run_server.py" -WorkingDirectory $coreRoot -WindowStyle Hidden

for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Milliseconds 500
    if (Test-DelegatorCoreHealthy) {
        exit 0
    }
}

throw "Delegator core did not become healthy: $healthUrl"

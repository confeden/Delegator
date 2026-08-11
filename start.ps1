$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

$venvPython = Join-Path $root ".venv312\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $venvPython)) {
    $baseCandidates = @()
    if ($env:DELEGATOR_CORE_PYTHON) {
        $baseCandidates += $env:DELEGATOR_CORE_PYTHON
    }
    $baseCandidates += Join-Path $env:USERPROFILE ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    $systemPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($systemPython) {
        $baseCandidates += $systemPython.Source
    }

    $basePython = $baseCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1
    if (-not $basePython) {
        throw "Python 3.11+ was not found."
    }
    & $basePython -m venv (Join-Path $root ".venv312")
}

& $venvPython -m pip install -e .
& $venvPython -m delegator_core.main

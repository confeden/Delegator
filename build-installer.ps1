param(
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$projectRoot = $PSScriptRoot
$python = Join-Path $projectRoot ".venv312\Scripts\python.exe"
$pyinstaller = Join-Path $projectRoot ".venv312\Scripts\pyinstaller.exe"
$innoRoot = Join-Path $projectRoot "target\tools\innosetup-7.0.2"
$innoPackage = Join-Path $innoRoot "tools.innosetup.7.0.2.zip"
$innoPackageUri = "https://api.nuget.org/v3-flatcontainer/tools.innosetup/7.0.2/tools.innosetup.7.0.2.nupkg"
$innoPackageSha256 = "D8C26FB531AEF57848DF16BADD0B015BB3BABE12D3C2C4FCB7334E429928F7AE"
$isccCandidates = @(
    (Join-Path $innoRoot "tools\ISCC.exe"),
    "C:\Program Files (x86)\Inno Setup 7\ISCC.exe",
    "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
)

if (-not (Test-Path -LiteralPath $python)) {
    $bootstrapPython = Get-Command python.exe -ErrorAction SilentlyContinue
    if (-not $bootstrapPython) { throw "Python 3.12+ is required on the build machine." }
    & $bootstrapPython.Source -m venv (Join-Path $projectRoot ".venv312")
    if ($LASTEXITCODE -ne 0) { throw "Failed to create .venv312." }
}

& $python -m pip install --disable-pip-version-check -r (Join-Path $projectRoot "requirements-build.txt")
if ($LASTEXITCODE -eq 0) {
    & $python -m pip install --disable-pip-version-check --no-deps -e $projectRoot
}
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pyinstaller)) {
    throw "Failed to prepare the Python build environment."
}

$iscc = $isccCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $iscc) {
    New-Item -ItemType Directory -Force -Path $innoRoot | Out-Null
    if (-not (Test-Path -LiteralPath $innoPackage) -or
        (Get-FileHash -LiteralPath $innoPackage -Algorithm SHA256).Hash -ne $innoPackageSha256) {
        Invoke-WebRequest -UseBasicParsing -Uri $innoPackageUri -OutFile $innoPackage
    }
    $actualHash = (Get-FileHash -LiteralPath $innoPackage -Algorithm SHA256).Hash
    if ($actualHash -ne $innoPackageSha256) {
        throw "Tools.InnoSetup package checksum mismatch: $actualHash"
    }
    Expand-Archive -LiteralPath $innoPackage -DestinationPath $innoRoot -Force
    $iscc = Join-Path $innoRoot "tools\ISCC.exe"
}
if (-not (Test-Path -LiteralPath $iscc)) { throw "ISCC.exe was not found after bootstrap." }

$oldEncodedRustFlags = $env:CARGO_ENCODED_RUSTFLAGS
$pathRemaps = @(
    "--remap-path-prefix=$projectRoot=delegator-src",
    "--remap-path-prefix=$env:USERPROFILE=user-home"
)
$env:CARGO_ENCODED_RUSTFLAGS = $pathRemaps -join [char]0x1f

Push-Location $projectRoot
try {
    if (-not $SkipTests) {
        & cargo test
        if ($LASTEXITCODE -ne 0) { throw "Rust tests failed." }
    }
    & cargo build --release
    if ($LASTEXITCODE -ne 0) { throw "Rust release build failed." }

    $staticDir = Join-Path $projectRoot "delegator_core\static"
    & $pyinstaller --noconfirm --clean --onefile --noconsole --name delegator-core `
        --add-data "$staticDir;delegator_core\static" `
        --distpath "target\release" --workpath "target\pyinstaller\work" `
        --specpath "target\pyinstaller" "run_server.py"
    if ($LASTEXITCODE -ne 0) { throw "Delegator Core packaging failed." }

    & $iscc (Join-Path $projectRoot "installer\Delegator.iss")
    if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed." }
} finally {
    Pop-Location
    if ($null -eq $oldEncodedRustFlags) {
        Remove-Item Env:\CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue
    } else {
        $env:CARGO_ENCODED_RUSTFLAGS = $oldEncodedRustFlags
    }
}

Get-Item (Join-Path $projectRoot "dist\DelegatorSetup-0.4.2.exe")

param(
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"
$buildStartedUtc = [DateTime]::UtcNow
$projectRoot = $PSScriptRoot
$installerPath = Join-Path $projectRoot "dist\DelegatorSetup-0.9.0.exe"
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
# Every unit the cargo steps used, as Cargo's JSON messages name them. The prune at
# the end keeps these and what they were built against, and removes what older
# builds left behind.
$cargoMessages = @()

Push-Location $projectRoot
try {
    if (-not $SkipTests) {
        # No path remap for the tests: it only matters in the SHIPPED binary. While
        # it was set here too, this build and a plain `cargo test --locked` never
        # agreed on flags, so target\debug held two copies of every dependency (466
        # of 1200 units) and each command rebuilt what the other had just built.
        & cargo test
        if ($LASTEXITCODE -ne 0) { throw "Rust tests failed." }
        # Everything is fresh after the run above, so this compiles nothing.
        $cargoMessages += @(& cargo test --no-run --quiet --message-format=json)
        if ($LASTEXITCODE -ne 0) { throw "Listing the Rust test build failed." }
    }

    $env:CARGO_ENCODED_RUSTFLAGS = $pathRemaps -join [char]0x1f
    # stdout carries the JSON messages; progress and diagnostics still render on stderr.
    $cargoMessages += @(& cargo build --release --message-format=json-render-diagnostics)
    if ($LASTEXITCODE -ne 0) { throw "Rust release build failed." }

    $staticDir = Join-Path $projectRoot "delegator_core\static"
    # --noupx on purpose: PyInstaller silently uses UPX whenever it happens to be
    # on PATH, and one appeared here via winget between two releases. The payload
    # is identical either way (probed: PIL renders a PNG, sqlite runs), but the
    # artefact then shrinks by 5.5 MB and every byte of it is packed - which is a
    # textbook antivirus heuristic for an unsigned installer, and it makes the
    # build depend on what is installed on the machine rather than on this file.
    & $pyinstaller --noconfirm --clean --onefile --noconsole --noupx --name delegator-core `
        --add-data "$staticDir;delegator_core\static" `
        --distpath "target\release" --workpath "target\pyinstaller\work" `
        --specpath "target\pyinstaller" "run_server.py"
    if ($LASTEXITCODE -ne 0) { throw "Delegator Core packaging failed." }

    & $iscc (Join-Path $projectRoot "installer\Delegator.iss")
    if ($LASTEXITCODE -ne 0) { throw "Installer compilation failed." }
    # ISCC names the file after installer\Delegator.iss, this script after its own
    # line at the top (I5). When they disagree, what sits at $installerPath is an
    # older build's installer - and the prune below would bin the one just built.
    if (-not (Test-Path -LiteralPath $installerPath) -or
        (Get-Item -LiteralPath $installerPath).LastWriteTimeUtc -lt $buildStartedUtc) {
        throw "This build did not write $($installerPath) - the version in build-installer.ps1 and in installer\Delegator.iss disagree."
    }
} finally {
    Pop-Location
    if ($null -eq $oldEncodedRustFlags) {
        Remove-Item Env:\CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue
    } else {
        $env:CARGO_ENCODED_RUSTFLAGS = $oldEncodedRustFlags
    }
}

# Housekeeping after a finished build, never a step of it: whatever goes wrong
# here must not fail a build whose installer is already on disk.
try {
    & (Join-Path $projectRoot "scripts\prune-build-outputs.ps1") `
        -TargetDir (Join-Path $projectRoot "target") -CargoMessages $cargoMessages `
        -DistDir (Join-Path $projectRoot "dist") -KeepInstaller $installerPath -BuiltAfterUtc $buildStartedUtc
} catch {
    Write-Warning "Old build outputs were not pruned: $($_.Exception.Message)"
}

Get-Item -LiteralPath $installerPath

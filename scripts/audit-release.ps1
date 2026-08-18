param(
    [string]$InstallerPath
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path $PSScriptRoot -Parent
$excludedRoots = @(
    (Join-Path $projectRoot ".git"),
    (Join-Path $projectRoot "target"),
    (Join-Path $projectRoot "dist"),
    (Join-Path $projectRoot ".backup-pre-refactor"),
    # Agent worktrees: full checkouts of this same tree. Scanning them made the
    # audit report 1026 "source files" for a 100-file project and multiplied
    # every secret scan by ten.
    (Join-Path $projectRoot ".claude")
)
$sourceExtensions = @(".rs", ".py", ".ps1", ".cmd", ".iss", ".toml", ".json", ".md", ".txt", ".yml", ".yaml")

$sourceFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object {
    $path = $_.FullName
    $outsideExcludedRoots = -not ($excludedRoots | Where-Object { $path.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) })
    $outsideVirtualEnvs = $path -notmatch '[\\/]\.venv[^\\/]*[\\/]'
    $isSourceFile = ($sourceExtensions -contains $_.Extension.ToLowerInvariant()) -or
        ($_.Name -in @(".gitattributes", ".gitignore"))
    $outsideExcludedRoots -and $outsideVirtualEnvs -and $isSourceFile
}

$secretPatterns = @(
    ("AI" + "za[0-9A-Za-z_-]{30,}"),
    ("AQ" + "\.[0-9A-Za-z_-]{25,}"),
    ("sk" + "-or-v1-[0-9A-Za-z_-]{20,}"),
    ("sk" + "-[0-9A-Za-z_-]{24,}"),
    ("gh" + "p_[0-9A-Za-z]{30,}"),
    ("github" + "_pat_[0-9A-Za-z_]{30,}"),
    ("AK" + "IA[0-9A-Z]{16}"),
    ("-----BEGIN " + "(?:RSA |EC |OPENSSH )?PRIVATE KEY-----")
)

$findings = @()
foreach ($file in $sourceFiles) {
    foreach ($pattern in $secretPatterns) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches
        foreach ($match in $matches) {
            $findings += "$($file.FullName):$($match.LineNumber): potential credential"
        }
    }
}

$usersRootPattern = ('C:' + '\\Users\\')
$documentsRootPattern = ('[A-Z]:' + '\\Documents\\')
$personalPathPatterns = @(
    ($usersRootPattern + '(?!Default(?:\\|$)|Public(?:\\|$)|<[^>]+>)[^\\\r\n]+'),
    $documentsRootPattern
)
foreach ($file in $sourceFiles) {
    foreach ($pattern in $personalPathPatterns) {
        $matches = Select-String -LiteralPath $file.FullName -Pattern $pattern -AllMatches
        foreach ($match in $matches) {
            $findings += "$($file.FullName):$($match.LineNumber): personal absolute path"
        }
    }
}

$installerScript = Join-Path $projectRoot "installer\Delegator.iss"
$sourceLines = Select-String -LiteralPath $installerScript -Pattern '^Source:\s*"([^"]+)"'
if ($sourceLines.Count -eq 0) {
    $findings += "${installerScript}: installer has no explicit source manifest"
}
foreach ($line in $sourceLines) {
    $source = [string]$line.Matches[0].Groups[1].Value
    if ($source -match '^[A-Za-z]:\\|\*|\{user|%APPDATA%|%LOCALAPPDATA%|\.codex|\.gemini') {
        $findings += "${installerScript}:$($line.LineNumber): unsafe installer source '$source'"
    }
}

# Build outputs and virtualenvs must never be committed. The repository ships
# without a .gitignore by owner decision, so assert the actual risk (tracked
# files) rather than the presence of ignore rules.
$mustNotBeTracked = @("target", "dist", ".venv312", ".backup-pre-refactor")
foreach ($path in $mustNotBeTracked) {
    $tracked = & git -C $projectRoot ls-files -- $path 2>$null
    if ($LASTEXITCODE -eq 0 -and $tracked) {
        $findings += "build artifacts are tracked by git under '$path'"
    }
}

if ($findings.Count -gt 0) {
    $findings | ForEach-Object { Write-Output "AUDIT: $_" }
    throw "Release audit failed with $($findings.Count) finding(s)."
}

$artifactPaths = @()
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
    $resolvedInstaller = Resolve-Path -LiteralPath $InstallerPath -ErrorAction Stop
    $artifactPaths = @(
        (Join-Path $projectRoot "target\release\delegator.exe"),
        (Join-Path $projectRoot "target\release\delegator-core.exe"),
        $resolvedInstaller.Path
    )
}

$rg = Get-Command rg.exe -ErrorAction SilentlyContinue
if ($artifactPaths.Count -gt 0 -and -not $rg) {
    # Artifact scanning is a release gate: silently skipping it would let
    # build-machine paths or credentials ship inside the binaries.
    throw "rg.exe (ripgrep) is required to audit release artifacts but was not found on PATH."
}
if ($rg) {
    $markers = @($env:USERPROFILE, $projectRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($artifact in $artifactPaths | Where-Object { Test-Path -LiteralPath $_ }) {
        foreach ($marker in $markers) {
            & $rg.Source -a -F -l -- $marker $artifact | Out-Null
            if ($LASTEXITCODE -eq 0) {
                throw "Build-machine path found in artifact '$artifact'."
            }
        }
        foreach ($pattern in $secretPatterns) {
            & $rg.Source -a -l -- $pattern $artifact | Out-Null
            if ($LASTEXITCODE -eq 0) {
                throw "Potential credential pattern found in artifact '$artifact'."
            }
        }
    }
}

Write-Output "Release audit passed: $($sourceFiles.Count) source files, $($sourceLines.Count) explicit installer inputs."
if (-not [string]::IsNullOrWhiteSpace($InstallerPath)) {
    $hash = Get-FileHash -LiteralPath $InstallerPath -Algorithm SHA256
    Write-Output "Installer SHA-256: $($hash.Hash)"
}

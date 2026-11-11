<#
.SYNOPSIS
    Unit tests for the PowerShell runtime. Run under Windows PowerShell 5.1.

.DESCRIPTION
    Most of the product's logic lives in scripts\*.ps1 and until now nothing
    executed it in CI: the pipeline only PARSED the files (under pwsh 7, which
    accepts syntax 5.1 rejects) and checked their bytes. A pure function could be
    wrong in every case and the build stayed green.

    No Pester on purpose. The version that ships with Windows 10/11 is Pester
    3.4, its syntax is incompatible with Pester 5, and pinning a module turns a
    test run into a network install. Fifty lines of assertions have no such
    problem and run identically on a clean machine.

    ONE SCRIPT PER SUITE, each loaded into its own child scope. The three
    delegate scripts deliberately duplicate helper names (I14) - Get-TaskDomain,
    Write-DelegateUsageRecord and Get-ModelAttempts each exist in more than one
    file with DIFFERENT bodies. Dot-sourcing them into one scope would let the
    last definition win and every test would silently exercise the wrong copy,
    which is exactly the shape of G76.

    The runtime home is redirected to a temp directory first, so a test can never
    read the owner's live traffic or append to usage.jsonl - G74 calls that file
    the evidence the router learns from.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\ps\run-tests.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\ps\run-tests.ps1 -Filter verdict
#>
[CmdletBinding()]
param(
    # Substring of the suite name; runs everything when omitted.
    [string]$Filter
)

$ErrorActionPreference = "Stop"
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }

# Every tests\ps\*.tests.ps1 must appear here, naming the ONE script it loads.
# An unlisted file is an error, not a skip: a test nobody runs is worse than no
# test at all, because the row still reads "passed".
$Suites = @(
    @{ Tests = "improve-verdict.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "model-health.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "delegate-retry.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "caller-strength.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "ping-report.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "web-route.tests.ps1"; Script = "scripts\ai-delegate.ps1" }
    @{ Tests = "attempt-attribution.tests.ps1"; Script = "scripts\opencode-delegate.ps1" }
    @{ Tests = "custom-providers.tests.ps1"; Script = "scripts\opencode-delegate.ps1" }
    @{ Tests = "stream-availability.tests.ps1"; Script = "scripts\opencode-delegate.ps1" }
    @{ Tests = "build-outputs.tests.ps1"; Script = "scripts\prune-build-outputs.ps1" }
)

$script:Passed = 0
$script:Failed = 0
$script:Failures = @()
$script:CurrentSuite = ""

function Test-Case {
    <#
      One named case. A throwing body is a FAILURE, not a crash of the run:
      a test that dies must still let the remaining ones report.
    #>
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
    } catch {
        $script:Failed++
        $script:Failures += ("{0} :: {1}`n      {2}" -f $script:CurrentSuite, $Name, $_.Exception.Message)
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = "")
    $e = if ($null -eq $Expected) { "<null>" } else { [string]$Expected }
    $a = if ($null -eq $Actual) { "<null>" } else { [string]$Actual }
    if ($e -cne $a) {
        throw ("expected [{0}], got [{1}]{2}" -f $e, $a, $(if ($Because) { " - $Because" } else { "" }))
    }
}

function Assert-True {
    param($Condition, [string]$Because = "")
    if (-not $Condition) { throw ("expected true{0}" -f $(if ($Because) { " - $Because" } else { "" })) }
}

function Assert-False {
    param($Condition, [string]$Because = "")
    if ($Condition) { throw ("expected false{0}" -f $(if ($Because) { " - $Because" } else { "" })) }
}

function Assert-Null {
    param($Value, [string]$Because = "")
    if ($null -ne $Value) { throw ("expected null, got [{0}]{1}" -f $Value, $(if ($Because) { " - $Because" } else { "" })) }
}

function Assert-NotNull {
    param($Value, [string]$Because = "")
    if ($null -eq $Value) { throw ("expected a value{0}" -f $(if ($Because) { " - $Because" } else { "" })) }
}

function Assert-Match {
    param([string]$Pattern, [string]$Text, [string]$Because = "")
    if ([string]$Text -notmatch $Pattern) {
        throw ("expected [{0}] to match /{1}/{2}" -f $Text, $Pattern, $(if ($Because) { " - $Because" } else { "" }))
    }
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("delegator-pstests-" + [Guid]::NewGuid().ToString("n").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$env:DELEGATOR_RUNTIME_HOME = $sandbox
$env:DELEGATOR_EMIT_USAGE = "0"
# Redirecting the runtime home is NOT enough. Every copy of
# Write-DelegateUsageRecord ALSO appends to $env:DELEGATOR_USAGE_FILE whenever it
# is set (DEV_CONTRACTS §2.2), and that variable is inherited: run the suite from
# inside a delegation - which is exactly what an agent debugging Delegator does -
# and the test records land in a real request's ledger. The same goes for the
# request id, the client tag and the stage.
Remove-Item Env:\DELEGATOR_USAGE_FILE -ErrorAction SilentlyContinue
Remove-Item Env:\DELEGATOR_USAGE_STAGE -ErrorAction SilentlyContinue
$env:DELEGATOR_REQUEST_ID = "r-pstest0"
$env:DELEGATOR_CLIENT = "cli"

$script:RepoRoot = $repoRoot
$script:Sandbox = $sandbox

try {
    $onDisk = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "*.tests.ps1" | ForEach-Object { $_.Name })
    $listed = @($Suites | ForEach-Object { [string]$_.Tests })
    $unlisted = @($onDisk | Where-Object { $listed -notcontains $_ })
    if ($unlisted.Count -gt 0) {
        throw ("test file not listed in `$Suites (it would never run): " + ($unlisted -join ", "))
    }

    foreach ($suite in $Suites) {
        $testPath = Join-Path $PSScriptRoot ([string]$suite.Tests)
        $scriptPath = Join-Path $repoRoot ([string]$suite.Script)
        if (-not (Test-Path -LiteralPath $testPath)) { throw "missing test file: $testPath" }
        if (-not (Test-Path -LiteralPath $scriptPath)) { throw "missing script under test: $scriptPath" }

        $script:CurrentSuite = ([string]$suite.Tests) -replace "\.tests\.ps1$", ""
        if ($Filter -and $script:CurrentSuite -notlike "*$Filter*") { continue }
        if (-not $onWindows -and $script:CurrentSuite -eq "build-outputs") {
            Write-Host "  build-outputs: skipped (Windows build pruning tool)"
            continue
        }
        Write-Host ("  {0}  ({1})" -f $script:CurrentSuite, $suite.Script)

        # `& { ... }` is a CHILD scope: the dot-sourced script's functions live
        # and die there, so the next suite cannot inherit them.
        & {
            param($ScriptUnderTest, $TestFile)
            . $ScriptUnderTest
            . $TestFile
        } $scriptPath $testPath
    }
} finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
foreach ($failure in $script:Failures) { Write-Host ("FAIL  " + $failure) }
Write-Host ("{0} passed, {1} failed" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
exit 0

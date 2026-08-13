#requires -Version 5.1
<#
.SYNOPSIS
    Measures whether Delegator actually improves answers, with graders that never
    call a model.

.DESCRIPTION
    Four arms over the same cases (scripts\bench-cases.json):

      A  the weak IDE model alone   - one call to -WeakModel, the draft is FROZEN
                                      on disk and reused by every later run
      B  A's frozen draft + improve - what an IDE agent gets when it follows the hook
      C  delegate                   - the full auto-routed dispatcher path
      D  boost                      - advisors + judge (slow, off by default)

    Grading is mechanical: either the first ```python fence of the answer is
    executed against the case's asserts, or narrow regexes must / must not match.
    An LLM is never asked whether an answer is good.

    The decision rule for "did improve help" is McNemar over the A/B pair:
      b = A failed and B passed, c = A passed and B broke it.
      Ship when b >= 2c and b - c >= 4, and keep-precision >= 0.85.

.EXAMPLE
    .\scripts\bench-quality.ps1 -Arms A,B
    .\scripts\bench-quality.ps1 -Arms A,B,C -Only unique-ordered,chunk -Refresh
#>
param(
    [string[]]$Arms = @("A", "B"),
    [string[]]$Only = @(),
    [string]$WeakModel = "gemini-flash-lite-latest",
    [string]$CasesFile,
    [string]$OutDir,
    # Re-ask arm A instead of reusing the frozen drafts.
    [switch]$Refresh,
    [int]$TimeoutSec = 420
)

$ErrorActionPreference = "Stop"
# `powershell -File bench-quality.ps1 -Arms A,B` hands the array over as the
# single string "A,B" - split it back before anything asks -contains.
$Arms = @($Arms | ForEach-Object { ([string]$_).Split(",") } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ })
$Only = @($Only | ForEach-Object { ([string]$_).Split(",") } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$dispatcher = Join-Path $scriptRoot "ai-delegate.ps1"
if (-not $CasesFile) { $CasesFile = Join-Path $scriptRoot "bench-cases.json" }
if (-not $OutDir) {
    $base = if ($env:DELEGATOR_RUNTIME_HOME) { $env:DELEGATOR_RUNTIME_HOME } else { Join-Path $env:LOCALAPPDATA "DelegatorWin\runtime" }
    $OutDir = Join-Path $base "bench"
}
$draftDir = Join-Path $OutDir "drafts"
New-Item -ItemType Directory -Force -Path $draftDir | Out-Null

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Write-Text([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}
function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, $utf8NoBom)
}

# ── Runner ──────────────────────────────────────────────────────────────────
function Invoke-Dispatcher {
    # One dispatcher process. Returns stdout, exit code and wall clock. stderr is
    # dropped on purpose: only what an IDE agent would read counts.
    param([string[]]$Arguments)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dispatcher) + $Arguments
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $all -NoNewWindow -PassThru `
        -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    # Touching .Handle caches it; without this .ExitCode stays $null after a
    # timed WaitForExit and every run looks like a failure.
    $null = $proc.Handle
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        $sw.Stop()
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{ output = ""; exitCode = 124; ms = [int]$sw.ElapsedMilliseconds }
    }
    $sw.Stop()
    $out = if (Test-Path $outFile) { Read-Text $outFile } else { "" }
    Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ output = $out; exitCode = $proc.ExitCode; ms = [int]$sw.ElapsedMilliseconds }
}

function Remove-DelegatorMarkers {
    # Everything from the first ##DELEGATOR_ line on is machine framing, not answer.
    param([string]$Text)
    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    $keep = @()
    foreach ($line in $lines) {
        if ($line -match '^##DELEGATOR_') { break }
        $keep += $line
    }
    return (($keep -join "`n").Trim())
}

function Get-ImproveAnswer {
    # stdout of `improve` minus its header line.
    param([string]$Text)
    $body = ($Text -replace "`r`n", "`n")
    $lines = @($body -split "`n")
    $out = @()
    $started = $false
    foreach ($line in $lines) {
        if (-not $started) {
            if ($line -match '^##DELEGATOR_IMPROVE##') { $started = $true }
            continue
        }
        if ($line -match '^##DELEGATOR_') { break }
        $out += $line
    }
    return (($out -join "`n").Trim())
}

# ── Graders ─────────────────────────────────────────────────────────────────
function Get-PythonExecutable {
    $venv = Join-Path (Split-Path -Parent $scriptRoot) ".venv312\Scripts\python.exe"
    if (Test-Path -LiteralPath $venv) { return $venv }
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ""
}

function Get-FirstPythonBlock {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)```(?:python|py)?\s*\r?\n(.*?)```')
    if ($m.Success) { return $m.Groups[1].Value }
    # No fence: accept the raw text when it at least looks like a definition.
    if ($Text -match '(?m)^\s*def\s+\w+\s*\(') { return $Text }
    return ""
}

function Test-PythonCase {
    param([string]$Answer, [string]$Append, [string]$PythonExe)
    if ([string]::IsNullOrWhiteSpace($PythonExe)) { return @{ pass = $false; note = "no python" } }
    $code = Get-FirstPythonBlock $Answer
    if ([string]::IsNullOrWhiteSpace($code)) { return @{ pass = $false; note = "no code block" } }
    $file = Join-Path $env:TEMP ("dg-bench-" + [Guid]::NewGuid().ToString("n").Substring(0, 8) + ".py")
    Write-Text $file ($code + "`n`n" + $Append + "`n")
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $proc = Start-Process -FilePath $PythonExe -ArgumentList @($file) -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $proc.Handle
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch {}
            return @{ pass = $false; note = "python timeout" }
        }
        $stdout = (Read-Text $outFile).Trim()
        if ($proc.ExitCode -eq 0 -and $stdout -match "OK") { return @{ pass = $true; note = "" } }
        $stderr = (Read-Text $errFile).Trim()
        $tail = if ($stderr.Length -gt 160) { $stderr.Substring($stderr.Length - 160) } else { $stderr }
        return @{ pass = $false; note = ($tail -replace "\s+", " ") }
    } finally {
        Remove-Item $file, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-RegexCase {
    param([string]$Answer, $Case)
    foreach ($pattern in @($Case.mustContain)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Answer -notmatch $pattern) { return @{ pass = $false; note = "missing: $pattern" } }
    }
    foreach ($pattern in @($Case.mustNotContain)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($Answer -match $pattern) { return @{ pass = $false; note = "forbidden: $pattern" } }
    }
    return @{ pass = $true; note = "" }
}

function Get-FirstSqlBlock {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)```(?:sql|sqlite)?\s*\r?\n(.*?)```')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    if ($Text -match '(?is)\bselect\b.*\bfrom\b') { return $Text.Trim() }
    return ""
}

function Test-SqliteCase {
    # The model's SELECT is executed against the case's fixture with the stdlib
    # sqlite3 module and compared row by row to the expected result, which was
    # produced by a reference query - no judge, no fuzzy matching.
    param([string]$Answer, $Case, [string]$PythonExe)
    if ([string]::IsNullOrWhiteSpace($PythonExe)) { return @{ pass = $false; note = "no python" } }
    $sql = Get-FirstSqlBlock $Answer
    if ([string]::IsNullOrWhiteSpace($sql)) { return @{ pass = $false; note = "no sql block" } }
    $runner = @'
import json, sqlite3, sys
setup = open(sys.argv[1], encoding="utf-8").read()
query = open(sys.argv[2], encoding="utf-8").read()
expect = json.load(open(sys.argv[3], encoding="utf-8"))
con = sqlite3.connect(":memory:")
con.executescript(setup)
rows = [list(r) for r in con.execute(query)]
assert rows == expect, "got %r" % (rows,)
print("OK")
'@
    $stamp = [Guid]::NewGuid().ToString("n").Substring(0, 8)
    $runnerFile = Join-Path $env:TEMP "dg-bench-sql-$stamp.py"
    $setupFile = Join-Path $env:TEMP "dg-bench-setup-$stamp.sql"
    $queryFile = Join-Path $env:TEMP "dg-bench-query-$stamp.sql"
    $expectFile = Join-Path $env:TEMP "dg-bench-expect-$stamp.json"
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        Write-Text $runnerFile $runner
        Write-Text $setupFile ([string]$Case.setup)
        Write-Text $queryFile $sql
        # -InputObject, not the pipeline: piping an array of rows unrolls it and
        # the nested shape [[..],[..]] is lost, so every comparison failed while
        # printing the exactly-right rows.
        Write-Text $expectFile (ConvertTo-Json -InputObject @($Case.expect) -Depth 6 -Compress)
        $proc = Start-Process -FilePath $PythonExe -ArgumentList @($runnerFile, $setupFile, $queryFile, $expectFile) `
            -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $null = $proc.Handle
        if (-not $proc.WaitForExit(20000)) {
            try { $proc.Kill() } catch {}
            return @{ pass = $false; note = "sqlite timeout" }
        }
        if ($proc.ExitCode -eq 0 -and (Read-Text $outFile) -match "OK") { return @{ pass = $true; note = "" } }
        $stderr = (Read-Text $errFile).Trim()
        $tail = if ($stderr.Length -gt 160) { $stderr.Substring($stderr.Length - 160) } else { $stderr }
        return @{ pass = $false; note = ($tail -replace "\s+", " ") }
    } finally {
        Remove-Item $runnerFile, $setupFile, $queryFile, $expectFile, $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-Answer {
    param([string]$Answer, $Case, [string]$PythonExe)
    if ([string]::IsNullOrWhiteSpace($Answer)) { return @{ pass = $false; note = "empty answer" } }
    if ($Case.grader -eq "python") { return Test-PythonCase -Answer $Answer -Append ([string]$Case.append) -PythonExe $PythonExe }
    if ($Case.grader -eq "sqlite") { return Test-SqliteCase -Answer $Answer -Case $Case -PythonExe $PythonExe }
    return Test-RegexCase -Answer $Answer -Case $Case
}

# ── Run ─────────────────────────────────────────────────────────────────────
$cases = @((Get-Content -LiteralPath $CasesFile -Raw -Encoding UTF8 | ConvertFrom-Json).cases)
if ($Only.Count -gt 0) { $cases = @($cases | Where-Object { $Only -contains $_.id }) }
if ($cases.Count -eq 0) { throw "No cases selected." }
$pythonExe = Get-PythonExecutable
$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
Write-Host ("Cases: {0} | arms: {1} | weak model: {2}" -f $cases.Count, ($Arms -join ","), $WeakModel)
Write-Host ("Python grader: {0}" -f $(if ($pythonExe) { $pythonExe } else { "MISSING - python cases will fail" }))

$rows = @()
foreach ($case in $cases) {
    $taskFile = Join-Path $draftDir ("{0}.task.txt" -f $case.id)
    Write-Text $taskFile ([string]$case.task)
    $row = [ordered]@{ id = [string]$case.id; grader = [string]$case.grader }

    # ── A: the weak model alone (frozen) ──
    $draftFile = Join-Path $draftDir ("{0}.A.md" -f $case.id)
    if ($Refresh -or -not (Test-Path -LiteralPath $draftFile)) {
        $a = Invoke-Dispatcher @("ask", "-PromptFile", $taskFile, "-Model", $WeakModel, "-Backend", "gemini", "-NoPlanner", "-NoBoost")
        Write-Text $draftFile (Remove-DelegatorMarkers $a.output)
        $row.A_ms = $a.ms
    } else {
        $row.A_ms = 0
    }
    $draft = Read-Text $draftFile
    $gradeA = Test-Answer -Answer $draft -Case $case -PythonExe $pythonExe
    $row.A = [bool]$gradeA.pass
    $row.A_note = [string]$gradeA.note

    if ($Arms -contains "B") {
        $b = Invoke-Dispatcher @("improve", "-PromptFile", $taskFile, "-DraftFile", $draftFile)
        $row.B_ms = $b.ms
        $row.B_exit = $b.exitCode
        $answerB = if ($b.exitCode -eq 0) { Get-ImproveAnswer $b.output } else { $draft }
        if ([string]::IsNullOrWhiteSpace($answerB)) { $answerB = $draft }
        $row.B_changed = ($b.exitCode -eq 0)
        $gradeB = Test-Answer -Answer $answerB -Case $case -PythonExe $pythonExe
        $row.B = [bool]$gradeB.pass
        $row.B_note = [string]$gradeB.note
    }

    if ($Arms -contains "C") {
        $c = Invoke-Dispatcher @("delegate", "-PromptFile", $taskFile)
        $row.C_ms = $c.ms
        $gradeC = Test-Answer -Answer (Remove-DelegatorMarkers $c.output) -Case $case -PythonExe $pythonExe
        $row.C = [bool]$gradeC.pass
        $row.C_note = [string]$gradeC.note
    }

    if ($Arms -contains "D") {
        $d = Invoke-Dispatcher @("boost", "-PromptFile", $taskFile)
        $row.D_ms = $d.ms
        $gradeD = Test-Answer -Answer (Remove-DelegatorMarkers $d.output) -Case $case -PythonExe $pythonExe
        $row.D = [bool]$gradeD.pass
        $row.D_note = [string]$gradeD.note
    }

    $line = "{0,-16}" -f $case.id
    foreach ($arm in @("A", "B", "C", "D")) {
        if (-not ($Arms -contains $arm) -and $arm -ne "A") { continue }
        $value = $row["$arm"]
        if ($null -eq $value) { continue }
        $line += " {0}={1}" -f $arm, $(if ($value) { "pass" } else { "FAIL" })
    }
    Write-Host $line
    $rows += [pscustomobject]$row
}

# ── Report ──────────────────────────────────────────────────────────────────
function Get-Percentile {
    param([int[]]$Values, [double]$Fraction)
    $sorted = @($Values | Where-Object { $_ -gt 0 } | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $index = [int][Math]::Ceiling($Fraction * $sorted.Count) - 1
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $sorted.Count) { $index = $sorted.Count - 1 }
    return [int]$sorted[$index]
}

$summary = [ordered]@{ stamp = $stamp; cases = $rows.Count; weakModel = $WeakModel; arms = ($Arms -join ",") }
foreach ($arm in @("A", "B", "C", "D")) {
    $graded = @($rows | Where-Object { $null -ne $_."$arm" })
    if ($graded.Count -eq 0) { continue }
    $passed = @($graded | Where-Object { $_."$arm" }).Count
    $times = @($graded | ForEach-Object { [int]$_."${arm}_ms" })
    $summary["${arm}_pass"] = $passed
    $summary["${arm}_rate"] = [Math]::Round(100.0 * $passed / $graded.Count, 1)
    $summary["${arm}_p50ms"] = Get-Percentile -Values $times -Fraction 0.5
    $summary["${arm}_p95ms"] = Get-Percentile -Values $times -Fraction 0.95
}

if ($Arms -contains "B") {
    $paired = @($rows | Where-Object { $null -ne $_.B })
    $b = @($paired | Where-Object { -not $_.A -and $_.B }).Count       # improve rescued it
    $c = @($paired | Where-Object { $_.A -and -not $_.B }).Count       # improve broke it
    $keeps = @($paired | Where-Object { -not $_.B_changed })
    $keepOk = @($keeps | Where-Object { $_.A }).Count
    $summary.mcnemar_b = $b
    $summary.mcnemar_c = $c
    $summary.keeps = $keeps.Count
    $summary.keep_precision = if ($keeps.Count -gt 0) { [Math]::Round(1.0 * $keepOk / $keeps.Count, 2) } else { $null }
    $summary.verdict = if ($b -ge 2 * $c -and ($b - $c) -ge 4 -and ($keeps.Count -eq 0 -or $keepOk / [double]$keeps.Count -ge 0.85)) { "ship" } else { "not proven" }
}

$reportPath = Join-Path $OutDir ("bench-{0}.json" -f $stamp)
Write-Text $reportPath ((([pscustomobject]@{ summary = $summary; rows = $rows }) | ConvertTo-Json -Depth 6))

Write-Host ""
Write-Host "== Summary =="
foreach ($key in $summary.Keys) { Write-Host ("{0,-16} {1}" -f $key, $summary[$key]) }
Write-Host ""
Write-Host "Report: $reportPath"

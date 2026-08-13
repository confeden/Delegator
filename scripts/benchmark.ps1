#requires -Version 5.1
<#
.SYNOPSIS
    Agent-facing wrapper around the benchmark API of Delegator Core.

.DESCRIPTION
    The IDE agent runs `-benchmark` in its chat, reads runtime\BENCHMARK.md and
    drives this script. It only has to answer the tasks itself: the Delegator
    arm is produced HERE, by running the same task and the agent's own draft
    through `ai-delegate.ps1 improve`. That keeps the comparison honest (both
    arms see the identical task) and keeps the agent's job to three commands.

    start   - ask the core for 12 randomised tasks, write them next to each other
    answer  - submit YOUR answer for one task (the Delegator arm follows here)
    finish  - grade everything, print the verdict, write the report to the Desktop
    last    - print the report of the previous run

.EXAMPLE
    .\benchmark.ps1 start -Mode compare -Model "gemini-3.6-flash"
    .\benchmark.ps1 answer -RunId ab12cd34 -Task 1 -File C:\...\answer-01.md
    .\benchmark.ps1 finish -RunId ab12cd34
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "answer", "finish", "last")]
    [string]$Command = "start",

    [ValidateSet("compare", "solo")]
    [string]$Mode = "compare",

    [string]$Model = "",
    [string]$RunId = "",
    [int]$Task = 0,
    [string]$File = "",
    [int]$Seed = 0,
    [int]$TimeoutSec = 420,

    # Publish a run with answers missing. Those tasks score zero for the arm
    # that never answered, so this is for a run that cannot be completed.
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "delegator-common.ps1")
# Russian task text and verdicts travel through the console: without this the
# IDE agent reads them as question marks (PS 5.1 defaults to the OEM code page).
$Utf8NoBom = Initialize-DelegateEncoding

$CoreUrl = if ($env:DELEGATOR_CORE_URL) { $env:DELEGATOR_CORE_URL } else { "http://127.0.0.1:1380" }
$BenchHome = Join-Path $script:DelegateHome "benchmark"

function Read-Utf8([string]$Path) { return [System.IO.File]::ReadAllText($Path, $Utf8NoBom) }
function Write-Utf8([string]$Path, [string]$Text) { [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom) }

function Invoke-Core {
    # UTF8.GetBytes for the body (DEV_CONTRACTS section 4): PS 5.1 otherwise
    # sends Cyrillic task text and answers as question marks.
    #
    # An HTTP error is NOT the same as a dead core: 404 means the run is gone,
    # 409 means answers are still missing. Both carry a body worth showing, so
    # the status travels back instead of being flattened into one scary message.
    param([string]$Path, [hashtable]$Body, [string]$Method = "POST")
    $uri = "$CoreUrl$Path"
    try {
        if ($Method -eq "GET") {
            $response = Invoke-WebRequest -Uri $uri -Method GET -UseBasicParsing -TimeoutSec $TimeoutSec
        } else {
            $json = $Body | ConvertTo-Json -Depth 6 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $response = Invoke-WebRequest -Uri $uri -Method POST -UseBasicParsing -TimeoutSec $TimeoutSec `
                -ContentType "application/json; charset=utf-8" -Body $bytes
        }
    } catch {
        $status = 0
        $bodyText = ""
        $webResponse = $_.Exception.Response
        if ($webResponse) {
            try { $status = [int]$webResponse.StatusCode } catch {}
            try {
                $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $bodyText = $reader.ReadToEnd()
                $reader.Close()
            } catch {}
        }
        if ($status -gt 0) {
            $parsed = $null
            try { $parsed = $bodyText | ConvertFrom-Json } catch {}
            return [pscustomobject]@{ ok = $false; status = $status; data = $parsed; raw = $bodyText }
        }
        throw "Delegator Core не отвечает ($uri). Запустите Delegator и повторите. Подробности: $($_.Exception.Message)"
    }
    $text = [System.Text.Encoding]::UTF8.GetString($response.RawContentStream.ToArray())
    return [pscustomobject]@{ ok = $true; status = 200; data = ($text | ConvertFrom-Json); raw = $text }
}

function Get-CoreData {
    # Same call, but any HTTP error is fatal with a readable message.
    param([string]$Path, [hashtable]$Body, [string]$Method = "POST")
    $result = Invoke-Core -Path $Path -Body $Body -Method $Method
    if (-not $result.ok) {
        if ($result.status -eq 404) {
            throw "Прогон не найден: он уже завершён или Delegator перезапускался. Начните заново: benchmark.ps1 start"
        }
        throw "Delegator Core вернул ошибку HTTP $($result.status). $($result.raw)"
    }
    return $result.data
}

function Get-RunDir([string]$Id) { return (Join-Path $BenchHome $Id) }

function Send-Progress {
    # Tells the core what this run is doing, so the «Бенчмарк» tab shows movement
    # while a task is being processed. Never fatal: a benchmark must not fail
    # because a status ping did not land.
    param([string]$Id, [int]$TaskIndex, [string]$Stage)
    try {
        [void](Invoke-Core -Path "/api/benchmark/progress" -Body @{ runId = $Id; task = $TaskIndex; stage = $Stage })
    } catch {}
}

function Read-RunMeta([string]$Id) {
    $metaPath = Join-Path (Get-RunDir $Id) "run.json"
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "Прогон $Id не найден. Запустите: benchmark.ps1 start" }
    return (Read-Utf8 $metaPath | ConvertFrom-Json)
}

function Start-Run {
    $payload = @{ mode = $Mode; model = $Model }
    if ($Seed -gt 0) { $payload.seed = $Seed }
    $run = Get-CoreData -Path "/api/benchmark/start" -Body $payload

    $runDir = Get-RunDir $run.runId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $meta = [pscustomobject]@{
        runId = $run.runId; mode = $run.mode; seed = $run.seed
        benchmarkVersion = $run.benchmarkVersion; delegatorVersion = $run.delegatorVersion
        modelLabel = $run.modelLabel; dir = $runDir
    }
    Write-Utf8 (Join-Path $runDir "run.json") ($meta | ConvertTo-Json -Depth 5)

    Write-Output ("RUN {0}" -f $run.runId)
    Write-Output ("MODE {0}" -f $run.mode)
    Write-Output ("TASKS {0} (максимум {1} баллов, набор задач v{2})" -f $run.tasksPerRun, $run.maxPoints, $run.benchmarkVersion)
    Write-Output ("DIR {0}" -f $runDir)
    Write-Output ""
    foreach ($task in $run.tasks) {
        $taskPath = Join-Path $runDir ("task-{0:d2}.txt" -f $task.index)
        Write-Utf8 $taskPath ([string]$task.text)
        Write-Output ("{0:d2} [{1}] {2} -> {3}" -f $task.index, $task.level, $task.title, $taskPath)
    }
    Write-Output ""
    Send-Progress -Id $run.runId -TaskIndex 0 -Stage "waiting"
    Write-Output "Ответьте на каждую задачу сами, сохраните ответ в файл и вызовите:"
    Write-Output ("  benchmark.ps1 answer -RunId {0} -Task <N> -File <путь к вашему ответу>" -f $run.runId)
}

function Get-ImprovedAnswer {
    # Runs the Delegator arm for one task: the SAME task plus the agent's own
    # draft. Exit 0 means the answer was rewritten (its first line is the marker
    # ##DELEGATOR_IMPROVE##); anything else means "keep the draft".
    param([string]$TaskFile, [string]$DraftFile)
    $dispatcher = Join-Path $script:DelegateBinHome "ai-delegate.ps1"
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dispatcher,
            "improve", "-PromptFile", $TaskFile, "-DraftFile", $DraftFile)
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Caching the handle is required, or ExitCode stays $null after a timed wait.
        $null = $proc.Handle
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch {}
            return [pscustomobject]@{ text = (Read-Utf8 $DraftFile); changed = $false; ms = [int]$sw.ElapsedMilliseconds }
        }
        $stdout = if (Test-Path $outFile) { Read-Utf8 $outFile } else { "" }
        if ($proc.ExitCode -ne 0) {
            return [pscustomobject]@{ text = (Read-Utf8 $DraftFile); changed = $false; ms = [int]$sw.ElapsedMilliseconds }
        }
        # Strip the marker line and anything from the next ##DELEGATOR_ line on
        # (the usage marker is appended last when the core asks for it).
        $lines = @(($stdout -replace "`r`n", "`n") -split "`n")
        $body = @()
        $started = $false
        foreach ($line in $lines) {
            if (-not $started) {
                if ($line -match '^##DELEGATOR_IMPROVE##') { $started = $true }
                continue
            }
            if ($line -match '^##DELEGATOR_') { break }
            $body += $line
        }
        $text = ($body -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ text = (Read-Utf8 $DraftFile); changed = $false; ms = [int]$sw.ElapsedMilliseconds }
        }
        return [pscustomobject]@{ text = $text; changed = $true; ms = [int]$sw.ElapsedMilliseconds }
    } finally {
        Remove-Item $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Submit-Answer {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw "Нужен -RunId" }
    if ($Task -lt 1) { throw "Нужен -Task <номер задачи>" }
    if ([string]::IsNullOrWhiteSpace($File) -or -not (Test-Path -LiteralPath $File)) {
        throw "Нужен -File с вашим ответом на задачу $Task"
    }
    $meta = Read-RunMeta $RunId
    $runDir = [string]$meta.dir
    $answer = Read-Utf8 $File
    $ownCopy = Join-Path $runDir ("answer-{0:d2}-model.md" -f $Task)
    Write-Utf8 $ownCopy $answer
    [void](Get-CoreData -Path "/api/benchmark/answer" -Body @{ runId = $RunId; task = $Task; arm = "model"; answer = $answer })
    Write-Output ("Задача {0}: ваш ответ принят." -f $Task)

    if ($meta.mode -ne "compare") { return }

    $taskFile = Join-Path $runDir ("task-{0:d2}.txt" -f $Task)
    Send-Progress -Id $RunId -TaskIndex $Task -Stage "delegator"
    $improved = Get-ImprovedAnswer -TaskFile $taskFile -DraftFile $ownCopy
    $delegatorCopy = Join-Path $runDir ("answer-{0:d2}-delegator.md" -f $Task)
    Write-Utf8 $delegatorCopy $improved.text
    [void](Get-CoreData -Path "/api/benchmark/answer" -Body @{
        runId = $RunId; task = $Task; arm = "delegator"; answer = $improved.text; elapsedMs = $improved.ms
    })
    $state = if ($improved.changed) { "переписал ответ" } else { "оставил ваш ответ" }
    Write-Output ("Задача {0}: Delegator {1} ({2:N1} с)." -f $Task, $state, ($improved.ms / 1000))
    Send-Progress -Id $RunId -TaskIndex $Task -Stage "waiting"
}

function Complete-Run {
    if ([string]::IsNullOrWhiteSpace($RunId)) { throw "Нужен -RunId" }
    $result = Invoke-Core -Path "/api/benchmark/finish" -Body @{ runId = $RunId; force = [bool]$Force }
    if (-not $result.ok) {
        if ($result.status -eq 409) {
            # Publishing now would score the unanswered tasks as zero and blame
            # the arm that was never asked.
            Write-Output "Прогон ещё не готов: не все ответы отправлены."
            $missing = $result.data.detail.missing
            foreach ($arm in $missing.PSObject.Properties) {
                $who = if ($arm.Name -eq "model") { "ваши ответы" } else { "ответы Delegator" }
                Write-Output ("  нет: {0} для задач {1}" -f $who, ($arm.Value -join ", "))
            }
            Write-Output "Отправьте недостающие ответы (benchmark.ps1 answer ...) и повторите finish."
            Write-Output "Если ответить на них невозможно — benchmark.ps1 finish -RunId <id> -Force."
            exit 3
        }
        if ($result.status -eq 404) {
            throw "Прогон не найден: он уже завершён или Delegator перезапускался. Начните заново: benchmark.ps1 start"
        }
        throw "Delegator Core вернул ошибку HTTP $($result.status). $($result.raw)"
    }
    Show-Report $result.data
}

function Show-Last {
    $payload = Get-CoreData -Path "/api/benchmark/last" -Method "GET" -Body @{}
    if ($null -eq $payload.report) {
        Write-Output "Бенчмарк ещё не запускался."
        return
    }
    Show-Report $payload.report
}

function Format-Points {
    # Mirrors engine.format_points / gui::benchmark::format_points: 4.0 -> "4",
    # 2.25 -> "2.3". One report, three renderers, one spelling of every number.
    param($Value)
    if ($null -eq $Value) { return "0" }
    $number = [math]::Floor([math]::Abs([double]$Value) * 10 + 0.5) / 10
    if ([double]$Value -lt 0) { $number = -$number }
    if ([math]::Abs($number - [math]::Round($number)) -lt 1e-9) { return [string][int][math]::Round($number) }
    return $number.ToString("0.0", [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-ArmCell {
    # "2.3/3 (7/9)" - the points and the constraints they came from. A bare
    # number invites "so it failed"; the count says how much was actually right.
    param($Arm, $MaxPoints)
    if ($null -eq $Arm) { return "0/$MaxPoints" }
    $cell = "{0}/{1}" -f (Format-Points $Arm.points), $MaxPoints
    if ($Arm.checksTotal -gt 0) { $cell += " ({0}/{1})" -f $Arm.checksPassed, $Arm.checksTotal }
    return $cell
}

function Show-Report {
    param($Report)
    $compare = ($Report.mode -eq "compare")
    Write-Output ""
    Write-Output "=== Delegator: результаты бенчмарка ==="
    Write-Output ("Delegator v{0} · набор задач v{1} · seed {2}" -f $Report.delegatorVersion, $Report.benchmarkVersion, $Report.seed)
    Write-Output ("Модель IDE: {0}" -f $Report.modelLabel)
    Write-Output ""
    foreach ($row in $Report.tasks) {
        $line = "{0,2}. {1,-28} {2,-7} модель {3,-13}" -f $row.index, $row.title, $row.level, (Format-ArmCell $row.model $row.points)
        if ($compare) {
            $winner = switch ($row.winner) { "delegator" { "<= Delegator лучше" } "model" { "<= модель лучше" } default { "" } }
            $line += "  Delegator {0,-13}  {1}" -f (Format-ArmCell $row.delegator $row.points), $winner
        }
        Write-Output $line
    }
    Write-Output ""
    Write-Output ("Итого модель: {0} из {1}" -f (Format-Points $Report.totals.model), $Report.maxPoints)
    if ($compare) { Write-Output ("Итого с Delegator: {0} из {1}" -f (Format-Points $Report.totals.delegator), $Report.maxPoints) }
    # Per level and per capability: a single total never says WHERE the lag is.
    $groups = @()
    if ($Report.profile) {
        if ($Report.profile.byLevel) { $groups += $Report.profile.byLevel }
        if ($Report.profile.byCategory) { $groups += $Report.profile.byCategory }
    }
    if ($groups.Count -gt 0) {
        Write-Output ""
        Write-Output "Где сильнее и где слабее:"
        foreach ($group in $groups) {
            $line = "  {0,-10} {1,2} зад.  модель {2,-9}" -f $group.label, $group.tasks, ("{0}/{1}" -f (Format-Points $group.model), $group.maxPoints)
            if ($compare) { $line += "  Delegator {0,-9}" -f ("{0}/{1}" -f (Format-Points $group.delegator), $group.maxPoints) }
            Write-Output $line
        }
    }
    Write-Output ""
    Write-Output ([string]$Report.verdict)
    if ($Report.files) {
        Write-Output ""
        Write-Output "Отчёт сохранён на рабочий стол:"
        foreach ($property in $Report.files.PSObject.Properties) {
            Write-Output ("  {0}" -f $property.Value)
        }
    }
}

switch ($Command) {
    "start" { Start-Run }
    "answer" { Submit-Answer }
    "finish" { Complete-Run }
    "last" { Show-Last }
}

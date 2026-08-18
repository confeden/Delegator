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
    cancel  - drop a run you cannot finish, so the app stops waiting for it
    relabel - fix the model name of a run already in flight
    last    - print the report of the previous run

.EXAMPLE
    .\benchmark.ps1 start -Mode compare -Model "gpt-5.4-mini" -Reasoning "лёгкий"
    .\benchmark.ps1 answer -RunId ab12cd34 -Task 1 -File C:\...\answer-01.md
    .\benchmark.ps1 finish -RunId ab12cd34
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet("start", "answer", "finish", "cancel", "relabel", "last")]
    [string]$Command = "start",

    [ValidateSet("compare", "solo")]
    [string]$Mode = "compare",

    [string]$Model = "",

    # Reasoning / thinking level the IDE is set to ("минимальный", "low",
    # "extended"...). Free text on purpose: every vendor names it differently,
    # and a report that says only «gpt-5» cannot be compared with a later run of
    # the same family at a different level.
    [string]$Reasoning = "",

    [string]$RunId = "",
    [int]$Task = 0,
    [string]$File = "",
    [int]$Seed = 0,
    [int]$TimeoutSec = 420,

    # Publish a run with answers missing. Those tasks score zero for the arm
    # that never answered, so this is for a run that cannot be completed.
    [switch]$Force,

    # Skip the third arm (Delegator answering the task from scratch, with no
    # draft). It roughly doubles the wall-clock of a run, and it is the only
    # arm that measures the product's actual claim — so it is ON by default and
    # this switch exists for a quick smoke run, not for a real measurement.
    [switch]$NoAlone
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
    $payload = @{ mode = $Mode; model = $Model; reasoning = $Reasoning; force = [bool]$Force }
    if ($Seed -gt 0) { $payload.seed = $Seed }
    # 422 = the model was not named, 409 = another run is still being driven.
    # Both are protocol errors with a fix the agent can carry out, so they come
    # back as instructions instead of "the core is down".
    $started = Invoke-Core -Path "/api/benchmark/start" -Body $payload
    if (-not $started.ok) {
        if ($started.status -eq 422 -or $started.status -eq 409) {
            [Console]::Error.WriteLine([string]$started.data.detail.message)
            exit 4
        }
        throw "Delegator Core вернул ошибку HTTP $($started.status). $($started.raw)"
    }
    $run = $started.data

    $runDir = Get-RunDir $run.runId
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $meta = [pscustomobject]@{
        runId = $run.runId; mode = $run.mode; seed = $run.seed
        benchmarkVersion = $run.benchmarkVersion; delegatorVersion = $run.delegatorVersion
        modelLabel = $run.modelLabel; modelName = $run.modelName
        modelReasoning = $run.modelReasoning; dir = $runDir
    }
    Write-Utf8 (Join-Path $runDir "run.json") ($meta | ConvertTo-Json -Depth 5)

    Write-Output ("RUN {0}" -f $run.runId)
    Write-Output ("MODE {0}" -f $run.mode)
    # Printed back so a wrong label is caught NOW and not after ten minutes: the
    # report is worthless if it names the wrong model or the wrong thinking level.
    Write-Output ("МОДЕЛЬ В ОТЧЁТЕ: {0}" -f $run.modelLabel)
    if ([string]::IsNullOrWhiteSpace($Reasoning)) {
        Write-Output "  уровень рассуждений не указан — добавьте -Reasoning ""<уровень в вашей IDE>"""
    }
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

function Get-DelegatorAnswer {
    # Runs the Delegator arm for one task: the SAME task plus the agent's own
    # draft, through `assist` — so what is measured is THE PRODUCT (Delegator
    # deciding what to do), not one hard-coded mode.
    #
    # Until 0.6.0 this called `improve` directly, which made the arm
    # delegator = f(model draft): on a correct draft the only legal outcome is
    # "keep", so the measured effect was bounded above by zero for exactly the
    # strong models the product is for. Seven runs ended 28/28 vs 28/28, and on
    # 2026-08-16 eleven of twelve Delegator answers were byte-identical.
    #
    # Outcomes, all of which the report must be able to tell apart:
    #   exit 0 + ##DELEGATOR_IMPROVE## -> the corrected answer follows the marker
    #   exit 0, no marker              -> Delegator answered the task itself
    #   exit 3                         -> keep the draft (a real decision)
    #   anything else                  -> Delegator was UNAVAILABLE (not a tie)
    param([string]$TaskFile, [string]$DraftFile)
    $dispatcher = Join-Path $script:DelegateBinHome "ai-delegate.ps1"
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $dispatcher,
            "assist", "-PromptFile", $TaskFile)
        # No draft = the third arm: Delegator answers the task itself.
        if (-not [string]::IsNullOrWhiteSpace($DraftFile)) { $arguments += @("-DraftFile", $DraftFile) }
        $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        # Caching the handle is required, or ExitCode stays $null after a timed wait.
        $null = $proc.Handle
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch {}
            return [pscustomobject]@{ text = $(if ($DraftFile -and (Test-Path -LiteralPath $DraftFile)) { Read-Utf8 $DraftFile } else { "" }); changed = $false; mode = "timeout"
                                      unavailable = $true; ms = [int]$sw.ElapsedMilliseconds }
        }
        $stdout = if (Test-Path $outFile) { Read-Utf8 $outFile } else { "" }
        # `assist` reports its decision on stderr: «[Delegator] режим: improve (...)».
        # The report needs it, because "poровну" means one thing when Delegator
        # looked and found nothing and another when it never ran.
        $mode = ""
        if (Test-Path $errFile) {
            $stderrText = Read-Utf8 $errFile
            $match = [regex]::Match($stderrText, "режим:\s*([a-z]+)")
            if ($match.Success) { $mode = $match.Groups[1].Value }
        }
        if ($proc.ExitCode -eq 3) {
            # A real decision: Delegator looked and kept the draft.
            return [pscustomobject]@{ text = $(if ($DraftFile -and (Test-Path -LiteralPath $DraftFile)) { Read-Utf8 $DraftFile } else { "" }); changed = $false
                                      mode = $(if ($mode) { $mode } else { "keep" })
                                      unavailable = $false; ms = [int]$sw.ElapsedMilliseconds }
        }
        if ($proc.ExitCode -ne 0) {
            # Not a tie: Delegator could not run at all (quota, dead provider).
            return [pscustomobject]@{ text = $(if ($DraftFile -and (Test-Path -LiteralPath $DraftFile)) { Read-Utf8 $DraftFile } else { "" }); changed = $false
                                      mode = $(if ($mode) { $mode } else { "unavailable" })
                                      unavailable = $true; ms = [int]$sw.ElapsedMilliseconds }
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
        if (-not $started) {
            # No marker: Delegator answered the task itself (delegate / boost).
            $text = ($stdout -replace "`r`n", "`n").Trim()
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ text = $(if ($DraftFile -and (Test-Path -LiteralPath $DraftFile)) { Read-Utf8 $DraftFile } else { "" }); changed = $false
                                      mode = $(if ($mode) { $mode } else { "keep" })
                                      unavailable = $false; ms = [int]$sw.ElapsedMilliseconds }
        }
        return [pscustomobject]@{ text = $text; changed = $true
                                  mode = $(if ($mode) { $mode } else { "improve" })
                                  unavailable = $false; ms = [int]$sw.ElapsedMilliseconds }
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
    $accepted = Invoke-Core -Path "/api/benchmark/answer" -Body @{
        runId = $RunId; task = $Task; arm = "model"; answer = $answer; force = [bool]$Force
    }
    if (-not $accepted.ok) {
        if ($accepted.status -eq 422) {
            # Almost always the wrong file for this task number (seen live).
            [Console]::Error.WriteLine([string]$accepted.data.detail.message)
            [Console]::Error.WriteLine("Если ответ действительно без кода — повторите с -Force.")
            exit 5
        }
        if ($accepted.status -eq 404) {
            throw "Прогон не найден: он уже завершён или Delegator перезапускался. Начните заново: benchmark.ps1 start"
        }
        throw "Delegator Core вернул ошибку HTTP $($accepted.status). $($accepted.raw)"
    }
    Write-Output ("Задача {0}: ваш ответ принят." -f $Task)

    if ($meta.mode -ne "compare") { return }

    $taskFile = Join-Path $runDir ("task-{0:d2}.txt" -f $Task)
    Send-Progress -Id $RunId -TaskIndex $Task -Stage "delegator"
    $improved = Get-DelegatorAnswer -TaskFile $taskFile -DraftFile $ownCopy
    $delegatorCopy = Join-Path $runDir ("answer-{0:d2}-delegator.md" -f $Task)
    Write-Utf8 $delegatorCopy $improved.text
    [void](Get-CoreData -Path "/api/benchmark/answer" -Body @{
        runId = $RunId; task = $Task; arm = "delegator"; answer = $improved.text
        elapsedMs = $improved.ms; mode = [string]$improved.mode; force = $true
    })
    if (-not $NoAlone) {
        # THE THIRD ARM. `delegator` is Delegator reviewing YOUR answer, so on a
        # correct draft it can only keep it — the measured effect is bounded
        # above by zero, which is why seven runs in a row ended 28/28 vs 28/28.
        # This arm hands Delegator the task with NO draft: it is the only one
        # that exercises delegate/boost/custom providers, and the only one that
        # answers «а модели Delegator сами решают это лучше или хуже моей?».
        Send-Progress -Id $RunId -TaskIndex $Task -Stage "delegator"
        $alone = Get-DelegatorAnswer -TaskFile $taskFile -DraftFile ""
        if (-not $alone.unavailable -and -not [string]::IsNullOrWhiteSpace($alone.text)) {
            $aloneCopy = Join-Path $runDir ("answer-{0:d2}-alone.md" -f $Task)
            Write-Utf8 $aloneCopy $alone.text
            [void](Get-CoreData -Path "/api/benchmark/answer" -Body @{
                runId = $RunId; task = $Task; arm = "alone"; answer = $alone.text
                elapsedMs = $alone.ms; mode = [string]$alone.mode; force = $true
            })
            Write-Output ("Задача {0}: Delegator сам ответил через {1} ({2:N1} с)." -f $Task, $alone.mode, ($alone.ms / 1000))
        } else {
            Write-Output ("Задача {0}: Delegator сам ответить не смог — это плечо пропущено." -f $Task)
        }
    }

    $state = if ($improved.unavailable) { "не смог ответить (провайдер недоступен)" }
             elseif ($improved.changed) { "ответил сам ($($improved.mode))" }
             else { "оставил ваш ответ ($($improved.mode))" }
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

function Rename-Run {
    # Renames a run already in flight: the answers stay, only what the report
    # prints changes. This is the repair path for a run started without -Model.
    if ([string]::IsNullOrWhiteSpace($Model)) { throw "Нужен -Model с точным именем модели" }
    $payload = @{ model = $Model; reasoning = $Reasoning }
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { $payload.runId = $RunId }
    $result = Invoke-Core -Path "/api/benchmark/label" -Body $payload
    if (-not $result.ok) {
        if ($result.status -eq 422) { throw ([string]$result.data.detail.message) }
        if ($result.status -eq 404) { throw "Прогон не найден: начните заново (benchmark.ps1 start)" }
        throw "Delegator Core вернул ошибку HTTP $($result.status). $($result.raw)"
    }
    Write-Output ("Прогон {0}: модель в отчёте теперь «{1}»." -f $result.data.runId, $result.data.modelLabel)
}

function Stop-Run {
    # A run lives in the core's memory, and the app shows «Бенчмарк идёт» until
    # it is finished or dropped. When the agent cannot go on - a rate limit, an
    # overloaded backend, the user stopping the run - this is what ends it. The
    # core notices a silent chat by itself, but only after ten minutes.
    $payload = @{}
    if (-not [string]::IsNullOrWhiteSpace($RunId)) { $payload.runId = $RunId }
    $result = Invoke-Core -Path "/api/benchmark/cancel" -Body $payload
    if (-not $result.ok) {
        throw "Delegator Core вернул ошибку HTTP $($result.status). $($result.raw)"
    }
    if ($null -eq $result.data.cancelled) {
        Write-Output "Активных прогонов нет — прекращать нечего."
        return
    }
    Write-Output ("Прогон {0} прекращён: решено задач {1} из {2}. Отчёта по нему не будет." -f `
        $result.data.cancelled, $result.data.answeredModel, $result.data.tasksTotal)
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
    "cancel" { Stop-Run }
    "relabel" { Rename-Run }
    "last" { Show-Last }
}

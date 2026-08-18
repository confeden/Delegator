# Delegator benchmark — protocol for the IDE agent

## RUN THIS YOURSELF. DO NOT EXPLAIN IT TO THE USER.

**You execute every command below with your own shell tool, right now.** Do not
print them as instructions, do not ask the user to run anything, do not offer a
plan and wait for approval. The user typing `-benchmark` IS the approval.

This is not documentation. The whole point of the benchmark is to measure how
**you** answer the tasks — the user cannot answer them for you, so handing them
the commands does not start a run at all, it just ends the conversation with
nothing measured. Seen live 2026-08-13: an agent printed the three commands, the
user waited, and no run existed.

Report progress in one short line per task and print the final report in full.

Everything below runs in **PowerShell**. `<RUNTIME>` is the folder this file
sits in.

Purpose: measure how well **you** solve tasks on your own, and how well the same
tasks are solved when your answer goes through Delegator. You never grade
anything — the grader executes code and compares results mechanically.

Each task is graded against a LIST of named constraints, not as one pass/fail:
an answer that satisfies seven of nine scores seven ninths of the task's points.
So an answer that is nearly right is worth submitting — but a constraint the
task states and you skipped costs points, every time.

## Rules that keep the result honest

1. Answer every task **yourself first**, from your own knowledge, as if the user
   had asked it. Do not call Delegator, do not search, do not look at the other
   arm. The script produces the Delegator answer itself, from the draft you
   submit.
2. **One task at a time, in order, and never in parallel.** Each `answer` call
   also runs the Delegator side of that task and may take minutes; starting the
   next one before it returns, or calling `finish` early, publishes a report
   where unanswered tasks count as zero against the arm that was never asked.
   `finish` refuses such a run and tells you which tasks are still missing.
3. Never edit a task, never skip a task, never guess what the grader wants:
   solve exactly what is written.
4. Code answers must contain the solution in one ```python fence, SQL answers in
   one ```sql fence. Keep the function/class name exactly as the task states.
   **Before every `answer` call, re-read the task file you are answering and
   check that the file you are about to submit solves THAT task in THAT
   language.** A run on 2026-08-15 submitted the SQL task's answer under task 9
   and a Python function under the SQL task: both scored 0 for "no code of the
   required kind", and the report announced a 6-point Delegator win that was
   pure file mix-up. The grader cannot see your intent — it extracts the fence
   the task demands and runs it.
5. Do not tell the user an answer is correct — you do not know that. Only the
   final report decides.

## Steps

**1. Ask for the tasks** — run this command yourself. Use `compare` when Delegator is installed and working;
use `solo` when the user only wants their own model measured.

```
& "<RUNTIME>\benchmark.ps1" start -Mode compare -Model "<your exact model id>" -Reasoning "<your reasoning level>"
```

**Name yourself precisely — the report is worthless if it names the wrong
system, and the command REFUSES to start without it (exit 4).** `-Model` is the
exact id the user selected in the IDE, version and variant included
(`gpt-5.4-mini`, `gemini-3.7-flash`, `claude-opus-4-8`) — never the family
(`gpt-5`), never `unknown`, never a guess. `-Reasoning` is the thinking effort
the IDE is set to, in whatever words it uses (`лёгкий`, `minimal`, `high`).

**If you cannot read your own model id from your configuration, ask the user —
one line, then wait for the answer:** «Какая модель и какой уровень рассуждений
сейчас выбраны в вашей IDE? Нужны точные названия для отчёта.» They can see it
in the model picker; you may not be able to. Asking costs one message, a report
that says «неизвестная модель» is worth nothing and pollutes the statistics of
every later run.

Already started a run without a name? Fix it in place, do not throw the work
away:

```
& "<RUNTIME>\benchmark.ps1" relabel -RunId <id> -Model "<id>" -Reasoning "<level>"
```

**One run at a time.** `start` refuses (exit 4) while another run is still being
driven, and names it: either continue that one or `cancel` it. Two runs at once
made the app follow the wrong one and report «подготовка» while the chat was on
task 11.

The command prints `RUN <id>`, `МОДЕЛЬ В ОТЧЁТЕ: …`, a `DIR`, and 12 lines with a
task file each. Check that model line before answering anything.

**2. For every one of the 12 tasks:** read the task file, write your answer to a
new UTF-8 file (for example `<DIR>\my-01.md`), then submit it:

```
& "<RUNTIME>\benchmark.ps1" answer -RunId <id> -Task <N> -File "<DIR>\my-01.md"
```

In `compare` mode this one command also produces the Delegator answer for the
same task, so a single call per task is enough. It may take up to a few minutes
per task — that is normal, do not interrupt it.

**Exit 5 means the file you submitted is not what the task asked for** (a Python
function for an SQL task, or an answer with no code fence at all). That is a
mix-up, not a verdict: re-read `task-NN.txt`, submit the file that solves THAT
task. Only if the answer genuinely contains no code — because you could not
solve it — repeat the call with `-Force`.

**3. Finish and show the result.**

```
& "<RUNTIME>\benchmark.ps1" finish -RunId <id>
```

Print the whole output to the user unchanged. It contains the per-task scores
(`балл/максимум (пройдено проверок/всего)`), the score per level and per
category, both totals and the verdict, and the paths of the report files that
were written to the user's Desktop (`.txt` and `.png`). Then say, in one
sentence, that the `.png` can be shared as a normal picture in any chat, and
that the same result is visible in Delegator on the «Бенчмарк» tab.

The verdict may end with «этого мало: нужно минимум N расхождений». That is a
statement about the sample size, not about Delegator — pass it on as written and
do not soften it or spin it either way.

If a command fails because Delegator Core is not answering, tell the user to
start Delegator and run `-benchmark` again. Do not invent results, ever: a
benchmark that lies is worse than no benchmark.

**If YOU fail — an overloaded-servers error, a rate limit, anything that stops
you mid-run — say so to the user in plain words, end the run, and stop.** Do not
retry silently. A run you abandon keeps the app saying «Бенчмарк идёт» and keeps
waiting for a report that is never coming, so end it explicitly:

```
& "<RUNTIME>\benchmark.ps1" cancel -RunId <id>
```

Then tell the user which task you got to and why you stopped. Delegator also
notices a chat that has gone silent for ten minutes and offers to end the run on
the «Бенчмарк» tab, but the user should hear it from you first.

The same command ends a run the user asks you to stop. It is the ONLY way to
abandon a run: closing the chat, hitting stop, or starting over leaves the old
run in flight.

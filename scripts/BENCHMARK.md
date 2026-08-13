# Delegator benchmark — protocol for the IDE agent

The user typed `-benchmark`. Follow these steps exactly. Everything below runs in
**PowerShell**. `<RUNTIME>` is the folder this file sits in.

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
5. Do not tell the user an answer is correct — you do not know that. Only the
   final report decides.

## Steps

**1. Ask for the tasks.** Use `compare` when Delegator is installed and working;
use `solo` when the user only wants their own model measured.

```
& "<RUNTIME>\benchmark.ps1" start -Mode compare -Model "<the model you are running as>"
```

Put your real model name in `-Model` (for example `gemini-3.6-flash`) — it goes
into the report. The command prints `RUN <id>`, a `DIR`, and 12 lines with a task
file each.

**2. For every one of the 12 tasks:** read the task file, write your answer to a
new UTF-8 file (for example `<DIR>\my-01.md`), then submit it:

```
& "<RUNTIME>\benchmark.ps1" answer -RunId <id> -Task <N> -File "<DIR>\my-01.md"
```

In `compare` mode this one command also produces the Delegator answer for the
same task, so a single call per task is enough. It may take up to a few minutes
per task — that is normal, do not interrupt it.

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
you mid-run — say so to the user in plain words and stop.** Do not retry
silently and do not leave the run hanging: it holds the report until you either
finish it or it is cancelled. Delegator notices a chat that has gone silent for
ten minutes and offers to end the run on the «Бенчмарк» tab, but the user should
hear it from you first, with the task number you got to.

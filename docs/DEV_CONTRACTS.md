# DEV_CONTRACTS.md — internal cross-layer contracts (v1, 2026-08-10)

Developer doc (English). Defines the contracts between the Rust GUI, Python core, and
PowerShell runtime introduced by the 0.3.0 refactor. User-facing docs stay Russian.

## 1. Prompt transport (fixes: newline truncation, %VAR% expansion, cmd injection)

Problem: `ai-delegate.cmd %*` routes prompts through cmd.exe argv → truncated at first
newline, `%VAR%` expanded, metacharacters live. Therefore:

- Every PS entry script (`ai-delegate.ps1`, `ai-delegate-micro.ps1`, `ai-delegate-parallel.ps1`,
  `ai-delegate-plan.ps1`) accepts **`-PromptFile <absolute path>`** — UTF-8 text file containing
  the full prompt. Precedence: `-PromptFile` > stdin (existing `[Console]::In.ReadToEnd()` path) >
  positional prompt arg. The file is caller-owned (caller deletes it).
- The Python core NEVER goes through `ai-delegate.cmd` anymore. It derives the sibling
  `ai-delegate.ps1` from `DELEGATOR_CORE_DELEGATE_CMD` and invokes
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <runtime>\ai-delegate.ps1 <mode> -PromptFile <tmp> [-Model <m>]`.
  `/health` still reports the `.cmd` path (GUI identity check unchanged).
- `ai-delegate.cmd` stays as the IDE-facing entry point; the IDE hook text must tell agents:
  single-line prompts may go as an argument; multiline prompts / prompts containing `%`, `"`,
  `&` must be written to a temp file and passed via `-PromptFile` (or piped via stdin).
- Internal fan-out (boost advisors, parallel workers) must pass prompts via temp files
  (`-PromptFile`), never as nested `powershell.exe` argv (PS 5.1 strips embedded quotes).

## 2. Usage accounting

### 2.1 Global log — `<RT>\usage.jsonl`
`RT` = `%DELEGATOR_RUNTIME_HOME%` else `%LOCALAPPDATA%\DelegatorWin\runtime`.
Appended under named mutex `Global\DelegatorUsageLog`, one compact JSON per line:

```json
{"ts":"2026-08-10T12:34:56.789Z","requestId":"r-...","client":"core|ide|cli",
 "stage":"answer|triage|advisor|synthesis|verify|micro|plan|parallel",
 "mode":"ask|micro|verify|boost|parallel|plan","provider":"gemini|opencode-cli|openrouter|zen",
 "model":"...","promptTokens":123,"completionTokens":456,"totalTokens":579,
 "cost":0.0,"elapsedMs":1234,"ok":true,"accountId":"..."}
```

Token fields may be null when the provider did not report them. Written by
`gemini-delegate.ps1` / `opencode-delegate.ps1` on every completed provider call (success or
final failure), and by `ai-delegate.ps1` for stages it runs itself. Each script carries its own
copy of the writer helper (existing convention: provider scripts do not dot-source common).

### 2.2 Per-request env contract (set by the parent, read by children)
- `DELEGATOR_REQUEST_ID` — id shared by all stages of one invocation (generate `r-<8 hex>` if absent).
- `DELEGATOR_USAGE_FILE` — per-request JSONL path; children append the same records there
  (in addition to usage.jsonl) so the dispatcher can aggregate without re-reading the global log.
- `DELEGATOR_EMIT_USAGE=1` — makes `ai-delegate.ps1` print the final usage marker (2.3).
- `DELEGATOR_CLIENT` — `core` (set by Python), `ide` (set in hook text), default `cli`.

### 2.3 Stream marker (parsed by the Python core)
When `DELEGATOR_EMIT_USAGE=1`, the LAST line of `ai-delegate.ps1` stdout is:

```
##DELEGATOR_USAGE## {"requestId":"...","mode":"...","model":"<final answering model>","provider":"...","promptTokens":n,"completionTokens":n,"totalTokens":n,"cost":x,"elapsedMs":n,"ok":true,"stages":[{"stage":"...","model":"...","totalTokens":n}]}
```

Single line, compact JSON, summed across all stages of the request. The Python core strips any
line starting with `##DELEGATOR_USAGE##` from the user-visible answer.

### 2.4 Provider token extraction (must capture splits, not just totals)
- Gemini: `usageMetadata.promptTokenCount` / `candidatesTokenCount` / `totalTokenCount`.
- OpenCode CLI: SUM `part.tokens.{input,output,total}` and `part.cost` across ALL
  step_finish events (current code overwrites with the last event — wrong).
- OpenRouter / Zen direct: `usage.prompt_tokens` / `completion_tokens` / `total_tokens`, `usage.cost`|`cost`.

## 3. `GET /api/usage?days=N` (Python core; consumed by Rust GUI tab + SPA panel)

```json
{"days":7,
 "today":{"requests":12,"promptTokens":1000,"completionTokens":2000,"totalTokens":3000,
           "cost":0.0,"byProvider":{"gemini":{"requests":8,"totalTokens":2100}},
           "byClient":{"core":{"requests":4,"totalTokens":900}}},
 "daily":[{"date":"2026-08-10","requests":12,"totalTokens":3000,"cost":0.0}],
 "byModel":[{"model":"gemini-flash-latest","provider":"gemini","requests":9,
             "promptTokens":800,"completionTokens":1500,"totalTokens":2300,"cost":0.0}],
 "savedTokensTotal":123456}
```

`savedTokensTotal` = sum of `totalTokens` over the window — tokens the expensive IDE model did
not have to spend (delegated work). Source: `usage.jsonl` (covers IDE-invoked calls too) with
`stage=="answer"|"micro"|"verify"` counted in savedTokens; all stages counted in totals.
DB message rows are NOT the source (they only cover core-initiated chats).

## 4. HTTP body encoding (PS 5.1)

`Invoke-RestMethod -Body <string>` destroys non-ASCII (sends ISO-8859-1 `?`). ALL direct HTTP
provider calls must pass `-Body ([System.Text.Encoding]::UTF8.GetBytes($json))` and keep
`Content-Type: application/json; charset=utf-8`.

## 5. Error classes and cooldowns — `<RT>\cooldowns.json`

Classifier (per provider script) maps failures to: `rate_limit | auth | not_found | server |
timeout | content_policy | context_overflow | network | unknown`.

Policy: `auth`/`not_found` → cooldown 6h, no same-model retry; `rate_limit` → cooldown
(honor Retry-After; Gemini daily-quota → until next midnight America/Los_Angeles; else 120s)
and switch model immediately; `server`/`timeout`/`network` → one same-model retry with backoff
then switch; `content_policy` → switch model, cooldown 10min; `context_overflow` → switch to the
largest-context enabled model. A model exempt from cooldown when it is the only candidate.

```json
{"version":1,"models":{"<model>":{"until":"2026-08-10T13:00:00Z","reason":"rate_limit",
 "failCount":3,"lastStatus":429}}}
```

Mutex: `Global\DelegatorCooldowns`. Model selection (ranking walk, least-used selection,
account/model rotation) must skip models with active cooldowns.

## 6. File encoding of .ps1

Windows PowerShell 5.1 reads no-BOM files as ANSI → any Cyrillic literal breaks. ALL `.ps1`
must be UTF-8 **with BOM** (CI-checked). Prefer ASCII-only literals in .ps1 where practical.

## 7a. Outbound proxy — GUI-managed `proxies` list in config.json (+ legacy proxy.json)

All MODEL traffic (Gemini generateContent, OpenRouter/Zen chat completions, OpenCode CLI,
model-catalog refresh scripts) honors user-configurable proxies. The PRIMARY store is the GUI
config `%APPDATA%\Delegator\DelegatorWin\config\config.json` (config_version >= 8):

```json
"proxies": [
  {"id": "proxy-<nanos>", "label": "Прокси 1", "url": "http://192.168.0.148:8080",
   "enabled": true, "use_for_gemini": false, "use_for_opencode": true},
  {"id": "proxy-<nanos2>", "label": "Прокси 2", "url": "socks5://10.0.0.5:1080",
   "enabled": true, "use_for_gemini": true, "use_for_opencode": false}
]
```

Resolution per provider P ('gemini' | 'opencode'):
1. env `DELEGATOR_PROXY` — `off` → no proxy anywhere; any url → that url for ALL providers.
2. If config.json has the `proxies` key (even an empty list): first ENTRY in list order with
   `enabled=true`, non-empty `url`, and `use_for_<P>=true` wins. Empty/no-match → direct.
   The `proxies` key being present makes it authoritative — legacy file is NOT consulted.
3. Legacy fallback (only when `proxies` key is absent — pre-v8 config): `<RT>\proxy.json`
   `{"enabled":true,"url":...,"gemini":true,"opencode":true}` as before.

Different providers may thus use different proxies (e.g. proxy 1 for OpenCode, proxy 2 for
Gemini). Rationale for per-provider gating: a proxy egress IP may be geo-blocked by one provider
(Google rejects unsupported regions with FAILED_PRECONDITION) while fine for others.

v7→v8 migration: if `<RT>\proxy.json` exists, import it as the single entry «Прокси 1»
(enabled/url/gemini/opencode → use_for_*; missing flags default true); else `proxies: []`.
The legacy file is left on disk but ignored from then on.

- Supported schemes: `http://`, `https://` (native `Invoke-RestMethod -Proxy`) and
  `socks5://` / `socks5h://` (PS 5.1/.NET cannot SOCKS — those calls route through
  `curl.exe` from System32, which supports SOCKS natively).
- Env override: `DELEGATOR_PROXY=<url>` forces a proxy, `DELEGATOR_PROXY=off` disables even
  when proxy.json enables one. Precedence: env > proxy.json.
- OpenCode CLI child processes get `HTTP_PROXY`/`HTTPS_PROXY` (+`NO_PROXY=127.0.0.1,localhost`)
  set from the same setting.
- Loopback traffic (delegator-core on 127.0.0.1) NEVER goes through the proxy.
- Helper duplicated per script (no dot-source convention): `Get-DelegateProxy` returns the
  effective url or `$null`.

## 7. Supervisor contract (core restart)

Rust GUI sets `DELEGATOR_SUPERVISED=1` when spawning the core and watches the child: if it
exits, the GUI respawns it (with backoff). `POST /api/restart` under `DELEGATOR_SUPERVISED=1`
performs a clean process exit (the supervisor restarts it); without it (dev mode) it keeps the
legacy `os.execv` self-restart.

**The supervisor may not live in the egui update loop.** A hidden window receives no paint
messages on Windows, so `eframe` never calls `update()` while Delegator sits in the tray —
measured on 0.5.0 (2026-08-12): 0.000 s of CPU in 10 s, and a killed core was still gone 45 s
later. Supervision runs on its own thread, the release check as a tokio task, and the tray
«Включить/Отключить» item inside the tray callback (`src/gui/background.rs`). Shutdown order is
fixed: `background::request_stop()` → `wait_until_core_released()` → `taskkill`, otherwise the
supervisor respawns the core that shutdown just killed.

## 8. `improve` — reviewing the CALLER's own answer

    ai-delegate.ps1 improve -PromptFile <task> -DraftFile <the caller's answer>
                            [-ContextFile "a.rs;b.rs"] [-Json]

| exit | stdout | meaning |
|------|--------|---------|
| 0 | `##DELEGATOR_IMPROVE## {"verdict","defects","model"}` on the FIRST line, corrected answer after it | use the corrected answer |
| 3 | empty | keep your draft (verdict ok/minor, unparsable verdict, or a guard rejected the rewrite) |
| 2 | empty | bad input (no task, missing/empty draft) |
| 1 | empty | the backend failed; keep your draft |

Bad input must NOT go through `Write-Error`: `$ErrorActionPreference = "Stop"` makes it a
terminating error, so the exit code becomes 1 plus a stack trace. Use
`[Console]::Error.WriteLine` + `Exit-Delegate 2`.

The answer ends at the first line matching `^##DELEGATOR_`: with `DELEGATOR_EMIT_USAGE=1` the
usage marker of §2.3 is still appended as the last stdout line.

Cost: one model call when the draft passes, two when it does not. The reviewer is
`Get-StrongEnabledModel` (§9). `-Json` must never reach the two internal calls (the providers
would answer with their envelope and the verdict parser would read the envelope's braces);
`Run-Improve` clears it at script scope and keeps a copy for its own output.
A draft longer than `$script:ImproveDraftBudget` (24 000 chars) is kept unreviewed — rewriting a
truncated copy would delete the rest of the caller's answer. A `-ContextFile` path that does not
exist is reported on stderr, counted in `ctxmissing=N` and skipped, never fatal: the caller is a
weak model guessing paths, and a hard failure is indistinguishable from "your draft passed".
Guards (`Test-ImproveGuards`) reject a rewrite that is empty, shorter than 40 % of a
>400-character draft, dropped the draft's code fences, or reads as a refusal — damaging a correct
draft is worse than failing to fix a wrong one, so every doubt ends in KEEP. Outcomes go to
`<RT>\delegate-metrics.jsonl` as `stage=improve,
status=keep-*|improved-*|guard-*, extra=defects=N,calls=K,guard=…,ctxmissing=N`.

## 9. Model choice for user-facing answers

`model-rankings.json` does not ship, so `Select-RankedDelegateModel` returns `""` on a normal
install and the backend then answers with its own flash-class default — a weak IDE agent
delegating to an equally weak model. `Get-StrongEnabledModel` is the floor under that: the
**`enabled_opencode_models` list only** (Gemini ids never compete here — callers that need a
non-OpenCode answer fall back themselves, e.g. `improve` → `gemini-pro-latest`), sorted by
strength DESC and filtered by measured health. Strength comes from
`<RT>\opencode-zen-catalog.json`; when that file does not exist yet (cold install)
`Get-ModelStrengthScore` recomputes it from the id with the same heuristic — a flat default
would make the tie-break alphabetical.

Health comes from `<RT>\usage.jsonl` (last 400 records, per model the last 12): a model is
skipped when ≥4 samples show a failure rate ≥40 %, or when the p75 of its successful calls
exceeds the latency budget (100 s, `CODEX_DELEGATE_LATENCY_BUDGET_MS`). A model with no history
is always tried, so a fresh install still reaches for the best one and demotes it by itself.
If every candidate is unaffordable the least slow one wins — an answer beats a timeout.

Applied at: the `ask`/`delegate` strength floor (deep, verify or heavy domain), the fusion judge
and `verify` (`Get-OrchestratorModel`), the critic of the self-correction loop, and `improve`.
Plumbing (triage/extract/planner) keeps using the WEAKEST enabled model.

## 10. Benchmark (`-benchmark`, public)

Engine lives in `delegator_core/benchmark/` — inside the core on purpose: a user has no Python,
but the frozen core carries one. Candidate code never runs in the core process; it goes to a child
process, which is **this executable re-invoked with `--benchmark-exec <script> <result.json>`**
(`sandbox.py`, guarded in `run_server.py` BEFORE `main` is imported), with a 25 s timeout. The
child reports through a file, not stdout: the packaged core is windowed and its streams may not
exist.

`BENCHMARK_VERSION` (engine.py) versions the TASK SET and the scoring rules, independently of the
app version. Two reports are comparable only when it matches; bump it whenever a template or a
weight changes.

Run shape (1.4): **12 tasks — 2 fast (1 point), 4 normal (2), 6 deep (3), 28 points max**, drawn
from **46 templates (5 fast / 23 normal / 18 deep)**. **Levels are graded by measured difficulty,
not by how the task feels to write.** Runs #4 and #5 (`deepseek-v4-flash-free`) scored 4/4 and 8/8
on the fast and normal tiers, so eight of twelve slots of a ten-minute run measured nothing — hence
the 2/4/6 mix. Six deep templates observed at p = 1.0 (allocate-weights, next-business-day,
parse-csv-line, parse-query, round-half-up, semver-compare) were demoted the same day.
**When you move a template between groups in `TEMPLATES`, edit the level inside the template too**
— `Task.__post_init__` takes its points from the template's own level, and a mismatch silently
made a run worth 30 of a stated 28.

Templates are parameterised and drawn with a seeded RNG. `build_tasks(seed, difficulty=None)`:
`None` is the plain uniform draw (tests, reproducibility); ANY dict — **including an empty one** —
weights it. `generate_run` always passes `stats.difficulty_map(items.jsonl)`.
`weight = max(0.1, 1 − p)`. For a template with no measurement `p` comes from `CATEGORY_PRIOR`
(code/sql 0.9, spec/debug/performance 0.35), and ONE recorded observation replaces the prior
outright. The draw is without replacement: a run never asks the same template twice.

**Why a per-category prior and not one "unknown" bucket:** 1.4 treated every undrawn template
alike, so twelve unmeasured legacy tasks competed on equal terms with the five written to break a
model — run #6 gave the new classes one of six deep slots and came back 28/28. Measured after the
fix: new-class deep tasks per run went from 1.6 to 3.2. Five runs of ceilings are evidence about
the legacy classes; the prior states it instead of pretending we know nothing.

Grading is mechanical: a `python` task compares the candidate against a REFERENCE implementation on
generated inputs (so randomisation needs no answer keys), a `sqlite` task runs the candidate's
`sql` fence against a generated fixture and compares rows.

### Task classes (1.4) — why the old set stopped measuring

Five runs in a row produced only 0 % and 100 % answers, so partial credit had nothing to resolve
and every run was a tie. A modern model does not fail a short task that asks for one known
algorithm. Three classes were added because they still fail:

* **`spec`** — 9–11 interacting rules in one task (`validate-order`, `apply-discounts`), each rule
  its own named check. Models satisfy eight and drop the rest; the score lands between 0 and full,
  which is the only place a difference between the arms can appear.
* **`debug`** — buggy code plus the one input where it is wrong; fix it without breaking the rest
  (`fix-insert-point`, `fix-pagination`). Closest to what an IDE agent actually does, and the class
  where `improve` is handed a concrete failure instead of an abstract review.
* **`performance`** — a stated time budget on a generated input (`top-k-fast`). Catches "correct
  but quadratic", which single-case tests never see. **The perf check must be LAST** in the check
  list: checks run in order, and a candidate killed by the 25 s timeout keeps only what it recorded
  before. Tune `distinct`, not `size` — with 500 distinct values `items.count` in a loop finished
  in a second (it runs at C speed) and the task measured nothing; 18 000+ makes it bite.

**Authoring rule, learned by writing them:** run a hand-written CORRECT answer through the checker,
not only the bundled `solution`. `test_every_checker_accepts_its_own_reference_solution` cannot
catch a reference that contradicts its own prose — `top-k-fast` shipped for ten minutes with a
reference that returned a non-empty list for `k = -1` while the task text demanded an empty one, so
a correct answer would have been scored wrong.

### Partial credit per constraint (1.3)

A checker is a LIST of named checks — `templates.check(id, title, code=…, cases=…, weight=1)` —
and `grade_answer` returns a verdict per check. A task's score is
`level points × (earned weight / total weight)`, so points are FRACTIONAL and the report prints
`2.3/3 (7/9)`; `passed` stays all-or-nothing and is what the paired test uses. `MAX_POINTS` is
still 24 so two runs stay comparable. **Why:** binary grading is what made three live runs in a
row come back as twelve ties — a nine-constraint task scored 3 or 0 and threw the rest away.

`templates.default_checks` derives the list for free: a **weight-0 `contract` gate** (the entry
point exists — diagnostic, never worth points), one check per generated case, one for the `extra`
block. `_sql` grades a query on a ladder: weight-0 `runs`, then `shape` / `rows` / `order`, so
"right rows, wrong order" scores differently from "does not parse". A template with no generated
cases must name its checks by hand (`_t_lru_cache`), or it collapses back to all-or-nothing.

Gates are weight 0 **because partial credit must not pay for garbage**: with them scored, a
`def f(*a): return None` stub collected ~0.17 of every task. Measured after: max 0.29 over the
whole pool, mean 0.03, and `test_a_degenerate_answer_stays_near_zero` holds it under 0.35.

Each check runs in its own function inside one try/except, and the harness appends its result to
the file named by env `DELEGATOR_BENCH_CHECKS` **before moving on**. A candidate killed by the
25 s timeout therefore keeps the constraints it already satisfied — that is the difference between
"wrong" and "slow", and the only way a future performance-budget task can be graded at all.

Points are formatted half-up in THREE places (`engine.format_points`,
`gui::benchmark::format_points`, `Format-Points` in benchmark.ps1). Python's `round()` is
half-to-even and would print 2.25 as «2.2» where the GUI prints «2.3» for the same stored number.

Every template also carries a `solution` (a known-good answer; by default the reference with its
private name renamed to the entry point). `tests/test_benchmark.py` runs EVERY template through
its own checker with that solution and with a stub: a task nobody can pass, or one anybody can,
never ships. Growing the deep pool is the standing job — the first live run scored **24/24 with
Gemini 3.1 Pro**, which measures nothing. Deep tasks must therefore hinge on a rule that is
precisely specified and widely misremembered (cron's day-of-month OR day-of-week, `^0.0.3`
ranges, largest-remainder ties), not on knowing an algorithm.

### Capability profile and honest statistics

`report["profile"]` carries `byLevel` (fixed fast/normal/deep order) and `byCategory`, each row
`{key, label, tasks, maxPoints, model, delegator}` — the answer to "где отставание или
опережение", which no single total can give. Rendered by all four renderers (txt, svg, png, GUI);
the task table stays 12 rows, the profile is a separate short block.

`report["stats"]` (compare mode only, `None` in solo) is an **exact two-sided McNemar test** over
the tasks where exactly one arm fully passed: `{discordantDelegator, discordantModel, mcnemarP,
minDiscordantForProof, alpha, text}`. `math.comb`, no scipy. `minDiscordantForProof` is 6 — with
α = 0.05 no smaller sample can reach significance, whatever the result. Its `text` is appended to
the verdict, because **"не доказано" alone reads as a failure of Delegator when it is usually a
failure of the sample size**, and the report must say which.

### Item statistics (`items.jsonl`)

`finish_run` appends one line per graded (task, arm) to `<RT>\benchmark\items.jsonl` — template,
level, category, seed, model label, score, pass, failed check ids, elapsed. **An unanswered arm is
never recorded**: a missing answer is a protocol failure, not evidence that a task is hard.

`stats.summarise` reports per template: `pValue` (mean share of points earned), `fullPass`,
`discrimination` (corrected item-total correlation — does this item separate the runs that scored
high from those that scored low), `suggestedLevel`, and `advice` ∈ `keep` / `more-data` /
`retire` / `move-<level>` / `weak`. Thresholds: ≥ 0.9 → fast, ≥ 0.6 → normal, else deep; `retire`
needs p ≥ 0.98, ≥ 8 samples AND ≥ 2 distinct models (one model's strong suit is not evidence).
`GET /api/benchmark/items` serves it, together with `unseen` — the templates never drawn yet, so a
sample covering two thirds of the pool cannot read as covering all of it.

**Nothing here edits a template automatically.** Applying a suggestion changes the task set, which
means a `BENCHMARK_VERSION` bump; the numbers are evidence for that decision, never the decision.
This is how the hand-made 0.5.4 re-levelling stops being an opinion.

Endpoints (all local):

| method | path | purpose |
|--------|------|---------|
| POST | `/api/benchmark/start` | `{mode: compare\|solo, model, seed?}` → runId + 12 tasks |
| POST | `/api/benchmark/answer` | `{runId, task, arm: model\|delegator, answer, elapsedMs?}` |
| POST | `/api/benchmark/finish` | grades, stores, writes both report files, returns the report; **409 with the missing task numbers when answers are outstanding** (`force: true` overrides) |
| POST | `/api/benchmark/progress` | `{runId, task, stage}` — where the run is right now |
| GET | `/api/benchmark/status` | live state of the run in flight, `active: null` between runs |
| GET | `/api/benchmark/last` | last stored report (the GUI tab reads this) |
| GET | `/api/benchmark/items` | per-template difficulty, discrimination and level advice |
| POST | `/api/benchmark/export` | `{formats: [txt, png, svg]}` → paths written to the Desktop |

A run may only be published once every arm has answered every task. Seen live 2026-08-12: the agent
ran `answer` calls in parallel and called `finish` while two Delegator answers were still in flight;
the report scored those tasks 0 and announced that Delegator had lost them. `missing_answers()` +
the 409 make that impossible, and BENCHMARK.md now forbids parallel answers outright.

The IDE agent drives it via `runtime\benchmark.ps1` (start / answer / finish / last) following
`runtime\BENCHMARK.md`; the hook teaches the `-benchmark` trigger. **The agent submits only its own
answer** — `benchmark.ps1 answer` produces the Delegator arm itself by running the same task and
that draft through `improve` (§8). Two reasons: both arms provably see the identical task, and a
weak model cannot mis-drive the comparison.

Progress: `benchmark.ps1` pings `/api/benchmark/progress` before each slow step (`waiting` →
`delegator` → `waiting`), and `record_answer` stamps the state itself, so the tab keeps moving
even if a ping is lost. The GUI polls `/api/benchmark/status` every 1.5 s **only while the tab is
open**, and reloads the report automatically when a run disappears from `active` (that is how the
result appears without pressing «Обновить»). A ping never fails a run: `Send-Progress` swallows
its own errors.

Reports go to the real Desktop (`User Shell Folders\Desktop` via winreg, so a OneDrive-redirected
Desktop works) as `Benchmark_v<app version>_<YYYY.MM.DD>.txt|.png`; an existing file is never
overwritten (`_2`, `_3`, …).

**The picture is PNG, not SVG, and that is a product decision, not a preference:** Telegram treats
an `.svg` as a web document and warns the recipient that opening it may reveal their IP address —
unacceptable on a file whose whole purpose is being shared. `benchmark/image.py` draws it with
Pillow (the core's only extra dependency, pinned in requirements-build.txt) at 2× and downscales,
using the first available system TrueType face (Segoe UI → Tahoma → Arial → Verdana → DejaVu) so
Cyrillic renders. If Pillow or every font is missing, `export_report` falls back to the SVG and
reports why in `pngError` — a report is never lost over a picture. `render_svg` stays and is still
reachable with `{"formats": ["svg"]}` for anyone who wants vector.

## 11. Mechanical draft check (`improve`, §8)

`improve` used to decide "keep" or "rewrite" purely from what a reviewer model READ. Benchmark run
#4 (2026-08-13) showed what that misses: both arms submitted a SQL query with `ROW_NUMBER()` inside
`GROUP BY`, SQLite refuses to prepare it (`misuse of window function`), the reviewer read it, called
it correct, and Delegator returned the broken draft unchanged after 11 s. **No prompt fixes that —
a reviewer that only reads cannot run a compiler.**

`delegator_core/draft_check.py` is the part that does not read. It compiles every ```python fence
and prepares every ```sql fence, and it never executes anything: `compile()` stops before the first
statement, `EXPLAIN` before the query.

* **SQL needs a schema or it says nothing.** Without one SQLite stops at `no such table` long before
  it looks at the rest — which is exactly why a bare syntax check would have missed run #4.
  `schema_from_text` recovers it from a `CREATE TABLE` pasted into the prompt, else from the way
  people describe tables in prose (`logins(user_id INTEGER, day INTEGER)`) — the prose form only
  counts when the parentheses contain a recognisable SQL type, so a function signature is never
  mistaken for a table. `no such table/column/function` from our reconstructed schema is silence,
  never a defect.
* **No false positives, ever.** A defect that is not real turns a correct draft into a rewrite, and
  rewriting a correct answer is how `improve` does damage. Fragments (`...`, `# ...`), bare
  `return` at top level, stray indentation and unparsable-for-other-reasons blocks are all skipped.
* **Transport is a CLI, not an endpoint:** `delegator-core.exe --lint-draft <task> <draft> <result>`,
  guarded in `run_server.py` BEFORE `main` is imported (same reason as `--benchmark-exec`). IDE
  agents call `improve` whether or not the Delegator window is open, and a check that only works
  while the core happens to be listening is a check that is usually skipped.
* **In `ai-delegate.ps1`:** `Get-MechanicalDefects` (20 s cap, hidden window, temp files always
  removed) runs BEFORE the reviewer and its findings go into the check prompt as PROVEN DEFECTS.
  Afterwards they outrank the verdict: a mechanical defect forces `major`, so `ok`/`minor` can no
  longer end in "keep", and an unparsable verdict becomes `major` instead of "keep". No core, no
  Python, no answer in 20 s → no defects, and `improve` behaves exactly as before.

### 11a. A defect must be demonstrable (0.5.8)

The reviewer's JSON is now `{"verdict":…,"defects":[{"defect":"…","failingCase":"concrete input
and the wrong result"}],"confidence":…}` and `Get-SupportedDefects` DROPS any entry without a
`failingCase`. A bare string (older/sloppier answers) survives only when it names a case inline
(`например`, `input`, `->`, …). If nothing survives, the draft is kept.

**Why:** the 30-case internal bench measured `improve` rewriting 10 of 30 drafts of which 8 were
already correct — ~29 % verdict inflation, because asserting a defect costs the reviewer nothing.
Run #6 produced another instance (one unnecessary 72 s rewrite of a correct answer). Rewriting a
correct answer is the only way `improve` can do damage, so the bar is now "show me the input".
Mechanical defects (§11) bypass this entirely — they are already proven.

`delegate-metrics.jsonl` carries `unsupported=<n>` on the keep path: that is the tuning signal for
how often the reviewer claims something it cannot demonstrate.

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
 "stage":"answer|triage|advisor|synthesis|verify|review|micro|plan|parallel",
 "mode":"ask|micro|verify|boost|parallel|plan","provider":"gemini|opencode-cli|openrouter|zen",
 "model":"...","promptTokens":123,"completionTokens":456,"totalTokens":579,
 "cost":0.0,"elapsedMs":1234,"ok":true,"accountId":"...","bench":false,
 "errorClass":"timeout"}
```

**`bench` (0.7)** is true for every record written while a benchmark run is in flight, and the
core drops those records from EVERY figure it reports. A run delegates real work on
purpose: counting it inflates spend by the price of the measurement and "saved" by work nobody
asked for, so the counter would end up rewarding the act of benchmarking. The flag is carried by
`<RT>\benchmark-active.json`, written by `coding-bench/start.py` and removed by `bench.py finish` (only when no other run is unfinished: the other arm may be running in another chat). A flag older than
6 h is ignored — a dead agent must not switch accounting off forever. An environment variable
cannot do this job: the agent runs each arm through `ai-delegate.cmd` in a separate process.
Three copies of the check, one per usage writer. `router-decisions.jsonl` carries the same flag.

Token fields may be null when the provider did not report them. Written by
`gemini-delegate.ps1` / `opencode-delegate.ps1` on every completed provider call, and by
`ai-delegate.ps1` for stages it runs itself. Each script carries its own copy of the writer
helper (existing convention: provider scripts do not dot-source common).

**Every rung of the ladder, not only the last (0.7.2).** Both providers try several models before
giving up, and until 0.7.2 a run wrote exactly ONE record. A run that failed on A and B and
answered on C left no trace of A and B, so `Get-ModelHealth` (§9) never learned they were broken
and the router put A first again on the very next call — the feature that claims to pick models
by measured ability was reading evidence that was never written down. Now:

- opencode: one record per failed candidate, at the moment it fails.
- gemini: one record per ABANDONED MODEL, not per account attempt. Health is keyed on the model,
  and one record per account would weigh a model down once per configured key (G28).
- The old end-of-run record survives only for a run that reached no model at all; a set of
  already-recorded ids stops the `finally` path from counting the same call twice.
- A failure with exit code 2 writes NOTHING: the CLI is missing or unconfigured, so no provider
  call happened, nothing was spent, and attributing it would demote the whole pool at once
  (`Test-AttemptIsModelFailure`).

**`errorClass`** is present only on `ok:false` records and carries the §5 class. §9 reads it.

**`elapsedMs` is the duration of that CALL**, not of the run that contained it. Both providers
used to time from the start of the run, so a model that answered on the third rung wore the cost
of the two before it and its p75 latency looked far worse than it was.

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
 "savedTokensTotal":123456,"savedOutputTokens":123456,"handledTokens":400000,
 "spentTokensTotal":450000,"delegations":37,"benchmarkRecordsExcluded":0}
```

Source: `usage.jsonl` (covers IDE-invoked calls too); DB message rows are NOT the source, they
only cover core-initiated chats. **Every record with `bench:true` is dropped first** (§2.1).

- **`savedOutputTokens`** — the headline, and the only figure that claims to be a saving:
  `completionTokens` summed over SUCCESSFUL user-facing stages
  (`answer|micro|verify|plan|parallel|improve`). That is output the caller's own model did not
  have to generate. It still pays to read the answer back, but generation is the constrained
  resource, so the input half is deliberately not claimed.
- **`handledTokens`** — gross throughput moved off the main model, input context included. This
  is where a long `-ContextFile` shows up.
- **`spentTokensTotal`** — everything Delegator's own models burned, including internal stages
  (`triage|advisor|synthesis|extract|review`) and failed calls.
- **`delegations`** — distinct `requestId`s that produced user-facing output.
- **`savedTokensTotal`** — legacy key, equal to `savedOutputTokens` since 0.7. Before 0.7 it was
  gross `totalTokens`, i.e. Delegator's own SPEND presented as a SAVING.

**The 0.7 cut-off.** Config migration v11→v12 writes `<RT>\usage-counted-from.txt` (ISO-8601 UTC)
and this report ignores anything older; `days=N` may only be NARROWED by it, never widened. The
log is deliberately NOT moved or deleted, because `Get-ModelHealth` (§9) reads the same file to
learn which models are slow or failing. The first design renamed it aside and did both kinds of
damage: a racing double migration destroyed 180 KB of history outright, and the empty log left
every model looking untested, so the strength floor picked the highest-DPR id it could find and
spent 92 s timing out on it. Reset the COUNTER, never the EVIDENCE.

A failed call is `spent` and never `saved`. Internal stages are `spent` and never `saved` —
they replace no work the caller would otherwise have done.

**`review` (0.7.2) exists because of exactly that rule.** `improve`'s internal review call was
staged `verify`, which is BOTH a saved stage and the name of the user-facing `verify` command, so
every draft Delegator reviewed and then KEPT was booked as a saving for output the caller never
received. Only `improve`'s rewrite is user-facing; the review and the §8.1 re-ask are `review`.

Since 0.7.2 the ladder records each failed rung (§2.1), so `byModel[].requests` counts attempts
and a model that only ever fails now appears with requests and zero tokens. That is deliberate:
the row is the truth about what was tried. The headline figures are unaffected — `savedOutputTokens`
counts successful user-facing stages only, `spentTokensTotal` sums tokens (a failed rung reports
none), and `daily`/`today` requests are distinct `requestId`s, not records.

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

Cost: one model call when the draft passes, two when it does not, plus at most one re-ask (below).
The reviewer is `Get-StrongEnabledModel` (§9). `-Json` must never reach the internal calls (the
providers would answer with their envelope and the verdict parser would read the envelope's
braces); `Run-Improve` clears it at script scope and keeps a copy for its own output.
A draft longer than `$script:ImproveDraftBudget` (24 000 chars) is kept unreviewed — rewriting a
truncated copy would delete the rest of the caller's answer. A `-ContextFile` path that does not
exist is reported on stderr, counted in `ctxmissing=N` and skipped, never fatal: the caller is a
weak model guessing paths, and a hard failure is indistinguishable from "your draft passed".
Guards (`Test-ImproveGuards`) reject a rewrite that is empty, shorter than 40 % of a
>400-character draft, dropped the draft's code fences, or reads as a refusal — damaging a correct
draft is worse than failing to fix a wrong one, so every doubt ends in KEEP. Outcomes go to
`<RT>\delegate-metrics.jsonl` as `stage=improve,
status=keep-*|improved-*|guard-*, extra=defects=N,calls=K,reask=0|1,parse=json|salvaged,guard=…,ctxmissing=N`.

### 8.1 Reading the verdict (0.7.2)

`Get-ImproveVerdict` used to slice `IndexOf("{")` … `LastIndexOf("}")` and hand that to
`ConvertFrom-Json`. That is right only when the object is the whole answer, and it produced 32
`verdict-unparsable` outcomes in 228 measured runs (14 %) — each one a review that was paid for
and thrown away, returned to the caller as an exit 3 indistinguishable from "your draft passed".
Four steps replace it, cheapest first:

1. `Get-JsonObjectCandidates` walks the text and returns every BALANCED `{…}` region, ignoring
   braces and quotes inside JSON strings. It survives a closing sentence with braces, a schema
   example printed before the real verdict, and a defect that quotes a brace.
2. **If that returns nothing, the old whole-slice parse runs once as a fallback.** The scanner
   reads every `"` as a JSON delimiter and prose is not JSON, so ONE unpaired quote in the
   reviewer's preamble (`prints 5" without escaping`) leaves it inside a string for the rest of
   the text and it finds no region at all. The slice handled that shape, so dropping it would have
   been a regression, not an improvement — and the cost of the regression is silent: salvage keeps
   the verdict and throws every demonstrated defect away.
3. The candidate whose `verdict` is one of the four words wins; otherwise the first with a
   `verdict` key; otherwise the first that parses at all. `parseMode` is set to `json`.
4. If nothing parsed, the raw text is searched for the verdict FIELD
   (`"?\bverdict"?\s*[:=]\s*"?\s*(ok|minor|major|wrong)\b(?![|/])`) and a `salvaged` object is
   built with **no defects** — §11a says a defect must be demonstrable, and text we could not
   parse is not a demonstration. Two things it must NOT match: prose alone ("the draft is ok"),
   because reading a verdict out of prose is how a keep silently becomes a rewrite; and the SCHEMA
   this section's own check prompt prints, `"verdict":"ok|minor|major|wrong"` — that is what
   `(?![|/])` is for. A reviewer that echoes its instructions and is then cut off would otherwise
   salvage as a clean `ok` it never gave, and a usable verdict suppresses the re-ask below.

Only when all four fail does `Test-ShouldReaskVerdict` allow **one** extra call, and it is a
different, much smaller question: *restate the review you already gave as this schema*. The
reviewer's own reply goes back to it, capped at `$script:ImproveReaskBudget` (6 000 chars). The
re-ask DESCRIBES the three keys and never prints a complete example object: a model that echoes
its instructions would hand back a verdict we wrote ourselves, and step 3 would take it.
Bounded at one — a model that cannot emit JSON twice will not emit it on the third try, and
`improve` must not become an open loop against a free tier. Empty reviewer output never triggers
a re-ask: that is a backend failure, not a formatting failure. Both internal calls are staged
`review`, never `verify` (§3).

## 9. Model choice for user-facing answers

`model-rankings.json` does not ship, so `Select-RankedDelegateModel` returns `""` on a normal
install and the backend then answers with its own flash-class default — a weak IDE agent
delegating to an equally weak model. `Get-StrongEnabledModel` is the floor under that: the
**`enabled_opencode_models` list only** (Gemini ids never compete here — callers that need a
non-OpenCode answer fall back themselves, e.g. `improve` → `gemini-pro-latest`), sorted by
strength DESC and filtered by measured health.

### 9.1 DPR — the strength scale (0.7)

Strength is **DPR (Delegator Programming Rating)**, defined in the SHIPPED
`{app}\runtime\model-ratings.json`: `round(2 × Artificial Analysis Coding Index %)`, snapshot
2026-08-18, cross-checked against SWE-bench Verified. **0 means the model cannot program at
all** — speech, TTS, safety classifiers and embedding models are literal zeros and must never
be delegated code — and the scale has **no ceiling** (today's top is 156).

Lookup is the LONGEST substring of the lowercased id, so one row covers every route to the same
model (`agentrouter/claude-opus-5`, `aerolink/claude-opus-5`, `orcarouter/anthropic/claude-opus-4.6-fast`)
and `glm-5.2` wins over `glm-5`. An id with no row is **unrated**, which is NOT zero: it scores
`DelegateUnratedDpr` (100) and measured health decides from there. Zeroing an unknown model
would ban it; guessing high would hand it hard work nobody measured.

Tier floors: **deep ≥130, normal ≥100, fast below**. `<RT>\opencode-zen-catalog.json` still
carries the per-id numbers to the router and still wins where it has an entry — it is now
GENERATED from this table by `update-free-models.ps1`, so the file is a cache, not a second
opinion.

**The cache carries `ratingsVersion`, and a mismatch invalidates it whole** (PowerShell
`Read-ZenCatalog`, Rust `load_zen_strengths`). The catalog is only rewritten when it ages past
24 h, so without this an upgrade that changes the scores keeps routing on the old ones for a
full day — measured on the 0.7 upgrade itself, where a surviving pre-0.7 catalog still scored
`nemotron-3-ultra` 93 (top of the deep tier) hours after the table scoring it 99 had shipped.
A pre-0.7 catalog has no stamp at all, so it reads as 0 and is rejected, which is the intent.
**Bump `version` in model-ratings.json whenever any `dpr` changes**, or every cache built from
the old numbers stays valid.

Four copies of the reader, deliberately: `delegator-common.ps1`, `opencode-delegate.ps1`,
`update-free-models.ps1`, `src/gui/opencode_setup.rs` (which embeds the table with
`include_str!` so the GUI can order models before the runtime has written anything).

The alias-NAME heuristic this replaced is **gone, not kept as a fallback**. It did not merely
guess, it guessed backwards where it mattered: "ultra" was worth +40, so `nemotron-3-ultra`
scored 93/100 and led the deep tier, while the published index puts it at 49 — and that is the
model already on record for 175 s on a trivial question and 6 failures in its last 10 calls.
Re-snapshot the index; never hand-edit a row.

Health comes from `<RT>\usage.jsonl` (last 400 records, per model the last 12): a model is
skipped when ≥4 samples show a failure rate ≥40 %, or when the p75 of its successful calls
exceeds the latency budget (100 s, `CODEX_DELEGATE_LATENCY_BUDGET_MS`). A model with no history
is always tried, so a fresh install still reaches for the best one and demotes it by itself.

**Not every failure is a statement about the model** (`Test-ErrorClassIsQualitySignal`, 0.7.2).
The test is CORRELATION: a class every candidate in the ladder suffers identically is a fact about
the environment, the account or the prompt, and blaming models for it demotes the whole pool at
once. That was harmless while a run wrote ONE record; since §2.1 writes one per rung, a single
delegation made offline would mark every enabled model. These classes are dropped from the window
entirely — not counted as a failure, and not as a sample either:

| class | why it says nothing about the model |
|---|---|
| `rate_limit`, `auth` | time-bounded ACCOUNT states, already tracked WITH AN EXPIRY in `cooldowns.json` / `google-api-usage.json` (G29) |
| `network` | the machine or the proxy is down; every rung reports `unable to connect` and none of them was reached |
| `context_overflow` | a statement about the PROMPT — one oversized `-ContextFile` makes the whole pool look broken |

`server`, `timeout`, `not_found`, `content_policy` and `unknown` still count: they can be
correlated too, but they are also exactly the per-model failures N3 exists to catch, and their
cooldowns are short. Health has no expiry — a sample only leaves when twelve newer calls push it
out — so a demotion earned during a two-minute outage would outlive it by days, and nothing prints
health, so nobody would see the strength floor quietly invert into a weakness floor. A record with
NO `errorClass` counts as a failure: everything written before 0.7.2 lacks the field, and dropping
those would erase the router's memory on upgrade.
If every candidate is unaffordable the least slow one wins — an answer beats a timeout.

Applied at: the `ask`/`delegate` strength floor (deep, verify or heavy domain), the fusion judge
and `verify` (`Get-OrchestratorModel`), the critic of the self-correction loop, and `improve`.
Plumbing (triage/extract/planner) keeps using the WEAKEST enabled model.

## 10. Benchmark (`-benchmark`, public)

A coding benchmark (v1.7) that the IDE agent runs from its chat; the core is NOT involved. Package:
`coding-bench/` in the repo, installed to `<install>\runtime\coding-bench\` (`start.py`, `grade_run.py`, `template/`,
`hidden/`); runs and results are written to `<RT>\coding-bench\{runs,results}` (RT = the data dir, where the logs are); agent protocol: `scripts/BENCHMARK.md` -> `<RT>\BENCHMARK.md`.

Triggers (hook text in `ide_detector.rs`): `-benchmark` (also `/benchmark`) = **native** arm, the bare model, Delegator
must not be called; `-benchmark d` (also `-benchmark delegator`) = **delegator** arm, the same model told to use
`ai-delegate.cmd assist`. The arms are always separate chats (they may run at the same time) so they never share a
context. In a delegator run (flag `benchmark-active.json` fresh) `assist` sends EVERY call to the web chat first when the
Web checkbox is on and the extension is connected (`Run-Assist`, before the router - a strong caller would otherwise get
`keep`); when it is off / not connected / failed the ordinary ladder runs with its model fallbacks.

Flow: `python start.py --mode native|delegator "<model>"` copies `template/` into `runs/<mode>-<model>-<stamp>-<id>/`
(three tasks: routing 35, compress 35, sat 30; 15 min each; `bench.py begin|check|status|finish`);
`finish` publishes `REPORT.md` and runs `grade_run.py` (5-10 min, serialised by a lock file, timings depend on the
machine), which writes `results/<model-slug>/<arm>/<run>__v1.7__grade.json` + `.md` (`flags`, `work_minutes` optional for older files), rebuilds `SUMMARY_v1.5.md`, copies `results/<model-slug>` to
`Desktop\Delegator-benchmark\<model-slug>` (one folder, one subfolder per arm - carry it to another PC) and deletes the run folder (the archive lives in `runs_archive/`, outside the agent's reach by
convention only). The grading is mechanical (D11).

Grade JSON: `run`, `model`, `mode`, `bench_version`, `total` (0-100), `tasks.{routing,compress,sat}.{score,max,note,detail}`,
`minutes`, `self_confidence`, `calibration_error`, `delegation` (delegator mode only: `calls`, `ok`, `web_calls`,
`failed_attempts`, `requests_with_fallback`, `models`; read from `usage.jsonl` records stamped `bench:true` and
`delegate-metrics.jsonl` stage `web`, inside the run's wall-clock window - approximate, other Delegator traffic in
that window is counted), `graded_at`. The GUI tab «Бенчмарк» only reads these files.

The in-flight flag `<RT>enchmark-active.json` ({run, mode, model, started}) is written by `start.py`,
refreshed by `bench.py begin|check` and removed by `finish`; the 6 h staleness rule of the `bench` flag below
still holds. Reports of different benchmark versions are not comparable (I6). The installer ships a private CPython 3.12 (`scripts/build-pyembed.py` -> `<install>
untime\python\python.exe`, no `_pth` file,
~14 MB / +6.4 MB installer); tasks, `bench.py` and the graders run on it, with `PYTHONNOUSERSITE=1`.

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

### 11b. The REWRITE is checked too (0.5.11)

Benchmark run #8: `improve` took a **13/13 answer and returned a 2/13 one**. The rewrite used
`re.fullmatch` and put `import re` in a SECOND code block with a note to move it to the top. Two
holes met: nothing ever linted the rewrite (only the draft), and `compile()` cannot see a missing
import — an unbound name is a RUNTIME error.

- `undefined_names(code)` walks the AST and reports names that are loaded but bound nowhere.
  **`compile()` first, not just `ast.parse`**: the parser ACCEPTS a top-level `return`, so a
  snippet like «return value + 1» would otherwise be reported as using an undefined `value` — a
  false positive the module's own test caught. Module-wide, not scope-aware, and silent on
  `from x import *`: it must never blame correct code.
- `rewrite_defects(task, draft, rewrite)` returns reasons to THROW AWAY a rewrite: its first code
  block is not self-contained (names bound only in a later block), or it introduced a mechanical
  defect the draft did not have. `improve` then keeps the draft and records
  `guard-rewrite-broken`. Transport: the optional 5th path of
  `delegator-core.exe --lint-draft <task> <draft> <result> [rewrite]`.
- Answers are linted with ALL their Python joined, because an import in a second block does not
  make the code wrong — only badly presented. The "split" rule above is what judges presentation,
  and it applies to REWRITES only: `improve`'s output is fed back as *the* answer.

### 12. Provider failover and the universal free route

`Invoke-DelegateAcrossBackends` (ai-delegate.ps1) tries the chosen backend, then up to two models
on the other one, then `openrouter/openrouter/free`. Google meters each MODEL separately — measured
live, `gemini-pro-latest` returned 429 while the key was healthy and flash still had quota — so a
single-candidate fallback fails exactly when it is needed.

`openrouter/openrouter/free` (`config.rs UNIVERSAL_FREE_MODEL`, mirrored in ai-delegate.ps1) routes
to whatever free model OpenRouter has, so it answers when every metered model is out of quota.
Config migration **v9→v10** puts it in `enabled_opencode_models` — the runtime allowlist is
mandatory and refused it before ("Requested model … is not enabled in the Delegator GUI"), and the
Zen catalog sync never saw it because it only keeps ids matching `^opencode/…`. It is deliberately
NOT added to `known_opencode_models`: that list is the Zen catalog's memory and stays `opencode/*`
only (a test guards this), and `sync_opencode_catalog` never prunes `openrouter/*` anyway.
`openrouter/*` always goes to the **opencode** backend, whichever side the failover started from.

### 12a. User-added OpenAI-compatible providers (config v13)

A provider the user adds in the GUI is a row in `config.json` `custom_providers`:

    { "id": "bai", "label": "B.AI", "base_url": "https://api.b.ai/v1", "enabled": true,
      "accounts": [ { "id": "...", "label": "...", "api_key_enc": "<DPAPI>", "enabled": true } ],
      "enabled_models": ["hy3"], "known_models": ["hy3", "glm-5.3-flash"] }

**One namespace.** Its models are addressed `<provider id>/<model>` — the same shape as
`openrouter/*` — and every consumer splits on the FIRST slash, because a model id may itself
contain one (`tokenrouter/z-ai/glm-5.3-free` is one model of one provider). `is_valid_provider_id`
(config.rs) refuses `opencode`, `openrouter`, `gemini` and `google`: a provider holding one of those
prefixes would capture the built-in backends' ids in that split.

**Who owns what.** Google keeps `google_accounts` (its protocol is `generateContent`, not
OpenAI-compatible) and OpenRouter keeps `opencode_accounts` (the same key also authorises the
OpenCode CLI). Migration **v12→v13** therefore moves nothing: it adds a field and bumps the number.
Moving a live DPAPI blob is how a key gets lost (I19).

**Dispatch** (`opencode-delegate.ps1`): `Get-CustomProviderForModel` is consulted BEFORE
`Test-ModelAvailableInOpenCode`, or the CLI — which has never heard of the id — would claim it.
It resolves to `executionPath = openai-compat-direct`, `provider = <id>`, and one POST to
`<base_url>/chat/completions` through `Invoke-OpenAICompatModel`, which is also what
`Invoke-OpenRouterDirectModel` now calls. §4 (UTF-8 body), §7a (proxy precedence, SOCKS via
curl.exe), account rotation and the single 429 retry are that one function's, so a second provider
cannot drift away from them.

**Allowlist.** `enabled_models` is per provider and mandatory, exactly as `enabled_opencode_models`
is for Zen (I8). The pool merge happens AFTER the `enabled_opencode_models` intersection, because
that list is the Zen/OpenRouter allowlist and has never heard of these ids — intersecting would drop
every one. Tiering is by DPR, the same thresholds the Zen catalog uses. A provider with no enabled
key contributes NOTHING: an id in the pool that can only answer `401` costs a whole rung of a ladder.

**Verdicts — `<RT>\provider-verdicts.json`.** A listing is not an answer to "is
this free on MY key": b.ai lists 48 models, carries no `pricing` field, and four
of them answer on a deposit-free key. So the GUI asks, once per model, with a
`max_tokens: 8` request, and caches what came back:

    {"version":1,"providers":{"bai":{"hy3":{"verdict":"free","status":200,
      "reason":"","checked_at":1789,"expires_at":null}}}}

`classify_probe` (`provider_verdicts.rs`) owns the mapping: `200` → `free`,
`402`/`403` → `paid`, `400` NAMING money (insufficient / balance / quota /
credit) → `paid`, `404` → `absent`. Everything else — `401`, `429`, `5xx`, a
transport failure, a `400` about our own body — produces **no verdict**, because
each says something about the key, the quota or the wire and nothing about the
model. That arm is not a nicety: during the live check three working models
answered `429` under probing pressure, and a classifier that read that as "not
free" would have retired all three.

`free` never expires (ordinary traffic revisits it and a later refusal replaces
it); `paid`/`absent` expire after `NEGATIVE_VERDICT_TTL_SECS` (48 h), because a
plan changes and nobody announces it. Probes are capped at `MAX_PROBES_PER_RUN`
per provider per round, and cached per model rather than per run — a probe
spends the provider's quota and saves nothing (I11).

**A verdict may only REMOVE.** `Test-ModelRefusedByProvider` drops a
non-`free` model from the pool; nothing anywhere ticks a box, because I8 makes
the GUI selection the mandatory allowlist. A missing or unreadable verdict file
is an empty map, and an empty map removes nothing — the same asymmetry that
keeps a failed catalog load from emptying a provider.

**The daily round** (`PROVIDER_CATALOG_INTERVAL_SECS`, `config.provider_catalog_
refreshed_at`) is started by `spawn_provider_catalog_poller`, a tokio task that
re-reads config every 120 s, and by «Проверить модели». Never from the egui loop:
a hidden window gets no `update()`, so a round scheduled there ran only on restart
(G105). It is due when 24 h have passed since the last attempt AND some provider
is switched on with an enabled key (`CustomProvider::has_usable_key`); a round with
nothing to ask returns before it stamps, so without the second half a keyless
provider was due on every tick. The round stamps the ATTEMPT before any request,
like the `opencode upgrade` round, so an unreachable provider cannot fire a probe
round on every tick either.

The round runs for seconds while the GUI stays live, so it never saves the config
copy it read before the network: the stamp is saved and announced
(`CONFIG_GENERATION`) at once, and the discovered ids are written into a fresh
load at the end — the first round after a key is added runs exactly while the
user is ticking that provider's models. Discovered ids go
to `known_models` and **never** to `enabled_models`. Provider traffic from the
GUI rides the `opencode` proxy flag — the same one the runtime resolves — because
a catalog probed from one egress while delegation leaves from another describes a
route that does not exist.

**Ratings.** The table is matched by longest substring, so a new id can inherit a rating from a
shorter one it contains — `glm-5.3-flash` took the 150 of `glm-5.3` and landed in the deep tier.
A row with `"dpr": null, "confidence": "unrated"` is kept by `Get-DelegatorRatingRows` for exactly
this: the most specific match wins, and when it is unrated the answer is "no number"
(`DelegateUnratedDpr`), never a sibling's. Adding any row bumps `version` in `model-ratings.json`,
which invalidates every catalog stamped with the old one (I10, G75).

## 13. Caller-aware delegation (0.7.2)

Everything before this section assumed one kind of caller. It is not: an IDE agent running
`gemini-3.7-flash-low` and one running `claude-opus-5` want opposite things from the same command,
and until now both got the same pipeline.

**The rule, and everything below follows from it:** *return an answer at least as good as the
CALLER would have produced, at no token cost to the caller.*

### 13.1 The caller declares itself

    ai-delegate.ps1 assist -PromptFile <task> -CallerModel "gemini-3.7-flash-low"

`-CallerModel`, else `DELEGATOR_CALLER_MODEL`, else nothing. The id is whatever the caller's own
provider calls it, **including a reasoning-effort suffix**. The IDE hook text asks for it and tells
agents to omit it rather than guess. An undeclared caller routes exactly as it did in router 1.0 —
that is a hard requirement, not a nicety: most installed hook files predate this section.

### 13.2 Effort is not a rounding error

`model-ratings.json` carries ONE row per model, and the longest-substring lookup (§9.1) therefore
scores `gemini-3.7-flash-low` exactly like `gemini-3.7-flash`: **152, seventh of 196, above
`claude-opus-4-8`**. An agent at low effort is nothing like that number, and routing it as if it
were hands it the ECONOMY path when what it needs is amplification.

`Get-CallerEffortPenalty` subtracts DPR points for a trailing effort token — minimal 35, low 25,
medium 12, high/xhigh/max 0 — recognised only at the END of the id, so `low-latency-v2` is a model
name and `gpt-5.3-codex-high` is an effort level. Two rules about where this lives:

- **It is not in the table.** I10 forbids hand-editing rows; the published index has one figure per
  model, not one per effort level. This is a reviewable correction sitting on top of the snapshot.
- **It applies to the CALLER only.** The models Delegator answers with run at their own defaults.

An id with no row scores **0**, not `unrated_default`. Zero means "no comparison is possible"; 100
would be a mid score that reads as a weak caller and triggers amplification nobody asked for.

### 13.3 Three tiers, one number

`Get-CallerDpr` and `Get-BestAvailableDpr` (the DPR of the model `Get-StrongEnabledModel` would
actually pick, health included) go into the router as `callerDpr` / `bestDpr`. Router 1.1 turns the
gap into a tier — `CALLER_MARGIN` is 8, because the top twenty models of the shipped table sit
inside fifteen points, so eight is a tier and not a rounding difference.

| gap = best − caller | tier | what changes |
|---|---|---|
| ≥ +8 | `amplify` | `delegate` → `boost` on tasks ≥400 chars; `keep` → `improve` when a draft exists. We are clearly stronger, so the caller's tokens are not the scarce resource — its answer quality is. |
| −8 … +8 | `match` | nothing. We are level: answer once and do not spend three advisors proving it. |
| ≤ −8 | `guard` | `delegate`/`boost` → `keep`; `improve` keeps running but `modelReview=false`. |
| either number 0 | `unknown` | router 1.0 behaviour, exactly. |

The adjustment runs LAST, over a mode the textual rules already chose, and **never over a
confidence-1.0 guard**: empty task, truncated draft and oversized draft are about damage, and no
strength comparison may talk Delegator into reviewing half an answer. Tier-2 escalation is also
switched off in `guard` — a fast model knows nothing about who is calling, and letting it overrule
the quality guard would undo the one promise this section makes.

### 13.4 What `guard` actually does

Two refusals to spend, both deliberate:

- **No model review.** G34, measured: a reviewer weaker than the thing it reviews invents defects it
  cannot justify. §11 survives because it COMPILES the draft — those defects are facts.
- **No model rewrite either.** §11b would guarantee the rewrite clears the proven defect, but it
  guarantees nothing about the rest of the answer, and handing a 110-rated model an Opus draft to
  edit is the trade this mode exists to refuse. The proven defects go back on stderr and in the
  `-Json` envelope; the caller is the best rewriter in the room and now has facts it lacked.

Zero model calls either way — the honest form of "economy" when nothing we own earns its keep.
Returning those defects as DATA on stdout rather than as stderr prose needs P5.

### 13.5 Audit

`router-decisions.jsonl` carries `callerTier`, `callerDpr`, `bestDpr` and `modelReview` beside the
mode, and `delegate-metrics.jsonl` gets `caller=…;callerDpr=…;bestDpr=…` on the `route` record. A
tier without the two numbers that produced it is an assertion, not evidence — and the benchmark
grades the CHOICE by replaying it.

## 14. Web doors (0.9.38)

Signed-in chat tabs in the user's Chrome, driven by `extensions/gemini-web-bridge`. Table: `DOORS` in
`delegator_core/providers/web_doors.py`, in strength order: Gemini (D16), AI Studio, Z.ai, Qwen, DeepSeek, Kimi,
Tencent Hy, Rudder. A door is on through its `<id>_web_enabled` flag in config.json.

- `POST /api/web/ask {text, files?, model?, reasoning?, timeout_sec?, light?}` -> `{text, model, provider,
  door, seconds, errors}`, or 503 with the reasons. Doors within 8 DPR points of the strongest ready one are one tier and its fastest leads (`avg_seconds`).
  The leader runs alone for `hedge_delay_sec` (25 / 50 /
  90 s by prompt size), then the next door joins it, at most two at once; a failure hands over at once. The
  first good answer wins; only an answer from a clearly weaker door waits up to 15 s for a stronger one.
  The losers are cancelled. Attachments go to Gemini only. Gemini and AI Studio share `gemini_web_model` and
  `gemini_web_reasoning`, each with its own memory of spent models (`model_ladder`).
- `POST /api/web/panel {text, size?, reasoning?, timeout_sec?}` -> `{answers: [{text, model, door, seconds}]}`:
  the strongest doors at once, for `boost`.
- `GET /api/web/doors` -> `{connected, paused, seen_age, wanted, doors: [{id, label, url, enabled, strength,
  auth, auth_label, auth_at, resting_sec, rest_reason, last_error, last_seconds}]}`. `auth` is `unknown`,
  `checking`, `signed_in` or `signed_out`.
- `POST /api/web/login {door}` -> `{queued, url}`. `queued: false` = no extension called in lately, so the GUI
  opens `url` in the default browser itself.
- `POST /api/web/auth {door, state, label}`: the extension's report, from what the page shows. A site's
  sign-in button or sign-in path means `signed_out`; a composer without one means `signed_in`.
- Extension side: `GET /api/web-door/wait?known=a,b` (the ONE long poll for all doors, `&ack=` confirms the turns of the last reply and an unconfirmed
  turn goes out once more after 8 s, -> `{wanted, login, turns, extension_version}`; Chrome allows 6 connections per host, and a poll per door starved the last doors),
  `GET /api/web-door/{id}/live?id=` (false = stop this turn), `POST /api/web-door/{id}/phase {phase}`,
  `POST /api/web-door/{id}/result {request_id, text, error, used}`.
- A door's error text starts with its class: `LOGIN` -> `signed_out`, 30 min rest; `QUOTA` -> 3 h; `SLOW` -> 20 min;
  anything else -> 5 min. A success clears the rest. State persists in `<RT>\web-doors.json`.
- `POST /api/route`: the router in-process, same payload and result as `--route`. The exe stays for when the
  core is down.

Budgets: `assist` 540 s in total (the hook tells agents to allow 10 minutes), `improve` 240 s (past it the caller
keeps its draft), one web turn 300 s (benchmark 570 s, improve 180 s). Past the budget the ladder stops asking.

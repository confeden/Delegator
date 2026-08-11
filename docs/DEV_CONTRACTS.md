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

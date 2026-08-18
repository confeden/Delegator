"""Mode router: Delegator decides WHAT to do with a request, not the IDE agent.

Until 0.6.0 the mode was a verb the IDE agent typed after reading prose in the
hook text — so the product's central decision («review this answer» vs «answer
this outright» vs «convene several models») was made by the party least able to
make it, and made differently by every IDE. Measured consequences: an agent that
never calls `improve` at all, an agent that calls `boost` on a one-line
question, and 228 improve calls in the metrics log of which 109 came back
«nothing to fix» after a median of 15 s.

Design constraints this file exists under:

* **Deterministic first.** Tier 1 is pure functions over cheap textual features:
  no model, no network, no clock. It is the only tier that is allowed to be on
  the critical path of every request, and it must answer in single-digit
  milliseconds inside the frozen exe.
* **A model may only REFINE, never REPLACE.** When tier 1 is unsure it says so
  (`escalate`), and the caller may ask a fast model — but the tier-1 mode stays
  the fallback, so a dead provider degrades latency, never correctness.
* **Every decision is auditable.** The returned record is what gets written to
  `<RT>\\router-decisions.jsonl`, and the benchmark grades the CHOICE by
  replaying it, so a rule that looks clever and measures badly can be found.

Transport is `delegator-core.exe --route <request.json> <decision.json>`, the
same argv-guard trick as `--lint-draft`: agents call the runtime whether or not
the GUI is up, so the router cannot depend on the HTTP core being alive.
"""

from __future__ import annotations

import json
import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

ROUTER_VERSION = "1.0"

MODE_IMPROVE = "improve"
MODE_DELEGATE = "delegate"
MODE_BOOST = "boost"
MODE_KEEP = "keep"
MODES = (MODE_IMPROVE, MODE_DELEGATE, MODE_BOOST, MODE_KEEP)

# `improve` refuses a draft over this many characters (DEV_CONTRACTS §8): a
# truncated review is worse than none, so the router must not send one either.
IMPROVE_DRAFT_BUDGET = 24_000

# Below this a draft is a sentence, not an answer worth 15-30 s of review.
TRIVIAL_DRAFT_CHARS = 240

# A request this long is a specification, not a question.
LONG_TASK_CHARS = 4_000

# Boost costs three advisors plus a judge — minutes, not seconds. It is worth it
# only where a single model measurably struggles: long multi-constraint specs
# and open design questions.
BOOST_TASK_CHARS = 6_000

_FENCE = re.compile(r"```")
_CODE_HINT = re.compile(
    r"(?m)^\s*(def |class |import |from \w+ import|function |const |let |var |public |private |SELECT |WITH )",
    re.I,
)
_SQL_HINT = re.compile(r"\b(select|insert|update|delete|create table|join|group by)\b", re.I)
# An INSTRUCTION to produce code, as opposed to code pasted into the request.
# Measured on the 2026-08-16 run: 12 of 28 routing decisions fell through to
# "plain-question" with confidence 0.55 and complexity fast — every one of them
# a «Напиши функцию `chunk(items, size)`…» benchmark task. The older hints only
# matched code at the START of a line and English SQL keywords, so a task that
# DESCRIBES the work in prose read as small talk and went to the weakest tier.
_WRITE_CODE_HINT = re.compile(
    r"("
    r"напиши\s+(функци|класс|метод|скрипт|запрос|код|тест)"
    r"|реализуй|допиши|перепиши\s+(функци|класс|метод|код)|исправь\s+(функци|код|ошибк)|почини"
    r"|write\s+(a\s+)?(function|class|method|script|query|test)|implement\s|refactor"
    r"|fix\s+(the\s+)?(function|bug|code)"
    r"|верни\s+(список|кортеж|словарь|строк|числ)|возбуди\s+\w*error"
    r"|sql-запрос|sql\s+запрос"
    r"|`\w+\([^)]*\)`"
    r"|\bdef\s+\w+\s*\("
    r")",
    re.I,
)
_ERROR_HINT = re.compile(
    r"(traceback|exception|error:|panic:|stack trace|segfault|не работает|падает|ошибка)", re.I
)
# Questions where several perspectives genuinely disagree, i.e. where boost pays.
_DESIGN_HINT = re.compile(
    r"(архитектур|спроектир|design|architecture|trade-?off|подход|стратеги|migrat|refactor|"
    r"выбрать между|сравни|pros and cons)",
    re.I,
)
# Work that is bulk rather than judgement: exactly what offloading is for.
_BULK_HINT = re.compile(
    r"(переведи|translate|суммируй|summar|перепиши|rewrite|сгенерируй|generate|boilerplate|"
    r"напиши тесты|write tests|docstring|коммент)",
    re.I,
)


@dataclass
class Features:
    """Everything tier 1 is allowed to look at. Cheap, textual, no I/O."""

    task_chars: int = 0
    draft_chars: int = 0
    has_draft: bool = False
    draft_fences: int = 0
    draft_has_code: bool = False
    draft_truncated: bool = False
    task_has_code: bool = False
    task_has_sql: bool = False
    task_has_error: bool = False
    task_is_design: bool = False
    task_is_bulk: bool = False
    context_files: int = 0


@dataclass
class Decision:
    """What the caller executes, plus why — the audit record."""

    mode: str = MODE_DELEGATE
    reason: str = ""
    confidence: float = 0.0
    complexity: str = "normal"
    escalate: bool = False
    routerVersion: str = ROUTER_VERSION
    tier: str = "rules"
    features: dict = field(default_factory=dict)


def extract_features(task: str, draft: str = "", context_files: int = 0) -> Features:
    task = task or ""
    draft = draft or ""
    fences = len(_FENCE.findall(draft))
    return Features(
        task_chars=len(task),
        draft_chars=len(draft),
        has_draft=bool(draft.strip()),
        draft_fences=fences,
        draft_has_code=bool(_CODE_HINT.search(draft)) or fences >= 2,
        # An odd number of fences means the draft stops inside a code block:
        # the agent's own answer was cut off. Reviewing half an answer produces
        # a confident rewrite of the half that survived — silent corruption of
        # exactly the thing `improve` exists to protect.
        draft_truncated=fences % 2 == 1,
        task_has_code=bool(_CODE_HINT.search(task)) or bool(_WRITE_CODE_HINT.search(task)),
        task_has_sql=bool(_SQL_HINT.search(task)),
        task_has_error=bool(_ERROR_HINT.search(task)),
        task_is_design=bool(_DESIGN_HINT.search(task)),
        task_is_bulk=bool(_BULK_HINT.search(task)),
        context_files=max(0, int(context_files or 0)),
    )


def decide(task: str, draft: str = "", context_files: int = 0) -> Decision:
    """Tier 1. Pure, deterministic, ordered from "cannot be wrong" downwards.

    Confidence is not a probability, it is a licence to escalate: anything below
    0.6 means «a fast model may overrule this», and everything above means the
    rule stands on evidence recorded in ROADMAP.md or DEV_CONTRACTS.md.
    """
    f = extract_features(task, draft, context_files)
    payload = asdict(f)

    def decision(mode: str, reason: str, confidence: float, complexity: str = "normal") -> Decision:
        return Decision(
            mode=mode,
            reason=reason,
            confidence=confidence,
            complexity=complexity,
            escalate=confidence < 0.6,
            features=payload,
        )

    # ── Guards: cases where acting would do damage ──
    if not (task or "").strip():
        return decision(MODE_KEEP, "empty-task", 1.0, "fast")
    if f.has_draft and f.draft_truncated:
        return decision(MODE_KEEP, "draft-truncated", 1.0, "fast")
    if f.has_draft and f.draft_chars > IMPROVE_DRAFT_BUDGET:
        # §8 already refuses this; deciding it here keeps the reason honest
        # instead of surfacing as a mysterious non-zero exit.
        return decision(MODE_KEEP, "draft-too-long", 1.0, "deep")

    # ── With a draft: the question is «is this worth a second pass?» ──
    if f.has_draft:
        if f.draft_has_code or f.task_has_sql:
            # The one regime where a second pass provably pays: §11 executes the
            # code, so a defect is PROVEN rather than argued. The only benchmark
            # win Delegator ever earned honestly was of this shape.
            return decision(MODE_IMPROVE, "draft-carries-code", 0.9, "deep")
        if f.draft_chars < TRIVIAL_DRAFT_CHARS and not f.task_is_design:
            # 109 of 228 improve calls came back «nothing to fix» after a median
            # of 15 s. A two-line answer is where that waste lives.
            return decision(MODE_KEEP, "draft-trivial", 0.75, "fast")
        if f.task_is_design or f.task_chars >= LONG_TASK_CHARS:
            return decision(MODE_IMPROVE, "draft-on-hard-task", 0.7, "deep")
        return decision(MODE_IMPROVE, "draft-prose", 0.55, "normal")

    # ── No draft: the agent is asking Delegator to do the work ──
    if f.task_is_design and f.task_chars >= BOOST_TASK_CHARS:
        return decision(MODE_BOOST, "design-question-at-length", 0.7, "deep")
    if f.task_is_bulk:
        return decision(MODE_DELEGATE, "bulk-work", 0.85, "normal")
    if f.task_has_error or f.task_has_code or f.task_has_sql:
        return decision(MODE_DELEGATE, "code-task", 0.8, "deep" if f.task_chars >= LONG_TASK_CHARS else "normal")
    if f.task_chars >= LONG_TASK_CHARS or f.context_files:
        return decision(MODE_DELEGATE, "long-or-context-task", 0.7, "deep")
    return decision(MODE_DELEGATE, "plain-question", 0.55, "fast")


def route_files(request_path: str | Path, decision_path: str | Path) -> Decision:
    """The `--route` entry point: JSON in, JSON out, never raises.

    A router that can fail is a router the dispatcher has to guard, so every
    error path still writes a usable decision — `delegate` is the mode that was
    Delegator's whole job before the router existed.
    """
    try:
        # utf-8-sig, not utf-8: PowerShell 5.1 writes a BOM by default
        # (`Set-Content -Encoding UTF8`), and json.loads refuses one. The same
        # trap once made the app quarantine its own config.json.
        payload = json.loads(Path(request_path).read_text(encoding="utf-8-sig"))
        if not isinstance(payload, dict):
            raise ValueError("request must be an object")
        result = decide(
            str(payload.get("task") or ""),
            str(payload.get("draft") or ""),
            int(payload.get("contextFiles") or 0),
        )
    except (OSError, ValueError, TypeError) as error:
        result = Decision(
            mode=MODE_DELEGATE,
            reason="router-failed: %s" % type(error).__name__,
            confidence=0.0,
            escalate=False,
            tier="fallback",
        )
    try:
        Path(decision_path).write_text(
            json.dumps(asdict(result), ensure_ascii=False), encoding="utf-8"
        )
    except OSError:
        pass
    return result


def maybe_run_as_router(argv: list[str]) -> bool:
    """`delegator-core.exe --route <request.json> <decision.json>`.

    Returns True when this process was a routing call and must exit now. Kept
    beside `maybe_run_as_child` / `maybe_run_as_linter` so run_server.py has one
    shape for all three: check argv BEFORE importing the FastAPI app, or every
    routing call would boot a web server.
    """
    if len(argv) < 4 or argv[1] != "--route":
        return False
    route_files(argv[2], argv[3])
    return True

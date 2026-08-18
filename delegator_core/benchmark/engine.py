"""Run lifecycle, grading, scoring and reports for the public benchmark.

Flow: `generate_run` hands out 12 randomised tasks → the caller submits one
answer per task per arm (`record_answer`) → `finish_run` grades everything
mechanically and stores the result. Nothing here ever asks a model whether an
answer is good.
"""

from __future__ import annotations

import json
import math
import os
import re
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from .. import __version__ as APP_VERSION
from .sandbox import run_candidate
from .stats import difficulty_map, load_items, record_run
from .templates import LEVEL_POINTS, MAX_POINTS, TASKS_PER_RUN, Task, build_tasks

# Version of the TASK SET and the scoring rules. Reports may only be compared
# when this matches; bump it whenever a template or a weight changes.
# 2.1 — run #10 settled the escalation question: gemini-3.7-flash aced every
# task written to break it. Piling on rules buys nothing; the new `integration`
# class (work against an API the model was never trained on) is the direction
# that still produces failures.
# 2.0 — the owner's brief changed the target: Delegator is a reasoning
# amplifier first and a token saver second, so the set has to ask "does a second
# pass catch what the first missed" instead of "does the model know this".
# New classes `trap` (the obvious route is mechanically closed) and `exactness`;
# `spec`/`debug`/`performance` renamed to `contract`/`repair`/`budget`; the
# `topo-sort` REFERENCE was wrong for as long as it existed (DFS order instead
# of the alphabetically-smallest-available the task demands) and marked correct
# answers wrong. Nothing here is comparable with 1.6.
# 2.2 — the EXTRACTOR changed, so scores can differ: a fence that merely quotes
# the task's own material no longer counts as part of the answer. Found by
# adversarial review, measured on a workspace draft as a correct answer scoring
# 0.0 against a wrong one at 0.625.
BENCHMARK_VERSION = "2.2"

ARM_MODEL = "model"
ARM_DELEGATOR = "delegator"
# The third arm: Delegator answering the task from scratch, with no draft to
# review. It exists because the paired arms cannot measure the product's actual
# claim. `delegator` is improve(task, model draft), so on a correct draft the
# only legal outcome is "keep" — the measured effect is bounded above by
# (1 - model score), and live data agrees: 104 of 108 pairs score-identical,
# seven runs at 28/28. `alone` is the only arm that ever exercises delegate,
# boost, Get-StrongEnabledModel and the user's own providers, and it is not
# bounded in either direction: it answers «is Delegator's model better than
# mine on this class», which is the plug-in claim.
ARM_ALONE = "alone"
ARMS = (ARM_MODEL, ARM_DELEGATOR)
ALL_ARMS = (ARM_MODEL, ARM_DELEGATOR, ARM_ALONE)

MODE_COMPARE = "compare"
MODE_SOLO = "solo"

# The protocol keeps English level ids; a shared report must be readable.
LEVEL_LABELS = {"fast": "простая", "normal": "средняя", "deep": "сложная"}


def level_label(level: str) -> str:
    return LEVEL_LABELS.get(str(level), str(level))


_CODE_FENCE = re.compile(r"```(?:python|py)?\s*\r?\n(.*?)```", re.S)
_SQL_FENCE = re.compile(r"```(?:sql|sqlite)?\s*\r?\n(.*?)```", re.S)


@dataclass
class Answer:
    arm: str
    text: str
    elapsed_ms: int = 0
    # Which mode Delegator chose for this answer (improve / delegate / boost /
    # keep). Empty for the model arm and for any driver that does not report it.
    mode: str = ""


# What the run is doing right now, so the GUI can show progress instead of a
# frozen screen for the ten minutes a run takes.
STAGE_WAITING = "waiting"
STAGE_MODEL = "model-answer"
STAGE_DELEGATOR = "delegator"
STAGE_FINISHED = "finished"


@dataclass
class RunState:
    run_id: str
    seed: int
    mode: str
    model_label: str
    started_unix: int
    tasks: list[Task]
    answers: dict[str, dict[str, Answer]] = field(default_factory=dict)
    stage: str = STAGE_WAITING
    current_task: int = 0
    updated_unix: int = 0
    # How hard the model was told to think. Two runs of "the same" model at
    # different reasoning levels are two different systems, and a report that
    # names only the family («gpt-5») cannot be compared with anything later.
    reasoning: str = ""

    @property
    def display_label(self) -> str:
        """What every renderer prints: the model plus its reasoning level.

        Composed here, in ONE place, so the txt, the PNG, the SVG, the GUI, the
        verdict and items.jsonl all spell it identically — and so a level change
        counts as a different model in the item statistics, which is exactly
        what it is.
        """
        if not self.reasoning:
            return self.model_label
        return f"{self.model_label} · рассуждения: {self.reasoning}"

    def touch(self, task_index: int, stage: str) -> None:
        self.current_task = task_index
        self.stage = stage
        self.updated_unix = int(time.time())

    def answered(self, arm: str) -> int:
        return sum(1 for entry in self.answers.values() if arm in entry)

    def relabel(self, model_label: str, reasoning: str) -> None:
        """Fixes the name of a run already in flight. The answers are untouched;
        only the two strings the report prints change. Without this a run that
        started with a wrong or missing model name had to be thrown away after
        ten minutes of work."""
        self.model_label = (model_label or "").strip()[:80]
        self.reasoning = (reasoning or "").strip()[:40]


class BenchmarkStore:
    """In-flight runs plus the last finished report (one per machine)."""

    def __init__(self, home_dir: Path) -> None:
        self.home_dir = Path(home_dir)
        self.home_dir.mkdir(parents=True, exist_ok=True)
        self.last_path = self.home_dir / "benchmark-last.json"
        # Append-only history of every graded item, across runs and machines-
        # worth-of-time: the only way a level stops being an opinion.
        self.items_path = self.home_dir / "benchmark" / "items.jsonl"
        self._runs: dict[str, RunState] = {}

    def put(self, state: RunState) -> None:
        # Only one run matters at a time; drop anything older than an hour so a
        # forgotten run cannot pin memory forever.
        cutoff = int(time.time()) - 3600
        self._runs = {key: value for key, value in self._runs.items() if value.started_unix >= cutoff}
        self._runs[state.run_id] = state

    def get(self, run_id: str) -> RunState | None:
        return self._runs.get(run_id)

    def active(self) -> RunState | None:
        """The run somebody is actually DRIVING, or None.

        Ordered by last activity, not by start time: on 2026-08-16 a Copilot
        agent called `start` three times within minutes, drove the FIRST run to
        task 11 and left the others empty — and the GUI, which followed the
        newest start, showed «подготовка» for twelve minutes and then declared
        the run dead while the chat was working fine. Whoever last submitted an
        answer or a progress ping is the run that matters.
        """
        if not self._runs:
            return None
        return max(
            self._runs.values(),
            key=lambda state: (state.updated_unix or state.started_unix, state.started_unix),
        )

    def sweep(self) -> list[str]:
        """Forgets abandoned EMPTY runs and returns their ids.

        An agent that calls `start` twice leaves a zombie with no answers behind
        it; those zombies are what made the app follow the wrong run. A run that
        holds answers is never swept — that is somebody's work, and only an
        explicit `cancel` may drop it.
        """
        now = int(time.time())
        dead = [
            state.run_id
            for state in self._runs.values()
            if not state.answers
            and now - (state.updated_unix or state.started_unix) >= STALE_AFTER_SEC
        ]
        for run_id in dead:
            self._runs.pop(run_id, None)
        return dead

    def busy(self, ignore_run_id: str = "") -> RunState | None:
        """A run that is still being driven right now (touched within the stale
        window), if any. `start` refuses while one exists: two runs at once make
        the GUI, the answers and the report disagree about which is real."""
        for state in self._runs.values():
            if state.run_id == ignore_run_id:
                continue
            idle = int(time.time()) - (state.updated_unix or state.started_unix)
            if idle < STALE_AFTER_SEC:
                return state
        return None

    def drop(self, run_id: str) -> None:
        self._runs.pop(run_id, None)

    def save_last(self, report: dict) -> None:
        self.last_path.write_text(
            json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def load_last(self) -> dict | None:
        if not self.last_path.exists():
            return None
        try:
            return json.loads(self.last_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None


def generate_run(
    store: BenchmarkStore,
    mode: str,
    model_label: str,
    seed: int | None = None,
    reasoning: str = "",
) -> dict:
    mode = MODE_SOLO if mode == MODE_SOLO else MODE_COMPARE
    if seed is None:
        seed = uuid.uuid4().int % 10_000_000
    # The draw leans away from templates this machine's models have never
    # failed. Runs #4 and #5 spent eight of twelve slots on tasks with p = 1.0 —
    # a ten-minute run that measured nothing.
    # An EMPTY map is still passed on purpose: with no history the draw falls
    # back to the per-category priors, which is exactly what a fresh machine
    # needs. `None` would mean "uniform", and uniform is what produced 28/28.
    try:
        difficulty = difficulty_map(load_items(store.items_path), BENCHMARK_VERSION)
    except OSError:
        difficulty = {}
    tasks = build_tasks(seed, difficulty)
    state = RunState(
        run_id=uuid.uuid4().hex[:12],
        seed=seed,
        mode=mode,
        model_label=(model_label or "неизвестная модель").strip()[:80],
        started_unix=int(time.time()),
        tasks=tasks,
        updated_unix=int(time.time()),
        reasoning=(reasoning or "").strip()[:40],
    )
    store.put(state)
    return {
        "runId": state.run_id,
        "seed": seed,
        "mode": mode,
        "benchmarkVersion": BENCHMARK_VERSION,
        "delegatorVersion": APP_VERSION,
        "tasksPerRun": TASKS_PER_RUN,
        "maxPoints": MAX_POINTS,
        "modelLabel": state.display_label,
        "modelName": state.model_label,
        "modelReasoning": state.reasoning,
        "tasks": [
            {
                "index": index + 1,
                "id": task.template_id,
                "level": task.level,
                "category": task.category,
                "title": task.title,
                "points": task.points,
                "text": task.text,
            }
            for index, task in enumerate(tasks)
        ],
    }


# Everything an agent types when it does not actually know what it is running.
# Seen live on 2026-08-16: a VS Code Copilot agent started three runs, one of
# them with -Model "unknown" -Reasoning "unknown".
PLACEHOLDER_LABELS = {
    "",
    "unknown",
    "unknown model",
    "auto",
    "copilot/auto",
    "default",
    "none",
    "n/a",
    "-",
    "модель",
    "неизвестная модель",
    "неизвестно",
}


def model_label_problem(label: str) -> str | None:
    """Why this label cannot go into a report, or None when it is usable.

    A benchmark compares two systems; a report that names neither is not a
    measurement, and it poisons items.jsonl for every later run. The agent
    usually CAN read its own model — and when it cannot, the user always can,
    so the answer is "ask them", not "invent a placeholder".
    """
    text = (label or "").strip()
    if text.lower() in PLACEHOLDER_LABELS or len(text) < 3:
        return (
            "Нужно точное имя модели: спросите пользователя, какая модель и какой уровень "
            "рассуждений выбраны в его IDE, и повторите start с -Model и -Reasoning. "
            "Отчёт без имени модели ничего не измеряет."
        )
    if not any(char.isdigit() for char in text) and "-" not in text and "." not in text:
        return (
            f"«{text}» — это семейство, а не модель. Нужен точный идентификатор с версией "
            "(gpt-5.4-mini, gemini-3.7-flash, claude-opus-4-8). Спросите пользователя, что "
            "выбрано в переключателе моделей."
        )
    return None


def answer_format_problem(task: Task, text: str) -> str | None:
    """Mechanical check that the answer is the KIND of artefact this task asked
    for, using the grader's OWN extractors — so this can never disagree with it.

    Run 2026-08-15: the agent submitted the SQL task's answer under task 9 and a
    Python function under the SQL task. Both scored 0 for «нет кода», and the
    report announced a 6.4-point Delegator win that was pure file mix-up. The
    grader cannot see intent; this refuses the submission while it is still
    cheap to fix.
    """
    if task.checker["kind"] == "sqlite":
        if not _extract_sql(text):
            return (
                f"Задача {task.title} требует SQL-запрос в блоке ```sql — в присланном файле "
                "его нет. Проверьте, тот ли это файл: он должен решать ИМЕННО эту задачу."
            )
        return None
    if not _extract_python(text):
        return (
            f"Задача {task.title} требует код Python в блоке ```python — в присланном файле "
            "его нет. Проверьте, тот ли это файл: он должен решать ИМЕННО эту задачу."
        )
    return None


def record_answer(
    state: RunState,
    task_index: int,
    arm: str,
    text: str,
    elapsed_ms: int = 0,
    mode: str = "",
) -> None:
    if arm not in ALL_ARMS:
        raise ValueError("unknown arm")
    if not 1 <= task_index <= len(state.tasks):
        raise ValueError("task index out of range")
    key = str(task_index)
    state.answers.setdefault(key, {})[arm] = Answer(
        arm=arm, text=text or "", elapsed_ms=elapsed_ms, mode=(mode or "").strip()[:24]
    )
    state.touch(task_index, STAGE_MODEL if arm == ARM_MODEL else STAGE_DELEGATOR)


# A run is driven from the IDE chat, and that chat can die: the agent hits a
# "servers are overloaded" error, or the user closes the session. Nothing then
# ever calls `finish`, and the app used to keep saying «Бенчмарк идёт» for an
# hour. The agent pings progress before every slow step, so silence this long
# means the other side is gone, not that a task is hard.
STALE_AFTER_SEC = 600


def run_status(state: RunState | None) -> dict | None:
    """Live picture of a run for the GUI; None when nothing is in flight."""
    if state is None:
        return None
    now = int(time.time())
    idle = max(0, now - (state.updated_unix or state.started_unix))
    return {
        "stalled": idle >= STALE_AFTER_SEC,
        "stalledAfterSec": STALE_AFTER_SEC,
        "runId": state.run_id,
        "mode": state.mode,
        "modelLabel": state.display_label,
        "tasksTotal": len(state.tasks),
        "answeredModel": state.answered(ARM_MODEL),
        "answeredDelegator": state.answered(ARM_DELEGATOR),
        "currentTask": state.current_task,
        "currentTitle": (
            state.tasks[state.current_task - 1].title
            if 1 <= state.current_task <= len(state.tasks)
            else ""
        ),
        "stage": state.stage,
        "elapsedSec": max(0, now - state.started_unix),
        "idleSec": idle,
    }


# ── grading ────────────────────────────────────────────────────────────────


def _quotes_given_material(block: str, task_text: str) -> bool:
    """True when this fence just repeats code the TASK already handed over.

    An answer is allowed to quote the material back — «вот это соглашение из
    quota.py, поэтому я делаю так» is how a careful reader explains itself. But
    the quoted module gets concatenated with the real answer and redefines
    module-level names, and measured on a workspace draft that turned a CORRECT
    answer into 0.0 while a WRONG one scored 0.625. The comparison is
    whitespace-insensitive and needs three consecutive lines to match, so a
    coincidental one-liner (`import re`) is never mistaken for a quote.
    """
    if not task_text:
        return False
    lines = [line.strip() for line in (block or "").splitlines() if line.strip()]
    if len(lines) < 3:
        return False
    haystack = "\n".join(line.strip() for line in task_text.splitlines() if line.strip())
    matched = 0
    for index in range(len(lines) - 2):
        window = "\n".join(lines[index:index + 3])
        if window in haystack:
            matched += 1
    # More than half of the block's line windows come from the task: a quote.
    return matched * 2 > max(1, len(lines) - 2)


def _extract_python(answer: str, task_text: str = "") -> str:
    """ALL the Python the answer WROTE, in order — not just the first block.

    Run #8: an answer put the function in one block and `import re` in a second
    with a note to move it. Taking only the first block scored a working answer
    as eleven NameErrors. Whatever one thinks of an answer split that way, the
    grader must read the code that was actually written, and Python binds a
    module-level import before any function is CALLED, so order does not matter
    here. Blocks that are pure demonstration (no import/def/class/assignment)
    are skipped: `print(f([1,2]))` would otherwise run at grading time. Blocks
    that only QUOTE the task's own material are skipped too — see
    `_quotes_given_material`.
    """
    blocks = [match.group(1) for match in _CODE_FENCE.finditer(answer or "")]
    real = [
        block
        for block in blocks
        if re.search(r"(?m)^\s*(import\s+\w|from\s+\w|def\s+\w|class\s+\w|@\w|\w+\s*=)", block)
        and not _quotes_given_material(block, task_text)
    ]
    if real:
        return "\n\n".join(real)
    if blocks:
        return blocks[0]
    if re.search(r"(?m)^\s*(def|class)\s+\w+", answer or ""):
        return answer
    return ""


def _extract_sql(answer: str) -> str:
    match = _SQL_FENCE.search(answer or "")
    if match:
        return match.group(1).strip()
    if re.search(r"(?is)\bselect\b.*\bfrom\b", answer or ""):
        return (answer or "").strip()
    return ""


# Every check reports through this marker as well as through the file channel,
# so a run still grades when the temp directory is not writable.
CHECK_MARKER = "##DGCHECKS##"

# The harness is appended AFTER the candidate: `_dg_ref` and the runner must win
# over anything the answer defined, and re-importing a module here always yields
# the real one from sys.modules even if the candidate rebound the name.
_HARNESS_PRELUDE = r'''
# ---- Delegator benchmark checker ----
import copy as _dg_copy
import io as _dg_io
import json as _dg_json
import os as _dg_os

_dg_results = []
_dg_log = _dg_os.environ.get('DELEGATOR_BENCH_CHECKS') or ''


def _dg_record(_dg_id, _dg_ok, _dg_note):
    _dg_results.append({'id': _dg_id, 'ok': _dg_ok, 'note': _dg_note})
    if _dg_log:
        try:
            with _dg_io.open(_dg_log, 'a', encoding='utf-8') as _dg_fh:
                _dg_fh.write(_dg_json.dumps(
                    {'id': _dg_id, 'ok': _dg_ok, 'note': _dg_note}, ensure_ascii=False) + '\n')
                _dg_fh.flush()
        except OSError:
            pass


def _dg_run(_dg_id, _dg_fn):
    try:
        _dg_fn()
    except BaseException as _dg_err:
        _dg_record(_dg_id, False, ('%s: %s' % (type(_dg_err).__name__, _dg_err))[:200])
    else:
        _dg_record(_dg_id, True, '')
'''


def _indent(block: str) -> str:
    lines = (block or "").splitlines()
    body = "\n".join(("    " + line) if line.strip() else "" for line in lines)
    return body if body.strip() else "    pass"


def _case_body(entry: str, cases: list) -> str:
    return (
        "for _dg_args in %r:\n"
        "    _dg_got = %s(*_dg_copy.deepcopy(_dg_args))\n"
        "    _dg_exp = _dg_ref(*_dg_copy.deepcopy(_dg_args))\n"
        "    assert _dg_got == _dg_exp, "
        "'вход %%r: получено %%r, ожидалось %%r' %% (_dg_args, _dg_got, _dg_exp)\n"
    ) % (cases, entry)


def _check_body(item: dict, entry: str) -> str:
    parts = []
    if (item.get("code") or "").strip():
        parts.append(item["code"])
    if item.get("cases"):
        parts.append(_case_body(entry, item["cases"]))
    return "\n".join(parts)


def _harness(checks: list[dict], entry: str) -> str:
    """Each constraint in its own function, each run in its own try/except.

    One failing constraint must not hide the ones behind it — that is the whole
    difference between "scored 0" and "satisfied 7 of 9".
    """
    parts = [_HARNESS_PRELUDE]
    for number, item in enumerate(checks):
        parts.append("def _dg_check_%d():\n%s\n" % (number, _indent(_check_body(item, entry))))
        parts.append("_dg_run(%r, _dg_check_%d)\n" % (item["id"], number))
    parts.append("print(%r + _dg_json.dumps(_dg_results, ensure_ascii=False))\n" % CHECK_MARKER)
    return "\n".join(parts)


def _python_script(task: Task, candidate: str) -> str:
    checker = task.checker
    parts = []
    # A PRELUDE runs before the answer. That is the only place a task can
    # forbid a module: the candidate's own `import re` at the top of its file
    # would otherwise capture the real one before any check could intervene.
    if checker.get("prelude"):
        parts.append(checker["prelude"])
    parts.extend([candidate, ""])
    if checker.get("reference"):
        parts.append(checker["reference"])
    parts.append(_harness(checker.get("checks") or [], checker.get("entry") or ""))
    return "\n".join(parts) + "\n"


def _sqlite_script(task: Task, query: str) -> str:
    """Publishes `_dg_rows` / `_dg_expect` / `_dg_error` for the checks declared
    in `templates._sql` — a broken query leaves `_dg_rows` None instead of
    killing the whole script, so "does not even run" scores differently from
    "wrong order"."""
    checker = task.checker
    head = (
        "import sqlite3 as _dg_sqlite\n"
        "_dg_expect = %r\n"
        "_dg_rows = None\n"
        "_dg_error = ''\n"
        "try:\n"
        "    _dg_con = _dg_sqlite.connect(':memory:')\n"
        "    _dg_con.executescript(%r)\n"
        "    _dg_rows = [list(_dg_row) for _dg_row in _dg_con.execute(%r)]\n"
        "except Exception as _dg_err:\n"
        "    _dg_error = '%%s: %%s' %% (type(_dg_err).__name__, _dg_err)\n"
    ) % (checker["expect"], checker["setup"], query)
    return head + _harness(checker.get("checks") or [], "")


def _short(text: str, limit: int = 220) -> str:
    return re.sub(r"\s+", " ", str(text or "")).strip()[-limit:]


def _recorded(outcome: dict) -> dict[str, dict]:
    """What the harness managed to report, from the file first, stdout second."""
    entries = [item for item in (outcome.get("checks") or []) if isinstance(item, dict)]
    if not entries:
        stdout = outcome.get("stdout") or ""
        marker = stdout.rfind(CHECK_MARKER)
        if marker >= 0:
            tail = stdout[marker + len(CHECK_MARKER):].splitlines()
            try:
                parsed = json.loads(tail[0]) if tail else []
            except ValueError:
                parsed = []
            entries = [item for item in parsed if isinstance(item, dict)]
    return {str(item.get("id")): item for item in entries if item.get("id")}


def _score_checks(checks: list[dict], recorded: dict[str, dict], fallback: str) -> dict:
    rows: list[dict] = []
    earned = 0
    total = 0
    for item in checks:
        # `or 1` would be wrong here: weight 0 is meaningful (a gate check).
        weight = item.get("weight", 1)
        weight = 1 if weight is None else int(weight)
        total += weight
        entry = recorded.get(item["id"])
        ok = bool(entry and entry.get("ok"))
        if ok:
            earned += weight
        rows.append(
            {
                "id": item["id"],
                "title": item.get("title") or item["id"],
                "weight": weight,
                "ok": ok,
                "note": "" if ok else _short((entry or {}).get("note") or fallback, 200),
            }
        )
    passed = bool(rows) and all(row["ok"] for row in rows)
    first_failure = next((row["note"] for row in rows if not row["ok"] and row["note"]), "")
    return {
        "passed": passed,
        "checks": rows,
        "checksPassed": sum(1 for row in rows if row["ok"]),
        "checksTotal": len(rows),
        "score": round(earned / total, 4) if total else 0.0,
        "note": "" if passed else (first_failure or fallback),
    }


def grade_answer(task: Task, answer_text: str) -> dict:
    """One answer → a verdict per named constraint. Mechanical, no model involved.

    Binary grading is why three live runs in a row came back as twelve ties: a
    task with nine checkable constraints scored 3 or 0 and threw the rest away.
    """
    checks = task.checker.get("checks") or []
    if not (answer_text or "").strip():
        return _score_checks(checks, {}, "ответ пуст")

    if task.checker["kind"] == "sqlite":
        query = _extract_sql(answer_text)
        if not query:
            return _score_checks(checks, {}, "в ответе нет SQL-запроса")
        script = _sqlite_script(task, query)
    else:
        code = _extract_python(answer_text, task.text)
        if not code:
            return _score_checks(checks, {}, "в ответе нет кода Python")
        script = _python_script(task, code)

    outcome = run_candidate(script)
    if outcome["status"] == "timeout":
        fallback = "решение не уложилось во время"
    elif outcome["status"] == "ok":
        fallback = _short(outcome.get("stderr")) or "проверка не была выполнена"
    else:
        fallback = _short(outcome.get("stderr") or outcome.get("stdout")) or "ошибка выполнения"
    return _score_checks(checks, _recorded(outcome), fallback)


def missing_answers(state: RunState) -> dict[str, list[int]]:
    """Which task numbers still owe an answer, per arm.

    A run finished early scores the missing tasks as zero and blames the arm
    that never got to answer — exactly what happened on 2026-08-12, when the
    agent called finish while two Delegator answers were still in flight and the
    report claimed Delegator lost two tasks it had not been asked about.
    """
    arms = [ARM_MODEL] if state.mode == MODE_SOLO else list(ARMS)
    gaps: dict[str, list[int]] = {arm: [] for arm in arms}
    for index in range(1, len(state.tasks) + 1):
        submitted = state.answers.get(str(index), {})
        for arm in arms:
            if arm not in submitted:
                gaps[arm].append(index)
    return {arm: numbers for arm, numbers in gaps.items() if numbers}


# A category is a capability, and the report is far more useful when it says
# WHICH capability moved than when it says the total moved.
CATEGORY_LABELS = {
    "code": "код",
    "sql": "SQL",
    "contract": "много требований",
    "repair": "починка кода",
    "budget": "скорость",
    "trap": "закрытый обходной путь",
    "exactness": "точность правил",
    "integration": "чужой API",
}

# Below this the difference is float noise from proportional partial credit.
EPSILON = 1e-9

# The smallest per-task difference the report is willing to call a win. All
# three renderers round to one decimal, so anything under this prints as two
# identical numbers next to the word «лучше».
VISIBLE_POINT_DIFFERENCE = 0.05

# Significance level for the paired test, and the smallest number of tasks that
# could ever reach it. Printed next to every "не доказано" so the verdict says
# how much evidence is actually missing.
ALPHA = 0.05


def format_points(value: float | int | None) -> str:
    """4.0 → «4», 4.25 → «4.3». Partial credit must not print as 4.2499999.

    Rounds half UP, not to even: `round()` would print 2.25 as «2.2» while the
    Rust GUI (`gui::benchmark::format_points`) prints «2.3» for the same stored
    number, and the two renderers must agree on one report.
    """
    number = float(value or 0)
    scaled = math.floor(abs(number) * 10 + 0.5) / 10
    number = -scaled if number < 0 else scaled
    return str(int(number)) if abs(number - round(number)) < EPSILON else ("%.1f" % number)


def _min_discordant(alpha: float = ALPHA) -> int:
    count = 1
    while 2 * (0.5**count) > alpha:
        count += 1
    return count


def _mcnemar_p(better: int, worse: int) -> float | None:
    """Exact two-sided binomial test over the discordant pairs. No scipy."""
    total = better + worse
    if total == 0:
        return None
    smaller = min(better, worse)
    tail = sum(math.comb(total, index) for index in range(smaller + 1)) / float(2**total)
    return min(1.0, round(2 * tail, 4))


def _pair_stats(rows: list[dict]) -> dict:
    """The paired test, plus how much evidence a proof would actually need.

    "Не доказано" on its own reads as a failure of Delegator; it is usually a
    failure of the sample size, and the report has to say which.
    """
    better = worse = 0
    for row in rows:
        model_ok = (row.get(ARM_MODEL) or {}).get("passed", False)
        delegator_ok = (row.get(ARM_DELEGATOR) or {}).get("passed", False)
        if delegator_ok and not model_ok:
            better += 1
        elif model_ok and not delegator_ok:
            worse += 1
    p_value = _mcnemar_p(better, worse)
    need = _min_discordant()
    if better + worse == 0:
        text = (
            "Полных расхождений нет — этим прогоном разницу нельзя доказать ни в какую "
            f"сторону. Минимум для статистического вывода: {need} "
            f"{plural(need, 'расхождение', 'расхождения', 'расхождений')} в одну сторону."
        )
    else:
        head = (
            f"Расхождения: Delegator справился там, где модель не смогла — {better}; "
            f"обратных случаев — {worse}. Точный тест Макнемара: p = {p_value:.3f}"
        )
        if p_value is not None and p_value < ALPHA:
            text = head + " — разница статистически значима."
        else:
            text = (
                head + f" — этого мало: нужно минимум {need} "
                f"{plural(need, 'расхождение', 'расхождения', 'расхождений')} в одну сторону."
            )
    return {
        "discordantDelegator": better,
        "discordantModel": worse,
        "mcnemarP": p_value,
        "minDiscordantForProof": need,
        "alpha": ALPHA,
        "text": text,
    }


def _profile(rows: list[dict], mode: str) -> dict:
    """Score per level and per category — where the lead or the lag actually is.

    One number answers "did Delegator help"; it never answers "where", which is
    the question the owner asked for.
    """

    def group(key_of, labels: dict, order: list | None = None) -> list[dict]:
        buckets: dict[str, dict] = {}
        for row in rows:
            key = str(key_of(row))
            bucket = buckets.setdefault(
                key,
                {
                    "key": key,
                    "label": labels.get(key, key),
                    "tasks": 0,
                    "maxPoints": 0,
                    ARM_MODEL: 0.0,
                    ARM_DELEGATOR: 0.0,
                },
            )
            bucket["tasks"] += 1
            bucket["maxPoints"] += row["points"]
            bucket[ARM_MODEL] += (row.get(ARM_MODEL) or {}).get("points", 0) or 0
            bucket[ARM_DELEGATOR] += (row.get(ARM_DELEGATOR) or {}).get("points", 0) or 0
        out = []
        for key in order or sorted(buckets):
            bucket = buckets.get(key)
            if bucket is None:
                continue
            bucket[ARM_MODEL] = round(bucket[ARM_MODEL], 2)
            bucket[ARM_DELEGATOR] = (
                round(bucket[ARM_DELEGATOR], 2) if mode == MODE_COMPARE else None
            )
            out.append(bucket)
        return out

    return {
        "byLevel": group(lambda row: row["level"], LEVEL_LABELS, list(LEVEL_LABELS)),
        "byCategory": group(lambda row: row["category"], CATEGORY_LABELS),
    }


def finish_run(store: BenchmarkStore, state: RunState) -> dict:
    state.touch(state.current_task, STAGE_FINISHED)
    rows: list[dict] = []
    totals = {ARM_MODEL: 0.0, ARM_DELEGATOR: 0.0, ARM_ALONE: 0.0}
    counts = {"better": 0, "worse": 0, "same": 0}

    for index, task in enumerate(state.tasks, start=1):
        submitted = state.answers.get(str(index), {})
        row: dict[str, Any] = {
            "index": index,
            "id": task.template_id,
            "title": task.title,
            "level": task.level,
            "category": task.category,
            "points": task.points,
        }
        for arm in ALL_ARMS:
            if arm == ARM_DELEGATOR and state.mode == MODE_SOLO:
                continue
            if arm == ARM_ALONE and (state.mode == MODE_SOLO or ARM_ALONE not in submitted):
                # Optional: a run that never asked Delegator to answer alone is
                # still a valid run, and an absent arm must not be scored zero.
                continue
            answer = submitted.get(arm)
            if answer is None:
                row[arm] = {
                    "answered": False,
                    "passed": False,
                    "points": 0,
                    "maxPoints": task.points,
                    "score": 0.0,
                    "checks": [],
                    "checksPassed": 0,
                    "checksTotal": len(task.checker.get("checks") or []),
                    "note": "нет ответа",
                    "elapsedMs": 0,
                }
                continue
            verdict = grade_answer(task, answer.text)
            points = round(task.points * verdict["score"], 2)
            totals[arm] += points
            row[arm] = {
                "answered": True,
                "points": points,
                "maxPoints": task.points,
                "elapsedMs": answer.elapsed_ms,
                **verdict,
            }
            # Which mode Delegator chose, on whichever arm it produced.
            if answer.mode:
                row[arm]["mode"] = answer.mode
            if arm == ARM_DELEGATOR:
                # A tie means one of two very different things: «Delegator
                # looked and had nothing to fix» or «Delegator never really
                # ran». On 2026-08-16 eleven of twelve Delegator answers were
                # byte-identical to the model's, and the report could not say
                # so. Now it can, and so can items.jsonl.
                model_answer = submitted.get(ARM_MODEL)
                row[arm]["identicalToModel"] = bool(
                    model_answer is not None and model_answer.text == answer.text
                )
        if state.mode == MODE_COMPARE:
            # Points, not passes, decide the per-task winner — but a difference
            # of 1e-9 is float noise, and the 2026-08-15 headline «лучше в 3
            # задачах» was two protocol artefacts plus one 0.43-point fraction.
            # A tenth of a point is the smallest difference the report prints.
            model_points = (row.get(ARM_MODEL) or {}).get("points", 0)
            delegator_points = (row.get(ARM_DELEGATOR) or {}).get("points", 0)
            if delegator_points > model_points + VISIBLE_POINT_DIFFERENCE:
                row["winner"] = ARM_DELEGATOR
                counts["better"] += 1
            elif model_points > delegator_points + VISIBLE_POINT_DIFFERENCE:
                row["winner"] = ARM_MODEL
                counts["worse"] += 1
            else:
                row["winner"] = "tie"
                counts["same"] += 1
        rows.append(row)

    totals = {arm: round(value, 2) for arm, value in totals.items()}
    stats = _pair_stats(rows) if state.mode == MODE_COMPARE else None
    comparability = _comparability(rows) if state.mode == MODE_COMPARE else None
    report = {
        "benchmarkVersion": BENCHMARK_VERSION,
        "delegatorVersion": APP_VERSION,
        "runId": state.run_id,
        "seed": state.seed,
        "mode": state.mode,
        "modelLabel": state.display_label,
        "modelName": state.model_label,
        "modelReasoning": state.reasoning,
        "finishedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "maxPoints": MAX_POINTS,
        "tasks": rows,
        "totals": {
            ARM_MODEL: totals[ARM_MODEL],
            ARM_DELEGATOR: totals[ARM_DELEGATOR] if state.mode == MODE_COMPARE else None,
            # None when the run never asked Delegator to answer alone.
            ARM_ALONE: (
                totals[ARM_ALONE]
                if any(ARM_ALONE in (row or {}) for row in rows)
                else None
            ),
        },
        "counts": counts if state.mode == MODE_COMPARE else None,
        # How many of the twelve tasks were a REAL comparison. A tie means one
        # thing when Delegator looked and found nothing, and quite another when
        # the provider was down — and until 0.6.0 both looked identical.
        "comparability": comparability,
        "profile": _profile(rows, state.mode),
        "stats": stats,
        "verdict": _verdict_text(state, totals, counts, stats, comparability),
    }
    store.save_last(report)
    # Item statistics outlive the run: difficulty and discrimination are what
    # turn "this level feels hard" into a measurement (DEV_CONTRACTS §10).
    try:
        record_run(store.items_path, report)
    except OSError:
        pass
    store.drop(state.run_id)
    return report


def _comparability(rows: list[dict]) -> dict:
    """How much of this run was an actual comparison.

    `changed` is the number of tasks where Delegator handed back something
    different from the draft; `identical` is where it handed the draft straight
    back; `unavailable` is where it could not run at all. Only the first two are
    evidence about quality, and only `changed` can move a score.
    """
    pairs = changed = identical = unavailable = alone = 0
    by_mode: dict[str, int] = {}
    alone_by_mode: dict[str, int] = {}
    for row in rows:
        result = row.get(ARM_DELEGATOR)
        if not isinstance(result, dict) or not result.get("answered"):
            continue
        pairs += 1
        mode = str(result.get("mode") or "")
        if mode:
            by_mode[mode] = by_mode.get(mode, 0) + 1
        if mode in ("unavailable", "timeout"):
            unavailable += 1
        elif result.get("identicalToModel"):
            identical += 1
        else:
            changed += 1
        alone_result = row.get(ARM_ALONE)
        if isinstance(alone_result, dict) and alone_result.get("answered"):
            alone += 1
            alone_mode = str(alone_result.get("mode") or "")
            if alone_mode:
                alone_by_mode[alone_mode] = alone_by_mode.get(alone_mode, 0) + 1
    return {
        "pairs": pairs,
        "changed": changed,
        "identical": identical,
        "unavailable": unavailable,
        "alone": alone,
        "byMode": by_mode,
        # Which modes the router picked when Delegator answered from scratch:
        # the only place `delegate` and `boost` are ever exercised.
        "aloneByMode": alone_by_mode,
    }


def _verdict_text(
    state: RunState,
    totals: dict,
    counts: dict,
    stats: dict | None,
    comparability: dict | None = None,
) -> str:
    model_points = totals[ARM_MODEL]
    if state.mode == MODE_SOLO:
        return (
            f"Модель «{state.display_label}» набрала {format_points(model_points)} "
            f"из {MAX_POINTS} баллов. Delegator в этом прогоне не участвовал."
        )
    delegator_points = totals[ARM_DELEGATOR]
    diff = round(delegator_points - model_points, 2)
    if diff > EPSILON:
        head = (
            f"С Delegator результат выше на {format_points(diff)} "
            f"{plural(diff, 'балл', 'балла', 'баллов')}."
        )
    elif diff < -EPSILON:
        head = (
            f"С Delegator результат НИЖЕ на {format_points(abs(diff))} "
            f"{plural(abs(diff), 'балл', 'балла', 'баллов')}."
        )
    else:
        head = "Delegator не изменил итоговый балл."
    text = (
        f"{head} Модель «{state.display_label}»: {format_points(model_points)} из {MAX_POINTS}, "
        f"с Delegator: {format_points(delegator_points)} из {MAX_POINTS}. "
        f"Delegator лучше в {counts['better']} "
        f"{plural(counts['better'], 'задаче', 'задачах', 'задачах')}, "
        f"хуже в {counts['worse']}, поровну в {counts['same']}."
    )
    if model_points >= MAX_POINTS - EPSILON and delegator_points >= MAX_POINTS - EPSILON:
        # An honest benchmark says when it could not measure anything.
        text += (
            " Обе стороны решили всё — для этой модели набор задач оказался лёгким, "
            "и сравнение ничего не показывает. Запустите ещё раз: задачи будут другими."
        )
    if comparability:
        # Until 0.6.0 «поровну в 12» covered three different worlds: Delegator
        # looked and kept the answer, Delegator never ran, and Delegator was not
        # asked. Each of them now has its own sentence.
        if comparability["unavailable"]:
            text += (
                f" ВНИМАНИЕ: в {comparability['unavailable']} "
                f"{plural(comparability['unavailable'], 'задаче', 'задачах', 'задачах')} "
                "Delegator не смог ответить (провайдер недоступен) — это не ничья, "
                "а отсутствующее сравнение."
            )
        if comparability["pairs"] and not comparability["changed"]:
            text += (
                " Delegator не изменил НИ ОДНОГО ответа: на этом классе задач вашей модели "
                "помощь не нужна, и прогон измеряет только это."
            )
        elif comparability["changed"]:
            text += (
                f" Delegator реально вмешался в {comparability['changed']} "
                f"{plural(comparability['changed'], 'задаче', 'задачах', 'задачах')} "
                f"из {comparability['pairs']}."
            )
    alone_points = totals.get(ARM_ALONE)
    if comparability and comparability.get("alone") and alone_points is not None:
        # The arm that answers the owner's actual claim: how good is Delegator
        # WITHOUT the model's draft to lean on.
        text += (
            f" Delegator сам, без вашего ответа: {format_points(alone_points)} из {MAX_POINTS} "
            f"({comparability['alone']} "
            f"{plural(comparability['alone'], 'задача', 'задачи', 'задач')})."
        )
    if stats:
        text += " " + stats["text"]
    return text


# ── export ─────────────────────────────────────────────────────────────────


def desktop_dir() -> Path:
    """The real Desktop, including a OneDrive-redirected one."""
    if os.name == "nt":
        try:
            import winreg

            key = winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r"Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders",
            )
            try:
                value, _ = winreg.QueryValueEx(key, "Desktop")
                expanded = Path(os.path.expandvars(value))
                if expanded.exists():
                    return expanded
            finally:
                key.Close()
        except OSError:
            pass
    candidate = Path.home() / "Desktop"
    return candidate if candidate.exists() else Path.home()


def _report_stem(report: dict) -> str:
    finished = report.get("finishedAt", "")
    try:
        stamp = datetime.fromisoformat(finished).strftime("%Y.%m.%d")
    except ValueError:
        stamp = datetime.now().strftime("%Y.%m.%d")
    return f"Benchmark_v{report.get('delegatorVersion', APP_VERSION)}_{stamp}"


def _unique_path(directory: Path, stem: str, suffix: str) -> Path:
    path = directory / f"{stem}{suffix}"
    counter = 2
    while path.exists():
        path = directory / f"{stem}_{counter}{suffix}"
        counter += 1
    return path


def plural(count: float, one: str, few: str, many: str) -> str:
    """Russian plural for a report that people read. A fractional score always
    takes the `few` form («2.3 балла»), as the language requires."""
    if abs(count - round(count)) > EPSILON:
        return few
    whole = int(round(count))
    tail = whole % 100
    if 11 <= tail <= 14:
        return many
    return {1: one, 2: few, 3: few, 4: few}.get(whole % 10, many)


def plural_tasks(count: int) -> str:
    return plural(count, "задача", "задачи", "задач")


def arm_cell(result: dict | None, max_points: int) -> str:
    """«2.3/3 (7/9)» — the points and the constraints they came from.

    The bare number invites "so it failed"; the constraint count says how much
    of the task the answer actually got right.
    """
    result = result or {}
    cell = "%s/%s" % (format_points(result.get("points", 0)), max_points)
    total = result.get("checksTotal") or 0
    if total:
        cell += " (%d/%d)" % (result.get("checksPassed") or 0, total)
    return cell


def _profile_lines(report: dict) -> list[str]:
    profile = report.get("profile") or {}
    compare = report.get("mode") == MODE_COMPARE
    groups = list(profile.get("byLevel") or []) + list(profile.get("byCategory") or [])
    if not groups:
        return []
    lines = ["Где сильнее и где слабее"]
    for group in groups:
        line = "  {:<10} {:>2} {:<7}  модель {:<9}".format(
            group.get("label", ""),
            group.get("tasks", 0),
            plural_tasks(int(group.get("tasks", 0))),
            "%s/%s" % (format_points(group.get(ARM_MODEL)), group.get("maxPoints", 0)),
        )
        if compare:
            line += "  Delegator {:<9}".format(
                "%s/%s" % (format_points(group.get(ARM_DELEGATOR)), group.get("maxPoints", 0))
            )
        lines.append(line)
    return lines


def render_text(report: dict) -> str:
    compare = report.get("mode") == MODE_COMPARE
    lines = [
        "Delegator — результаты бенчмарка",
        "=" * 42,
        f"Версия Delegator: {report.get('delegatorVersion')}",
        f"Версия бенчмарка: {report.get('benchmarkVersion')} (сравнивать можно только одинаковые)",
        f"Дата: {report.get('finishedAt')}",
        f"Модель IDE: {report.get('modelLabel')}",
        f"Набор задач (seed): {report.get('seed')}",
        "",
    ]
    header = f"{'#':>2}  {'Задача':<26} {'Уровень':<8} {'Модель':<13}"
    if compare:
        header += f"  {'Delegator':<13}  Кто лучше"
    lines.append(header)
    lines.append("-" * len(header))
    for row in report.get("tasks", []):
        line = "{:>2}  {:<26} {:<8} {:<13}".format(
            row["index"], row["title"][:26], level_label(row["level"]),
            arm_cell(row.get(ARM_MODEL), row["points"]),
        )
        if compare:
            winner = {"delegator": "Delegator", "model": "Модель", "tie": "—"}.get(
                row.get("winner"), "—"
            )
            line += "  {:<13}  {}".format(arm_cell(row.get(ARM_DELEGATOR), row["points"]), winner)
        lines.append(line)
    lines.append("-" * len(header))
    totals = report.get("totals", {})
    lines.append(
        f"Итого модель: {format_points(totals.get(ARM_MODEL))} из {report.get('maxPoints')}"
    )
    if compare:
        lines.append(
            f"Итого с Delegator: {format_points(totals.get(ARM_DELEGATOR))} "
            f"из {report.get('maxPoints')}"
        )
    # One line, never a column: the printed table stays twelve rows wide.
    lines.extend(alone_lines(report))
    profile_lines = _profile_lines(report)
    if profile_lines:
        lines.append("")
        lines.extend(profile_lines)
    lines.append("")
    lines.append(report.get("verdict", ""))
    lines.append("")
    lines.append(
        "Оценка полностью механическая: каждая задача разбита на именованные проверки, "
        "код выполняется,"
    )
    lines.append(
        "SQL сравнивается построчно. Балл задачи — доля пройденных проверок "
        "(в скобках их число)."
    )
    lines.append("Ни одна модель не оценивала ответы.")
    return "\n".join(lines) + "\n"


def alone_lines(report: dict) -> list[str]:
    """The two honesty lines every renderer prints, or nothing.

    Shared by the txt, the SVG and (through the report) the PNG and the GUI, so
    the four of them cannot drift into saying different things about the same
    run — the same reason `format_points` is duplicated rather than reinvented.
    """
    lines: list[str] = []
    totals = report.get("totals") or {}
    comparability = report.get("comparability") or {}
    alone = totals.get(ARM_ALONE)
    if alone is not None:
        lines.append(
            f"Delegator сам (без вашего ответа): {format_points(alone)} "
            f"из {report.get('maxPoints')}"
        )
    if comparability.get("pairs"):
        lines.append(
            "Сравнений по существу: {changed} из {pairs} "
            "(вернул ваш ответ без изменений: {identical}, не смог ответить: {unavailable})".format(
                changed=comparability.get("changed", 0),
                pairs=comparability.get("pairs", 0),
                identical=comparability.get("identical", 0),
                unavailable=comparability.get("unavailable", 0),
            )
        )
    return lines


def _escape(text: str) -> str:
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def render_svg(report: dict) -> str:
    """A plain SVG table — vector, no dependencies, opens in any browser."""
    compare = report.get("mode") == MODE_COMPARE
    rows = report.get("tasks", [])
    profile_groups = list((report.get("profile") or {}).get("byLevel") or []) + list(
        (report.get("profile") or {}).get("byCategory") or []
    )
    row_height = 26
    width = 860 if compare else 620
    height = 210 + row_height * (len(rows) + 2 + len(profile_groups) + 1)
    green, red, ink, muted = "#2e7d32", "#b23c3c", "#1c1c1c", "#6b6b6b"
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" font-family="Segoe UI, Arial, sans-serif">',
        f'<rect width="{width}" height="{height}" fill="#ffffff"/>',
        f'<text x="24" y="40" font-size="20" font-weight="600" fill="{ink}">Delegator — результаты бенчмарка</text>',
        f'<text x="24" y="64" font-size="12" fill="{muted}">Delegator v{_escape(report.get("delegatorVersion"))} · '
        f'набор задач v{_escape(report.get("benchmarkVersion"))} · seed {_escape(report.get("seed"))}</text>',
        f'<text x="24" y="82" font-size="12" fill="{muted}">{_escape(report.get("finishedAt"))} · '
        f'модель IDE: {_escape(report.get("modelLabel"))}</text>',
    ]
    top = 110
    model_x, delegator_x, winner_x = 420, 580, 720
    parts.append(f'<line x1="24" y1="{top + 6}" x2="{width - 24}" y2="{top + 6}" stroke="#dddddd"/>')
    columns = [(24, "Задача"), (330, "Уровень"), (model_x, "Модель")]
    if compare:
        columns += [(delegator_x, "Delegator"), (winner_x, "Лучше")]
    for x, label in columns:
        parts.append(f'<text x="{x}" y="{top}" font-size="12" font-weight="600" fill="{muted}">{label}</text>')

    y = top + 28
    for row in rows:
        model = row.get(ARM_MODEL, {})
        parts.append(
            f'<text x="24" y="{y}" font-size="13" fill="{ink}">{row["index"]}. {_escape(row["title"])}</text>'
        )
        parts.append(
            f'<text x="330" y="{y}" font-size="12" fill="{muted}">{_escape(level_label(row["level"]))}</text>'
        )
        model_color = green if model.get("passed") else red
        parts.append(
            f'<text x="{model_x}" y="{y}" font-size="13" fill="{model_color}">'
            f'{_escape(arm_cell(model, row["points"]))}</text>'
        )
        if compare:
            delegator = row.get(ARM_DELEGATOR, {})
            delegator_color = green if delegator.get("passed") else red
            parts.append(
                f'<text x="{delegator_x}" y="{y}" font-size="13" fill="{delegator_color}">'
                f'{_escape(arm_cell(delegator, row["points"]))}</text>'
            )
            winner = row.get("winner")
            if winner in (ARM_MODEL, ARM_DELEGATOR):
                label = "Delegator" if winner == ARM_DELEGATOR else "модель"
                fill = "#e8f5e9" if winner == ARM_DELEGATOR else "#fdecea"
                stroke = green if winner == ARM_DELEGATOR else red
                parts.append(
                    f'<rect x="{winner_x - 6}" y="{y - 14}" width="86" height="19" rx="4" '
                    f'fill="{fill}" stroke="{stroke}"/>'
                )
                parts.append(
                    f'<text x="{winner_x + 2}" y="{y}" font-size="11" fill="{stroke}">{label}</text>'
                )
            else:
                parts.append(
                    f'<text x="{winner_x + 2}" y="{y}" font-size="11" fill="{muted}">поровну</text>'
                )
        y += row_height

    totals = report.get("totals", {})
    parts.append(f'<line x1="24" y1="{y - 16}" x2="{width - 24}" y2="{y - 16}" stroke="#dddddd"/>')
    parts.append(f'<text x="24" y="{y + 6}" font-size="14" font-weight="600" fill="{ink}">Итого</text>')
    parts.append(
        f'<text x="{model_x}" y="{y + 6}" font-size="14" font-weight="600" fill="{ink}">'
        f'{format_points(totals.get(ARM_MODEL))}/{report.get("maxPoints")}</text>'
    )
    if compare:
        delegator_total = totals.get(ARM_DELEGATOR) or 0
        model_total = totals.get(ARM_MODEL) or 0
        color = green if delegator_total > model_total else (red if delegator_total < model_total else ink)
        parts.append(
            f'<text x="{delegator_x}" y="{y + 6}" font-size="14" font-weight="600" fill="{color}">'
            f'{format_points(delegator_total)}/{report.get("maxPoints")}</text>'
        )
    y += 40

    # Where the lead or the lag is, per level and per capability. A single total
    # answers "did it help" and never answers "where".
    if profile_groups:
        parts.append(
            f'<text x="24" y="{y}" font-size="13" font-weight="600" fill="{ink}">'
            "Где сильнее и где слабее</text>"
        )
        y += 22
        for group in profile_groups:
            tasks = int(group.get("tasks", 0))
            parts.append(
                f'<text x="24" y="{y}" font-size="12" fill="{muted}">'
                f'{_escape(group.get("label", ""))} · {tasks} {plural_tasks(tasks)}</text>'
            )
            parts.append(
                f'<text x="{model_x}" y="{y}" font-size="12" fill="{ink}">'
                f'{format_points(group.get(ARM_MODEL))}/{group.get("maxPoints", 0)}</text>'
            )
            if compare:
                parts.append(
                    f'<text x="{delegator_x}" y="{y}" font-size="12" fill="{ink}">'
                    f'{format_points(group.get(ARM_DELEGATOR))}/{group.get("maxPoints", 0)}</text>'
                )
            y += row_height - 4
        y += 14
    verdict_lines = _wrap(report.get("verdict", ""), 104 if compare else 74)
    for chunk in verdict_lines:
        parts.append(f'<text x="24" y="{y}" font-size="12" fill="{ink}">{_escape(chunk)}</text>')
        y += 18
    parts.append(
        f'<text x="24" y="{y + 8}" font-size="11" fill="{muted}">'
        "Оценка механическая: задача разбита на именованные проверки, балл — доля пройденных. "
        "Модели ответы не оценивали.</text>"
    )
    # The header guessed the height before the verdict was wrapped; grow the
    # canvas if the text ran past it rather than clipping the conclusion.
    needed = y + 30
    if needed > height:
        parts[0] = parts[0].replace(f'height="{height}"', f'height="{needed}"').replace(
            f'viewBox="0 0 {width} {height}"', f'viewBox="0 0 {width} {needed}"'
        )
        parts[1] = parts[1].replace(f'height="{height}"', f'height="{needed}"')
    parts.append("</svg>")
    return "\n".join(parts)


def _wrap(text: str, width: int) -> list[str]:
    words = str(text).split()
    lines: list[str] = []
    current = ""
    for word in words:
        if len(current) + len(word) + 1 > width:
            lines.append(current)
            current = word
        else:
            current = f"{current} {word}".strip()
    if current:
        lines.append(current)
    return lines


# PNG, not SVG, is the shipped picture: Telegram treats an .svg as a web
# document and warns the recipient about revealing their IP address, which is a
# terrible thing to attach to a report people are meant to share. The vector
# version stays available on request.
DEFAULT_FORMATS = ("txt", "png")


def export_report(report: dict, formats: tuple[str, ...] = DEFAULT_FORMATS) -> dict[str, str]:
    """Writes the report to the user's Desktop. Returns {format: path}."""
    directory = desktop_dir()
    stem = _report_stem(report)
    written: dict[str, str] = {}
    if "txt" in formats:
        path = _unique_path(directory, stem, ".txt")
        path.write_text(render_text(report), encoding="utf-8")
        written["txt"] = str(path)
    if "png" in formats:
        try:
            from .image import write_png

            path = _unique_path(directory, stem, ".png")
            write_png(path, report, level_label, ARM_MODEL, ARM_DELEGATOR)
            written["png"] = str(path)
        except Exception as error:  # noqa: BLE001 - never lose a report over a picture
            # No Pillow or no font on this machine: hand over the vector file so
            # the user still has something to share, and say what happened.
            path = _unique_path(directory, stem, ".svg")
            path.write_text(render_svg(report), encoding="utf-8")
            written["svg"] = str(path)
            written["pngError"] = str(error)
    if "svg" in formats and "svg" not in written:
        path = _unique_path(directory, stem, ".svg")
        path.write_text(render_svg(report), encoding="utf-8")
        written["svg"] = str(path)
    return written

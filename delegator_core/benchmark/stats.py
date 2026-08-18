"""Item statistics: how hard each task template really is, and whether it separates.

A benchmark that never measures its own items drifts. A task everybody solves
costs a slot in the run and measures nothing; a level stays an opinion until the
numbers contradict it. The 0.5.4 re-levelling was done by hand once, off two
live runs — this module is what makes the next one evidence instead of a hunch.

Every graded item is appended to `<RT>\\benchmark\\items.jsonl` when a run
finishes, and summarised here into the classic pair:

* **p-value** — the share of the item's points that answers actually earn.
  1.0 means nobody ever fails it.
* **discrimination** — the corrected item-total correlation: does this item
  separate the runs that scored high overall from the ones that scored low?
  An item near 0 (or negative) adds noise, however hard it looks.

Applying a suggestion CHANGES THE TASK SET, so it belongs with a
`BENCHMARK_VERSION` bump. Nothing here edits a template by itself: the numbers
are evidence for a decision, never an automatic one.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

# Below these counts the numbers are noise dressed as statistics, and the
# summary says so instead of printing a confident wrong answer.
MIN_SAMPLES_FOR_DISCRIMINATION = 5
MIN_SAMPLES_FOR_ADVICE = 8

# Where a template belongs, by measured pass rate. Deliberately the same three
# names the run uses, so a suggestion is directly actionable.
LEVEL_THRESHOLDS = ((0.9, "fast"), (0.6, "normal"))
LEVEL_ORDER = {"fast": 0, "normal": 1, "deep": 2}

# An item nobody has ever failed, seen enough times and by more than one model,
# is not measuring anything and should be replaced.
RETIRE_P_VALUE = 0.98

ARMS = ("model", "delegator", "alone")

# Only the MODEL arm says anything about how hard an item is. The delegator arm
# is a byte copy of it most of the time (104 of 108 live pairs), so counting
# both doubles every sample guard while adding no information, and the `alone`
# arm measures Delegator's models rather than the item. Difficulty means one
# thing: how often an ordinary IDE model fails this task.
EVIDENCE_ARM = "model"


def same_task_set(version: str, current: str) -> bool:
    """True when two task-set versions may be pooled into one statistic.

    Only the MAJOR part counts: 2.0 renamed classes and fixed a reference that
    had been marking correct answers wrong, so 1.x samples of `topo-sort`
    produce a discrimination of −0.539 for an item that is not broken any more.
    The project already forbids comparing REPORTS across versions; item
    statistics were pooling them anyway, and they steer the draw.
    """
    left = str(version or "").split(".")[0]
    right = str(current or "").split(".")[0]
    return bool(left) and left == right


def for_task_set(items: list[dict], current: str) -> list[dict]:
    """Only the items recorded under the current major task-set version."""
    return [item for item in items if same_task_set(item.get("benchmarkVersion"), current)]


def evidence_only(items: list[dict]) -> list[dict]:
    """Only the rows that are independent evidence about an item's difficulty."""
    return [item for item in items if str(item.get("arm") or "") == EVIDENCE_ARM]

# The history is append-only, so it needs a ceiling: 24 lines per run means a
# heavy user would otherwise carry every run they ever made forever.
MAX_LINES = 20000
TRIM_AT_LINES = 50000


def record_run(path: Path | str, report: dict) -> int:
    """Appends one line per graded (task, arm). Returns how many were written.

    Unanswered arms are skipped: a missing answer is a protocol failure, not
    evidence that the task is hard.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    with path.open("a", encoding="utf-8") as handle:
        for row in report.get("tasks") or []:
            for arm in ARMS:
                result = row.get(arm)
                if not isinstance(result, dict) or not result.get("answered"):
                    continue
                handle.write(
                    json.dumps(
                        {
                            "ts": report.get("finishedAt"),
                            "runId": report.get("runId"),
                            "benchmarkVersion": report.get("benchmarkVersion"),
                            "seed": report.get("seed"),
                            "modelLabel": report.get("modelLabel"),
                            "arm": arm,
                            "template": row.get("id"),
                            "level": row.get("level"),
                            "category": row.get("category"),
                            "maxPoints": row.get("points"),
                            "points": result.get("points"),
                            "score": result.get("score"),
                            "passed": bool(result.get("passed")),
                            "checksPassed": result.get("checksPassed"),
                            "checksTotal": result.get("checksTotal"),
                            # True when Delegator handed the draft back
                            # unchanged. Without it a tie cannot be told apart
                            # from «Delegator never ran» — 11 of 12 tasks on
                            # 2026-08-16 were byte-identical, and the report
                            # said only «поровну».
                            "identicalToModel": bool(result.get("identicalToModel")),
                            "mode": result.get("mode") or "",
                            "failed": [
                                check.get("id")
                                for check in (result.get("checks") or [])
                                if not check.get("ok")
                            ],
                            "elapsedMs": result.get("elapsedMs"),
                        },
                        ensure_ascii=False,
                    )
                    + "\n"
                )
                written += 1
    _trim(path)
    return written


def _trim(path: Path) -> None:
    """Keeps the newest `MAX_LINES` once the file passes `TRIM_AT_LINES`.

    Trimming rarely and in bulk keeps the common path a plain append; a failure
    here must never fail a finished run, so it is swallowed.
    """
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
        if len(lines) <= TRIM_AT_LINES:
            return
        path.write_text("\n".join(lines[-MAX_LINES:]) + "\n", encoding="utf-8")
    except OSError:
        pass


def load_items(path: Path | str, limit: int = MAX_LINES) -> list[dict]:
    """The most recent `limit` recorded items; a corrupt line is skipped, not fatal."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError:
        return []
    items: list[dict] = []
    for line in raw.splitlines()[-limit:]:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("template"):
            items.append(entry)
    return items


def difficulty_map(items: list[dict], current_version: str = "") -> dict[str, float]:
    """{template id: measured pass share} for the weighted draw.

    Deliberately the raw mean over every recorded arm-answer, with no minimum
    sample size: one observation is weak evidence, but it is still evidence,
    and `templates._draw_weight` never lets a template's weight reach zero.
    Items from an older major task set are dropped: they steer which tasks a
    user is given, and a template that was graded by a broken reference in 1.6
    must not bias the 2.x draw.
    """
    if current_version:
        items = for_task_set(items, current_version)
    items = evidence_only(items)
    totals: dict[str, list[float]] = {}
    for item in items:
        totals.setdefault(str(item.get("template")), []).append(float(item.get("score") or 0.0))
    return {name: sum(scores) / len(scores) for name, scores in totals.items() if scores}


def _pearson(xs: list[float], ys: list[float]) -> float | None:
    count = len(xs)
    if count < 2:
        return None
    mean_x = sum(xs) / count
    mean_y = sum(ys) / count
    dx = [x - mean_x for x in xs]
    dy = [y - mean_y for y in ys]
    denominator = math.sqrt(sum(value * value for value in dx) * sum(value * value for value in dy))
    if denominator <= 0:
        return None
    return round(sum(a * b for a, b in zip(dx, dy)) / denominator, 3)


def suggested_level(p_value: float) -> str:
    for threshold, level in LEVEL_THRESHOLDS:
        if p_value >= threshold:
            return level
    return "deep"


def summarise(items: list[dict], known: dict[str, str] | None = None, current_version: str = "") -> dict:
    """Per-template difficulty and discrimination, plus what to do about it.

    `known` maps template id → its current level, so the summary can also name
    the templates that have never been drawn yet: a sample that silently covers
    two thirds of the pool would read as if it covered all of it.
    """
    if current_version:
        items = for_task_set(items, current_version)
    items = evidence_only(items)
    totals: dict[tuple, float] = {}
    for item in items:
        key = (item.get("runId"), item.get("arm"))
        totals[key] = totals.get(key, 0.0) + float(item.get("points") or 0.0)

    grouped: dict[str, list[dict]] = {}
    for item in items:
        grouped.setdefault(str(item.get("template")), []).append(item)

    templates: list[dict] = []
    for template, rows in sorted(grouped.items()):
        scores = [float(row.get("score") or 0.0) for row in rows]
        samples = len(scores)
        p_value = round(sum(scores) / samples, 3)
        full_pass = round(sum(1 for row in rows if row.get("passed")) / samples, 3)
        rest = [
            totals.get((row.get("runId"), row.get("arm")), 0.0) - float(row.get("points") or 0.0)
            for row in rows
        ]
        discrimination = (
            _pearson(scores, rest) if samples >= MIN_SAMPLES_FOR_DISCRIMINATION else None
        )
        level = str(rows[-1].get("level") or (known or {}).get(template) or "")
        models = sorted({str(row.get("modelLabel") or "") for row in rows})
        # Levelling on the FRACTIONAL score reads partial credit as easiness:
        # `topo-sort` scores 0.95 on average while only 3 of 4 answers actually
        # pass it. The level a task belongs to is about passing it.
        suggestion = suggested_level(full_pass)
        templates.append(
            {
                "template": template,
                "level": level,
                "category": str(rows[-1].get("category") or ""),
                "samples": samples,
                "models": models,
                "pValue": p_value,
                "fullPass": full_pass,
                "discrimination": discrimination,
                "suggestedLevel": suggestion,
                "advice": _advice(p_value, samples, models, level, suggestion, discrimination),
            }
        )

    templates.sort(key=lambda row: (LEVEL_ORDER.get(row["level"], 9), row["template"]))
    seen = set(grouped)
    unseen = sorted(name for name in (known or {}) if name not in seen)
    return {
        "samples": len(items),
        "runs": len({item.get("runId") for item in items}),
        "models": sorted({str(item.get("modelLabel") or "") for item in items}),
        "templates": templates,
        "unseen": unseen,
        "minSamplesForAdvice": MIN_SAMPLES_FOR_ADVICE,
        "taskSet": current_version,
    }


def _advice(
    p_value: float,
    samples: int,
    models: list[str],
    level: str,
    suggestion: str,
    discrimination: float | None,
) -> str:
    """`keep` / `more-data` / `retire` / `move-<level>` / `weak`.

    Never `retire` on one model's word: an item that only one model aced may
    simply be that model's strong suit.
    """
    if samples < MIN_SAMPLES_FOR_ADVICE:
        return "more-data"
    if p_value >= RETIRE_P_VALUE and len(models) >= 2:
        return "retire"
    if suggestion != level and level:
        return "move-%s" % suggestion
    if discrimination is not None and discrimination < 0.1:
        return "weak"
    return "keep"

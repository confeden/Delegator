"""The benchmark must be trustworthy before it is public: a correct answer has
to score, a wrong one must not, and neither may depend on a model."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from delegator_core.benchmark import engine, sandbox, stats
from delegator_core.benchmark.templates import (
    LEVEL_MIX,
    MAX_POINTS,
    TASKS_PER_RUN,
    build_tasks,
    known_template_ids,
)


def test_same_seed_repeats_and_new_seed_differs():
    first = build_tasks(1234)
    again = build_tasks(1234)
    other = build_tasks(4321)
    assert [t.template_id for t in first] == [t.template_id for t in again]
    assert [t.text for t in first] == [t.text for t in again]
    # Different seed: either other templates or at least other generated data.
    assert [t.text for t in first] != [t.text for t in other]


def test_run_shape_matches_the_promised_mix():
    """The printed table stays twelve rows (the owner's visual budget) and the
    points a run can award must match what the report prints as the maximum.

    The literal 12 is the promise; MAX_POINTS is deliberately NOT hard-coded —
    the level mix is re-weighted by measurement, and pinning the number here
    only ever produced a stale test."""
    tasks = build_tasks(7)
    assert len(tasks) == TASKS_PER_RUN == 12
    levels = {level: 0 for level in LEVEL_MIX}
    for task in tasks:
        levels[task.level] += 1
    assert levels == LEVEL_MIX
    # A template's own level decides its points; moving one between groups in
    # TEMPLATES without editing the template itself silently broke this.
    assert sum(task.points for task in tasks) == MAX_POINTS


CORRECT_ANSWERS = {
    "unique-ordered": "```python\ndef unique_ordered(items):\n    seen=set()\n    out=[]\n    for i in items:\n        if i not in seen:\n            seen.add(i)\n            out.append(i)\n    return out\n```",
    "safe-div": "```python\ndef safe_div(a, b):\n    return None if b == 0 else a / b\n```",
    "chunk": "```python\ndef chunk(items, size):\n    if size <= 0:\n        raise ValueError('size')\n    return [list(items[i:i+size]) for i in range(0, len(items), size)]\n```",
}


def _task_of(template_id: str):
    """A run holds 4 of the 5 fast templates, so hunt for a seed that includes
    the one under test instead of pinning a magic seed."""
    for seed in range(1, 300):
        for task in build_tasks(seed):
            if task.template_id == template_id:
                return task
    raise AssertionError("template %s is never generated" % template_id)


@pytest.mark.parametrize("template_id", sorted(CORRECT_ANSWERS))
def test_correct_answer_passes_and_broken_answer_fails(template_id):
    task = _task_of(template_id)
    good = engine.grade_answer(task, CORRECT_ANSWERS[template_id])
    assert good["passed"], good["note"]

    broken = engine.grade_answer(task, "```python\ndef %s(*args, **kwargs):\n    return 'nope'\n```" % template_id.replace("-", "_"))
    assert not broken["passed"]
    assert broken["note"]


def test_answer_without_code_never_scores():
    task = build_tasks(5)[0]
    verdict = engine.grade_answer(task, "Конечно! Вот подробное объяснение без кода.")
    assert not verdict["passed"]


def test_sqlite_task_grades_by_executing_the_query():
    task = next(
        t for seed in range(1, 300) for t in build_tasks(seed) if t.category == "sql"
    )
    wrong = engine.grade_answer(task, "```sql\nSELECT 1\n```")
    assert not wrong["passed"]


def test_full_run_scores_and_reports(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="compare", model_label="test-model", seed=2026)
    state = store.get(started["runId"])
    assert state is not None

    # The model arm answers one task correctly, Delegator answers nothing.
    index, task = next(
        (i, t) for i, t in enumerate(state.tasks, start=1) if t.template_id in CORRECT_ANSWERS
    )  # seed 2026 is chosen so at least one known-answer template is present
    engine.record_answer(state, index, engine.ARM_MODEL, CORRECT_ANSWERS[task.template_id])

    report = engine.finish_run(store, state)
    assert report["benchmarkVersion"] == engine.BENCHMARK_VERSION
    assert report["maxPoints"] == MAX_POINTS
    assert report["totals"]["model"] == task.points
    assert report["totals"]["delegator"] == 0
    assert len(report["tasks"]) == TASKS_PER_RUN
    assert report["counts"]["worse"] == 1  # model solved it, Delegator arm did not

    text = engine.render_text(report)
    assert "Версия бенчмарка" in text and "test-model" in text
    svg = engine.render_svg(report)
    assert svg.startswith("<svg") and svg.rstrip().endswith("</svg>")

    # The stored copy is what the GUI reads.
    stored = json.loads(store.last_path.read_text(encoding="utf-8"))
    assert stored["runId"] == report["runId"]


def test_solo_mode_has_no_delegator_column(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="solo", model_label="solo-model", seed=11)
    state = store.get(started["runId"])
    report = engine.finish_run(store, state)
    assert report["mode"] == "solo"
    assert report["totals"]["delegator"] is None
    assert report["counts"] is None
    assert "Delegator в этом прогоне не участвовал" in report["verdict"]
    assert all("delegator" not in row for row in report["tasks"])


def test_export_writes_both_files(tmp_path, monkeypatch):
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="solo", model_label="m", seed=3)
    report = engine.finish_run(store, store.get(started["runId"]))
    desktop = tmp_path / "Desktop"
    desktop.mkdir()
    monkeypatch.setattr(engine, "desktop_dir", lambda: desktop)

    files = engine.export_report(report)
    assert set(files) == {"txt", "png"}
    for path in files.values():
        assert path.startswith(str(desktop))
    # Name carries the Delegator version and the date, per the owner's request.
    assert "Benchmark_v" in files["txt"]

    again = engine.export_report(report)
    assert again["txt"] != files["txt"], "existing report must not be overwritten"


def _wrap_solution(task) -> str:
    """A known-good answer in the shape a model would send it."""
    fence = "sql" if task.checker["kind"] == "sqlite" else "python"
    return "```%s\n%s\n```" % (fence, task.checker["solution"])


def _every_template_once():
    """One generated instance of every template, across as many seeds as needed."""
    from delegator_core.benchmark.templates import TEMPLATES

    wanted = {builder.__name__ for group in TEMPLATES.values() for builder in group}
    seen: dict[str, object] = {}
    for seed in range(1, 400):
        for task in build_tasks(seed):
            seen.setdefault(task.template_id, task)
        if len(seen) >= len(wanted):
            break
    return list(seen.values())


@pytest.mark.parametrize("task", _every_template_once(), ids=lambda task: task.template_id)
def test_every_checker_accepts_its_own_reference_solution(task):
    """The grader must be satisfiable. A checker no correct answer can pass would
    silently measure the benchmark instead of the models — that is exactly how a
    public benchmark loses its credibility."""
    verdict = engine.grade_answer(task, _wrap_solution(task))
    assert verdict["passed"], "%s: %s" % (task.template_id, verdict["note"])


@pytest.mark.parametrize("task", _every_template_once(), ids=lambda task: task.template_id)
def test_every_checker_rejects_an_empty_stub(task):
    stub = "```sql\nSELECT 1\n```" if task.checker["kind"] == "sqlite" else (
        "```python\ndef _stub():\n    return None\n```"
    )
    assert not engine.grade_answer(task, stub)["passed"], task.template_id


def test_export_writes_a_png_that_chats_accept(tmp_path, monkeypatch):
    """The shared picture must be a raster image: Telegram warns about .svg
    ("the sender may learn your IP"), which is the last thing a report meant for
    sharing should do."""
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="compare", model_label="png-model", seed=17)
    report = engine.finish_run(store, store.get(started["runId"]))
    desktop = tmp_path / "Desktop"
    desktop.mkdir()
    monkeypatch.setattr(engine, "desktop_dir", lambda: desktop)

    files = engine.export_report(report)
    assert set(files) == {"txt", "png"}, files
    png = Path(files["png"])
    assert png.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    assert png.stat().st_size > 5000


def test_export_falls_back_to_svg_when_the_picture_cannot_be_drawn(tmp_path, monkeypatch):
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="solo", model_label="m", seed=18)
    report = engine.finish_run(store, store.get(started["runId"]))
    desktop = tmp_path / "Desktop"
    desktop.mkdir()
    monkeypatch.setattr(engine, "desktop_dir", lambda: desktop)

    import delegator_core.benchmark.image as image_module

    def explode(*_args, **_kwargs):
        raise image_module.ImageUnavailable("no font")

    monkeypatch.setattr(image_module, "write_png", explode)

    files = engine.export_report(report)
    assert "svg" in files and "png" not in files
    assert "no font" in files["pngError"]
    assert Path(files["svg"]).read_text(encoding="utf-8").startswith("<svg")


def test_missing_answers_names_the_gaps(tmp_path):
    """A run finished early scores the unanswered tasks as zero and blames the
    arm that was never asked — the API refuses such a finish, so the engine has
    to report exactly what is missing."""
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="compare", model_label="m", seed=21)
    state = store.get(started["runId"])

    gaps = engine.missing_answers(state)
    assert gaps["model"] == list(range(1, 13))
    assert gaps["delegator"] == list(range(1, 13))

    for index in range(1, 13):
        engine.record_answer(state, index, engine.ARM_MODEL, "x")
    for index in range(1, 11):
        engine.record_answer(state, index, engine.ARM_DELEGATOR, "x")

    gaps = engine.missing_answers(state)
    assert "model" not in gaps
    assert gaps["delegator"] == [11, 12]

    for index in (11, 12):
        engine.record_answer(state, index, engine.ARM_DELEGATOR, "x")
    assert engine.missing_answers(state) == {}


def test_solo_run_does_not_wait_for_a_delegator_arm(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="solo", model_label="m", seed=22)
    state = store.get(started["runId"])
    for index in range(1, 13):
        engine.record_answer(state, index, engine.ARM_MODEL, "x")
    assert engine.missing_answers(state) == {}


# ── partial credit (DEV_CONTRACTS §10) ─────────────────────────────────────


def _solution_of(task) -> str:
    return _wrap_solution(task)


def test_a_nearly_correct_answer_scores_between_zero_and_full():
    """The reason the scoring changed: a task with eight constraints used to
    score 2 or 0, so an answer that got seven of them right was indistinguishable
    from one that got none — and every run came back a tie."""
    task = _task_of("safe-div")
    # Correct except for the division-by-zero rule the task spells out.
    verdict = engine.grade_answer(task, "```python\ndef safe_div(a, b):\n    return a / b\n```")
    assert not verdict["passed"]
    assert 0.0 < verdict["score"] < 1.0
    assert 0 < verdict["checksPassed"] < verdict["checksTotal"]
    # The failing constraint is named, not just counted.
    failed = [check for check in verdict["checks"] if not check["ok"]]
    assert failed and all(check["title"] for check in failed)


@pytest.mark.parametrize("task", _every_template_once(), ids=lambda task: task.template_id)
def test_a_degenerate_answer_stays_near_zero(task):
    """Partial credit must not pay for garbage. A stub that returns None (or
    `SELECT 1`) satisfies the odd constraint by luck; a third of the task is the
    most that may ever buy — otherwise a non-answer reads as a real score."""
    stub = (
        "```sql\nSELECT 1\n```"
        if task.checker["kind"] == "sqlite"
        else "```python\ndef %s(*args, **kwargs):\n    return None\n```"
        % (task.checker.get("entry") or "_stub")
    )
    verdict = engine.grade_answer(task, stub)
    assert not verdict["passed"]
    assert verdict["score"] <= 0.35, "%s: заглушка набрала %s" % (
        task.template_id,
        verdict["score"],
    )


def test_the_entry_point_gate_earns_no_points():
    """`contract` and `runs` are diagnostics, not achievements: naming a function
    correctly must be worth zero, or every non-answer starts above the floor."""
    task = _task_of("chunk")
    gates = [check for check in task.checker["checks"] if check["id"] == "contract"]
    assert gates and gates[0]["weight"] == 0


def test_a_sql_answer_with_the_right_rows_in_the_wrong_order_scores_partially():
    task = next(
        t
        for seed in range(1, 300)
        for t in build_tasks(seed)
        if t.template_id == "sql-dup-emails"
    )
    reversed_query = "SELECT * FROM (%s) ORDER BY 1 DESC" % task.checker["solution"]
    verdict = engine.grade_answer(task, "```sql\n%s\n```" % reversed_query)
    assert not verdict["passed"], "порядок строк задан в условии"
    by_id = {check["id"]: check["ok"] for check in verdict["checks"]}
    assert by_id["runs"] and by_id["shape"] and by_id["rows"]
    assert not by_id["order"]
    assert 0.5 < verdict["score"] < 1.0


def test_a_hanging_answer_still_keeps_the_constraints_it_satisfied(monkeypatch):
    """A candidate that loops forever is killed with its output unflushed. The
    checks it already passed are recovered from the file channel — that is the
    difference between "wrong" and "slow", and the only way a future performance
    task can be graded at all."""
    monkeypatch.setattr(
        engine, "run_candidate", lambda script: sandbox.run_candidate(script, timeout_sec=6)
    )
    task = _task_of("safe-div")
    verdict = engine.grade_answer(
        task,
        "```python\n"
        "def safe_div(a, b):\n"
        "    if b == 0:\n"
        "        while True:\n"
        "            pass\n"
        "    return a / b\n"
        "```",
    )
    assert not verdict["passed"]
    assert verdict["checksPassed"] > 0, "успевшие проверки должны быть засчитаны"
    assert verdict["checksPassed"] < verdict["checksTotal"]


def _full_run(store, seed: int, model_answer, delegator_answer, mode: str = "compare"):
    started = engine.generate_run(store, mode=mode, model_label="bench-model", seed=seed)
    state = store.get(started["runId"])
    for index, task in enumerate(state.tasks, start=1):
        engine.record_answer(state, index, engine.ARM_MODEL, model_answer(index, task))
        if mode == "compare":
            engine.record_answer(
                state, index, engine.ARM_DELEGATOR, delegator_answer(index, task)
            )
    return engine.finish_run(store, state)


def test_the_profile_splits_the_score_by_level_and_category(tmp_path):
    """«Где отставание или опережение» is a per-level question; one total can
    never answer it."""
    store = engine.BenchmarkStore(tmp_path)
    report = _full_run(
        store,
        seed=4242,
        model_answer=lambda index, task: _solution_of(task) if index % 2 else "",
        delegator_answer=lambda index, task: _solution_of(task),
    )
    levels = report["profile"]["byLevel"]
    assert [group["key"] for group in levels] == ["fast", "normal", "deep"]
    assert sum(group["maxPoints"] for group in levels) == MAX_POINTS
    assert sum(group["model"] for group in levels) == pytest.approx(report["totals"]["model"])
    assert sum(group["delegator"] for group in levels) == pytest.approx(
        report["totals"]["delegator"]
    )
    categories = report["profile"]["byCategory"]
    assert sum(group["tasks"] for group in categories) == TASKS_PER_RUN
    assert report["totals"]["delegator"] == MAX_POINTS


def test_a_solo_profile_has_no_delegator_column(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    report = _full_run(
        store,
        seed=99,
        model_answer=lambda index, task: _solution_of(task),
        delegator_answer=lambda index, task: "",
        mode="solo",
    )
    assert report["stats"] is None
    assert all(group["delegator"] is None for group in report["profile"]["byLevel"])


# ── honest statistics ──────────────────────────────────────────────────────


def test_mcnemar_is_exact_and_names_the_evidence_it_still_needs():
    assert engine._mcnemar_p(0, 0) is None
    # Six discordant pairs all one way is the smallest sample that can reach 0.05.
    assert engine._min_discordant() == 6
    assert engine._mcnemar_p(5, 0) > engine.ALPHA
    assert engine._mcnemar_p(6, 0) < engine.ALPHA
    assert engine._mcnemar_p(3, 3) == 1.0


def test_a_run_without_discordant_tasks_says_what_a_proof_would_take(tmp_path):
    """"Не доказано" alone reads as a failure of Delegator. It is usually a
    failure of the sample size, and the report has to say which."""
    store = engine.BenchmarkStore(tmp_path)
    report = _full_run(
        store,
        seed=31337,
        model_answer=lambda index, task: _solution_of(task),
        delegator_answer=lambda index, task: _solution_of(task),
    )
    assert report["totals"]["model"] == report["totals"]["delegator"] == MAX_POINTS
    assert report["stats"]["discordantDelegator"] == 0
    assert report["stats"]["mcnemarP"] is None
    assert "6" in report["stats"]["text"]
    assert "набор задач оказался лёгким" in report["verdict"]
    assert report["stats"]["text"] in report["verdict"]


def test_points_render_without_float_noise():
    assert engine.format_points(4.0) == "4"
    assert engine.format_points(2.25) == "2.3"
    assert engine.format_points(None) == "0"
    assert engine.plural(1, "балл", "балла", "баллов") == "балл"
    assert engine.plural(2.3, "балл", "балла", "баллов") == "балла"
    assert engine.plural(11, "балл", "балла", "баллов") == "баллов"


def test_the_text_report_shows_constraints_next_to_the_points(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    report = _full_run(
        store,
        seed=515,
        model_answer=lambda index, task: _solution_of(task),
        delegator_answer=lambda index, task: _solution_of(task),
    )
    text = engine.render_text(report)
    assert "Где сильнее и где слабее" in text
    assert "простая" in text and "сложная" in text
    assert "(" in text and "проверок" in text
    svg = engine.render_svg(report)
    assert svg.startswith("<svg") and svg.rstrip().endswith("</svg>")
    assert "Где сильнее и где слабее" in svg


# ── item statistics ────────────────────────────────────────────────────────


def test_every_finished_run_records_its_items(tmp_path):
    store = engine.BenchmarkStore(tmp_path)
    report = _full_run(
        store,
        seed=606,
        model_answer=lambda index, task: _solution_of(task),
        delegator_answer=lambda index, task: _solution_of(task),
    )
    items = stats.load_items(store.items_path)
    assert len(items) == TASKS_PER_RUN * 2
    assert {item["arm"] for item in items} == {"model", "delegator"}
    assert all(item["runId"] == report["runId"] for item in items)
    assert all(item["template"] and item["level"] for item in items)


def test_an_unanswered_arm_is_not_evidence_about_difficulty(tmp_path):
    """A missing answer is a protocol failure. Recording it as a failed item
    would make the task look harder than it is."""
    store = engine.BenchmarkStore(tmp_path)
    started = engine.generate_run(store, mode="compare", model_label="m", seed=707)
    state = store.get(started["runId"])
    engine.record_answer(state, 1, engine.ARM_MODEL, _solution_of(state.tasks[0]))
    engine.finish_run(store, state)
    items = stats.load_items(store.items_path)
    assert len(items) == 1 and items[0]["arm"] == "model"


def test_item_statistics_measure_difficulty_and_discrimination():
    def item(template, run, arm, score, level="normal"):
        return {
            "runId": run, "arm": arm, "template": template, "level": level,
            "category": "code", "modelLabel": "m-%s" % run, "score": score,
            "points": score * 2, "passed": score >= 1.0,
        }

    items = []
    for run in range(stats.MIN_SAMPLES_FOR_ADVICE):
        # `easy` is solved by everyone: it separates nothing.
        items.append(item("easy", run, "model", 1.0))
        # `sharp` tracks the run's overall strength: this is what an item is for.
        items.append(item("sharp", run, "model", 1.0 if run >= 4 else 0.0))
        items.append(item("filler", run, "model", 1.0 if run >= 4 else 0.0))
    summary = stats.summarise(items, known={"easy": "normal", "sharp": "normal", "never": "deep"})
    by_id = {row["template"]: row for row in summary["templates"]}
    assert by_id["easy"]["pValue"] == 1.0
    assert by_id["easy"]["advice"] == "retire"
    assert by_id["sharp"]["discrimination"] > 0.5
    assert by_id["sharp"]["advice"] in ("keep", "move-deep")
    assert summary["runs"] == stats.MIN_SAMPLES_FOR_ADVICE
    # A sample that covers part of the pool must not read as covering all of it.
    assert summary["unseen"] == ["never"]


def test_the_draw_avoids_templates_nobody_ever_fails():
    """Runs #4 and #5 spent eight of twelve slots on tasks with p = 1.0 — ten
    minutes of a benchmark measuring nothing. The draw now leans away from them,
    but never to zero: the measurement has to be able to change its mind."""
    from delegator_core.benchmark.templates import TEMPLATES, template_id_of

    solved = {template_id_of(builder): 1.0 for builder in TEMPLATES["deep"][:8]}
    drawn_biased, drawn_plain = [], []
    for seed in range(1, 60):
        drawn_biased += [t.template_id for t in build_tasks(seed, solved) if t.level == "deep"]
        drawn_plain += [t.template_id for t in build_tasks(seed) if t.level == "deep"]
    share_biased = sum(1 for name in drawn_biased if name in solved) / len(drawn_biased)
    share_plain = sum(1 for name in drawn_plain if name in solved) / len(drawn_plain)
    assert share_biased < share_plain / 2, (share_biased, share_plain)
    assert share_biased > 0.0, "a solved template must still be reachable"


def test_an_unmeasured_new_class_task_outweighs_an_unmeasured_legacy_one():
    """Run #6 is why this exists: treating "never drawn" as one bucket put twelve
    unmeasured legacy templates in the same pool as the five written to break a
    model, the new classes got one of six deep slots, and the run came back
    28/28 again. Five runs of ceilings are evidence about the legacy classes."""
    from delegator_core.benchmark.templates import CATEGORY_PRIOR, _draw_weight

    legacy = _draw_weight("never-seen", "code", {})
    fresh = _draw_weight("never-seen", "spec", {})
    assert fresh > legacy * 4, (fresh, legacy)
    assert CATEGORY_PRIOR["debug"] == CATEGORY_PRIOR["performance"] < CATEGORY_PRIOR["code"]

    # One recorded observation replaces the prior outright, in both directions.
    assert _draw_weight("t", "spec", {"t": 1.0}) == pytest.approx(0.1)
    assert _draw_weight("t", "code", {"t": 0.0}) == pytest.approx(1.0)

    new_classes = {"validate-order", "apply-discounts", "fix-pagination", "top-k-fast"}
    drawn = sum(
        1
        for seed in range(1, 80)
        for task in build_tasks(seed, {})
        if task.template_id in new_classes
    )
    plain = sum(
        1
        for seed in range(1, 80)
        for task in build_tasks(seed)
        if task.template_id in new_classes
    )
    assert drawn > plain, (drawn, plain)


def test_an_empty_history_still_weights_the_draw():
    """`{}` means "no history", not "uniform" — on a fresh machine the priors are
    the only thing keeping the run off the tasks everybody solves. `None` stays
    uniform so a seed alone reproduces a run in tests."""
    weighted = [task.template_id for task in build_tasks(4242, {})]
    uniform = [task.template_id for task in build_tasks(4242)]
    assert weighted != uniform


def test_a_run_never_asks_the_same_template_twice():
    for seed in (1, 2, 3, 77, 512):
        for difficulty in (None, {"cron-match": 1.0, "top-k-fast": 0.0}):
            ids = [task.template_id for task in build_tasks(seed, difficulty)]
            assert len(ids) == len(set(ids)), (seed, ids)


def test_difficulty_map_is_the_measured_pass_share():
    items = [
        {"template": "hard", "score": 0.0},
        {"template": "hard", "score": 0.5},
        {"template": "easy", "score": 1.0},
        {"template": "easy", "score": 1.0},
    ]
    assert stats.difficulty_map(items) == {"hard": 0.25, "easy": 1.0}


NEARLY_RIGHT = {
    # Fixes the reported bug but forgets the two documented validations.
    "fix-pagination": "```python\ndef page_count(total, per_page):\n"
    "    if per_page < 1:\n        raise ValueError('per_page')\n"
    "    return -(-total // per_page)\n```",
    # Correct, fast, but ignores the stated `k <= 0` rule.
    "top-k-fast": "```python\nfrom collections import Counter\ndef top_k(items, k):\n"
    "    c = Counter(items)\n"
    "    return [v for v, _ in sorted(c.items(), key=lambda p: (-p[1], p[0]))[:k]]\n```",
}


@pytest.mark.parametrize("template_id", sorted(NEARLY_RIGHT))
def test_the_new_classes_score_between_zero_and_full(template_id):
    """The whole point of the 1.4 task classes: five runs in a row produced only
    0 % and 100 % answers, so partial credit had nothing to resolve and every
    run was a tie. A task must be able to come back nearly-right."""
    task = _task_of(template_id)
    verdict = engine.grade_answer(task, NEARLY_RIGHT[template_id])
    assert not verdict["passed"]
    assert 0.3 < verdict["score"] < 1.0, verdict["score"]


def test_the_unfixed_bug_from_the_task_text_does_not_pass():
    """A debug task whose own broken code scores would measure nothing at all."""
    task = _task_of("fix-insert-point")
    verdict = engine.grade_answer(
        task,
        "```python\ndef insert_point(items, value):\n"
        "    low, high = 0, len(items) - 1\n"
        "    while low < high:\n"
        "        mid = (low + high) // 2\n"
        "        if items[mid] <= value:\n            low = mid + 1\n"
        "        else:\n            high = mid\n    return low\n```",
    )
    assert not verdict["passed"]
    failed = {check["id"] for check in verdict["checks"] if not check["ok"]}
    assert "reported-case" in failed, "the example named in the task must fail"


def test_a_level_suggestion_follows_the_measured_pass_rate():
    assert stats.suggested_level(1.0) == "fast"
    assert stats.suggested_level(0.75) == "normal"
    assert stats.suggested_level(0.2) == "deep"


def test_thin_evidence_never_produces_a_confident_verdict():
    items = [
        {"runId": "r", "arm": "model", "template": "t", "level": "deep", "category": "code",
         "modelLabel": "one", "score": 1.0, "points": 3, "passed": True}
    ]
    row = stats.summarise(items)["templates"][0]
    assert row["discrimination"] is None, "одна точка — не корреляция"
    assert row["advice"] == "more-data"


def test_the_whole_template_pool_is_enumerable():
    """Item statistics report which templates were never drawn; that needs the
    full list, and the ids live inside the builders."""
    from delegator_core.benchmark.templates import TEMPLATES

    known = known_template_ids()
    assert len(known) == sum(len(group) for group in TEMPLATES.values())
    assert set(known.values()) == {"fast", "normal", "deep"}
    assert known["cron-match"] == "deep"
    # Every level must hold at least as many templates as a run draws from it,
    # or `build_tasks` starts handing out the same task twice in one run.
    for level, count in LEVEL_MIX.items():
        assert len(TEMPLATES[level]) >= count, level

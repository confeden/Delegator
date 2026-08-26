"""The mode router decides what Delegator does with a request.

These tests are the contract: every rule here is a decision the IDE agent used
to make from prose, and each one has a live failure behind it (ROADMAP.md).
"""

from __future__ import annotations

import json

from delegator_core import router


CODE_DRAFT = """Вот решение:

```python
def cron_match(expr, minute, hour, day, month, weekday):
    return True
```
"""

TRUNCATED_DRAFT = """Вот решение:

```python
def cron_match(expr, minute, hour, day, month, weekday):
"""


def test_a_draft_with_code_is_reviewed():
    # The one regime where a second pass provably pays: §11 executes the code,
    # so the reviewer's defect is proven rather than argued.
    decision = router.decide("Напиши функцию cron_match(...)", CODE_DRAFT)
    assert decision.mode == router.MODE_IMPROVE
    assert decision.reason == "draft-carries-code"
    assert decision.confidence >= 0.6 and not decision.escalate


def test_a_truncated_draft_is_never_reviewed():
    # An odd fence count means the agent's own answer was cut off. Reviewing
    # half an answer returns a confident rewrite of the surviving half — silent
    # corruption of the thing improve exists to protect.
    decision = router.decide("Напиши функцию", TRUNCATED_DRAFT)
    assert decision.mode == router.MODE_KEEP
    assert decision.reason == "draft-truncated"
    assert decision.confidence == 1.0


def test_a_two_line_answer_is_not_worth_thirty_seconds():
    # 109 of 228 improve calls came back «nothing to fix» after a median 15 s.
    decision = router.decide("Как называется столица Франции?", "Париж.")
    assert decision.mode == router.MODE_KEEP
    assert decision.reason == "draft-trivial"


def test_an_oversized_draft_is_kept_with_a_readable_reason():
    decision = router.decide("Задача", "x" * (router.IMPROVE_DRAFT_BUDGET + 1))
    assert decision.mode == router.MODE_KEEP
    assert decision.reason == "draft-too-long"


def test_without_a_draft_delegator_answers_instead_of_reviewing():
    decision = router.decide("Переведи этот текст на английский: ...")
    assert decision.mode == router.MODE_DELEGATE
    assert decision.reason == "bulk-work"

    code = router.decide("Traceback: KeyError в функции parse_ini, почему падает?")
    assert code.mode == router.MODE_DELEGATE
    assert code.reason == "code-task"


def test_boost_is_reserved_for_long_design_questions():
    # Boost is minutes and three advisors; a short design question is not it.
    short = router.decide("Какую архитектуру выбрать?")
    assert short.mode != router.MODE_BOOST

    long_design = router.decide("Спроектируй архитектуру миграции. " + "Условие. " * 800)
    assert long_design.mode == router.MODE_BOOST
    assert long_design.complexity == "deep"


def test_an_empty_request_decides_nothing():
    assert router.decide("").mode == router.MODE_KEEP
    assert router.decide("   ", "draft").reason == "empty-task"


def test_low_confidence_asks_for_a_second_opinion():
    # `escalate` is a licence, not an order: the tier-1 mode stays the fallback,
    # so a dead fast model costs latency and never correctness.
    prose = router.decide("Объясни разницу между HTTP/2 и HTTP/3", "Короткий ответ. " * 30)
    assert prose.mode == router.MODE_IMPROVE
    assert prose.escalate is (prose.confidence < 0.6)


def test_the_cli_transport_never_raises_and_always_writes_a_decision(tmp_path):
    request = tmp_path / "request.json"
    decision_path = tmp_path / "decision.json"
    request.write_text(
        json.dumps({"task": "Напиши SQL-запрос", "draft": CODE_DRAFT, "contextFiles": 2}),
        encoding="utf-8",
    )
    assert router.maybe_run_as_router(["core.exe", "--route", str(request), str(decision_path)])
    written = json.loads(decision_path.read_text(encoding="utf-8"))
    assert written["mode"] == router.MODE_IMPROVE
    assert written["routerVersion"] == router.ROUTER_VERSION
    assert written["features"]["context_files"] == 2

    # A broken request still produces a usable decision: `delegate` is what
    # Delegator did for every request before the router existed.
    request.write_text("{not json", encoding="utf-8")
    router.route_files(request, decision_path)
    fallback = json.loads(decision_path.read_text(encoding="utf-8"))
    assert fallback["mode"] == router.MODE_DELEGATE
    assert fallback["tier"] == "fallback"
    assert not fallback["escalate"], "a failed router must not send anyone to a model"


def test_the_guard_ignores_every_other_argv():
    assert not router.maybe_run_as_router(["core.exe"])
    assert not router.maybe_run_as_router(["core.exe", "--lint-draft", "a", "b"])
    assert not router.maybe_run_as_router(["core.exe", "--route", "only-one-path"])


def test_a_powershell_written_request_with_a_bom_still_routes(tmp_path):
    # PS 5.1 writes a BOM by default and json.loads refuses one — the same trap
    # that once made the app quarantine its own config.json.
    request = tmp_path / "request.json"
    decision_path = tmp_path / "decision.json"
    request.write_bytes(
        b"\xef\xbb\xbf" + json.dumps({"task": "Напиши функцию parse_ini"}).encode("utf-8")
    )
    router.route_files(request, decision_path)
    written = json.loads(decision_path.read_text(encoding="utf-8"))
    assert written["tier"] == "rules", "a BOM must not fall through to the fallback"
    assert written["mode"] == router.MODE_DELEGATE


def test_a_task_that_describes_the_work_in_prose_is_still_code_work():
    # Measured on the 2026-08-16 run: 12 of 28 decisions fell through to
    # «plain-question» with complexity `fast` — every one of them a benchmark
    # task of exactly this shape. The old hints only matched code at the START
    # of a line, so a specification written in prose looked like small talk.
    for task in (
        "Напиши функцию на Python `chunk(items, size)`, которая делит список на подсписки.",
        "Напиши ОДИН SQL-запрос, который возвращает длину самой длинной серии.",
        "Реализуй класс LruCache с методами get и put.",
        "Write a function that merges overlapping intervals.",
        "Исправь функцию page_count: она возвращает 0 для 10 элементов.",
    ):
        decision = router.decide(task)
        assert decision.reason == "code-task", (task, decision.reason)
        assert decision.complexity in ("normal", "deep"), task
        assert not decision.escalate, "code work is not a coin flip"

    # And small talk is still small talk: the fix must not swallow everything.
    for task in ("Как дела?", "Объясни, чем HTTP/2 отличается от HTTP/3."):
        assert router.decide(task).reason == "plain-question", task


# ── Caller strength (router 1.1) ─────────────────────────────────────────────
# One rule: return an answer at least as good as the CALLER would have written,
# at no token cost to the caller. A weak caller gets quality it cannot reach; a
# strong one gets its tokens back without losing anything.

WEAK = dict(caller_dpr=110, best_dpr=156)     # Flash at low effort vs our Opus-class
STRONG = dict(caller_dpr=156, best_dpr=110)   # Opus asking, and we own nothing near it
LEVEL = dict(caller_dpr=150, best_dpr=152)    # inside CALLER_MARGIN


def test_an_undeclared_caller_routes_exactly_as_before():
    # The whole point of defaulting to 0: an agent that never learned to declare
    # itself must not be routed differently by an upgrade.
    plain = router.decide("Напиши функцию merge_intervals(items).")
    assert plain.callerTier == router.CALLER_TIER_UNKNOWN
    assert plain.mode == router.MODE_DELEGATE and plain.reason == "code-task"
    assert plain.modelReview is True
    # Half-declared is still undeclared: one number cannot produce a comparison.
    assert router.decide("x", caller_dpr=156).callerTier == router.CALLER_TIER_UNKNOWN
    assert router.decide("x", best_dpr=156).callerTier == router.CALLER_TIER_UNKNOWN


def test_a_weak_caller_gets_the_swarm_instead_of_one_model():
    task = "Напиши функцию на Python, которая разбирает cron-выражение и проверяет совпадение. " * 6
    base = router.decide(task)
    assert base.mode == router.MODE_DELEGATE
    assert len(task) >= router.AMPLIFY_TASK_CHARS
    lifted = router.decide(task, **WEAK)
    assert lifted.callerTier == router.CALLER_TIER_AMPLIFY
    assert lifted.mode == router.MODE_BOOST
    assert lifted.reason.endswith("+amplify-caller")

    # ...but a one-liner is not worth three advisors and a judge: a single model
    # at 156 already buries a caller at 110, and the swarm only costs minutes.
    short = router.decide("Как отсортировать список по ключу?", **WEAK)
    assert short.mode == router.MODE_DELEGATE


def test_a_weak_caller_gets_its_thin_draft_reviewed_after_all():
    # "Not worth thirty seconds" was measured against a caller of unknown
    # strength. Against a weak one the draft IS the weakest thing in the request.
    task = "Как отсортировать список словарей по ключу?"
    draft = "Используй sorted(items, key=...)."
    assert router.decide(task, draft).mode == router.MODE_KEEP
    lifted = router.decide(task, draft, **WEAK)
    assert lifted.mode == router.MODE_IMPROVE
    assert lifted.reason == "draft-trivial+amplify-caller"


def test_a_strong_caller_is_never_handed_a_worse_answer():
    # Opus asks, the best we can reach is 110. Answering outright would return
    # something worse than the caller would have written — the one outcome
    # delegation must never produce.
    task = "Напиши функцию merge_intervals(items), сливающую пересекающиеся интервалы."
    assert router.decide(task).mode == router.MODE_DELEGATE
    guarded = router.decide(task, **STRONG)
    assert guarded.callerTier == router.CALLER_TIER_GUARD
    assert guarded.mode == router.MODE_KEEP
    assert guarded.reason == "code-task+caller-stronger"
    assert not guarded.escalate, "a fast model must not overrule the quality guard"


def test_a_strong_caller_still_gets_the_mechanical_check():
    # `improve` survives the guard, stripped to §11: the checker COMPILES the
    # draft, so its defects are facts and need no model opinion (G34).
    guarded = router.decide("Напиши cron_match(...)", CODE_DRAFT, **STRONG)
    assert guarded.mode == router.MODE_IMPROVE
    assert guarded.reason == "draft-carries-code+mechanical-only"
    assert guarded.modelReview is False


def test_a_level_caller_changes_nothing():
    task = "Напиши функцию merge_intervals(items), сливающую пересекающиеся интервалы."
    base = router.decide(task)
    level = router.decide(task, **LEVEL)
    assert level.callerTier == router.CALLER_TIER_MATCH
    assert (level.mode, level.reason) == (base.mode, base.reason)
    assert level.modelReview is True


def test_the_damage_guards_outrank_every_strength_comparison():
    # A truncated draft is half an answer; reviewing it returns a confident
    # rewrite of the surviving half. No caller comparison may unlock that.
    for kwargs in (WEAK, STRONG, LEVEL):
        assert router.decide("t", TRUNCATED_DRAFT, **kwargs).mode == router.MODE_KEEP
        assert router.decide("", "", **kwargs).mode == router.MODE_KEEP
        big = router.decide("t", "x" * (router.IMPROVE_DRAFT_BUDGET + 1), **kwargs)
        assert big.mode == router.MODE_KEEP and big.reason == "draft-too-long"


def test_the_tier_boundary_is_the_margin_and_nothing_else():
    m = router.CALLER_MARGIN
    both = dict(caller_confidence="measured", best_confidence="measured")
    assert router.caller_tier(100, 100 + m, **both) == router.CALLER_TIER_AMPLIFY
    assert router.caller_tier(100, 100 + m - 1, **both) == router.CALLER_TIER_MATCH
    assert router.caller_tier(100, 100 - m, **both) == router.CALLER_TIER_GUARD
    assert router.caller_tier(100, 100 - m + 1, **both) == router.CALLER_TIER_MATCH
    assert router.caller_tier(0, 0) == router.CALLER_TIER_UNKNOWN


def test_a_single_source_rating_buys_a_wider_band_not_a_lower_score():
    # 154 of the 196 shipped rows rest on one source. `gemini-3.7-flash` is one
    # of them: 152 from the coding index alone, five days after launch, with no
    # SWE-Verified figure beside it — while `claude-sonnet-5` scores 143 from two
    # benchmarks that agree. Published head-to-heads call the pair a TIE, so the
    # nine-point gap is our arithmetic, not their difference.
    flash, sonnet = 152, 143
    confirmed = dict(caller_confidence="measured", best_confidence="measured")
    provisional = dict(caller_confidence="provisional", best_confidence="measured")

    # Taken at face value the tie reads as "the caller is clearly stronger", and
    # Delegator would refuse to answer at all.
    assert router.caller_tier(flash, sonnet, **confirmed) == router.CALLER_TIER_GUARD
    # With the wider band it reads as what it is: level.
    assert router.caller_tier(flash, sonnet, **provisional) == router.CALLER_TIER_MATCH

    # The score itself is untouched — the band moved, not the number. A real gap
    # still registers, so the effort penalty (§13.2) keeps working.
    assert router.caller_tier(127, 156, **provisional) == router.CALLER_TIER_AMPLIFY
    assert router.decide("t", caller_dpr=flash, best_dpr=sonnet, **provisional).callerDpr == flash


def test_an_unconfirmed_pair_defaults_to_the_wider_band():
    # Absent confidence is not "confirmed". Anything short of two agreeing
    # sources on BOTH sides gets the cautious margin.
    for kwargs in (
        {},
        dict(caller_confidence="measured"),
        dict(best_confidence="measured"),
        dict(caller_confidence="provisional", best_confidence="provisional"),
    ):
        assert router.caller_margin(**kwargs) == router.CALLER_MARGIN_PROVISIONAL
    assert router.caller_margin("measured", "measured") == router.CALLER_MARGIN


def test_the_decision_carries_the_numbers_that_produced_it(tmp_path):
    # router-decisions.jsonl has to be replayable: a tier without its inputs is
    # an assertion, not evidence.
    request = tmp_path / "req.json"
    out = tmp_path / "out.json"
    request.write_text(
        json.dumps({"task": "Напиши функцию foo(x).", "callerDpr": 110, "bestDpr": 156}),
        encoding="utf-8",
    )
    router.route_files(request, out)
    written = json.loads(out.read_text(encoding="utf-8"))
    assert written["callerTier"] == router.CALLER_TIER_AMPLIFY
    assert written["callerDpr"] == 110 and written["bestDpr"] == 156
    assert written["routerVersion"] == "1.1"


def test_the_verb_and_the_noun_are_almost_never_adjacent():
    # Measured live on 2026-08-23: four of seven natural phrasings missed, and a
    # miss is not harmless — «plain-question» carries complexity `fast`, so real
    # code work went to a flash-class model. The gap the hint allows is exactly
    # one language name, nothing wider.
    for task in (
        "Напиши на Python функцию merge_intervals(items), которая сливает интервалы.",
        "Напиши на TypeScript хук useDebounce.",
        "Сделай на Python скрипт, который читает CSV и пишет JSON.",
        "Создай компонент карточки товара.",
        "Write a Python function that merges overlapping intervals.",
    ):
        assert router.decide(task).reason == "code-task", task

    # And the reason the gap is one language name and not a wildcard: with
    # `\w+\s+` there instead, this becomes code work because "класса" matches.
    for task in (
        "Напиши краткое резюме этого класса задач.",
        "Составь план поездки в Прагу.",
        "Объясни, чем HTTP/2 отличается от HTTP/3.",
    ):
        assert router.decide(task).reason == "plain-question", task

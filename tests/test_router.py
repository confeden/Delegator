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

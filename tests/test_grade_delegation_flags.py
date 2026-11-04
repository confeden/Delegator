import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "coding-bench")))

import grade_run  # noqa: E402


def test_a_delegator_run_with_no_answer_is_flagged():
    stats = {"calls": 3, "ok": 0, "failed_attempts": 3}
    flags = grade_run.delegation_flags(stats)
    assert flags == ["delegation: no request was answered (3 failed attempts)"]


def test_a_run_that_never_called_delegator_is_flagged():
    flags = grade_run.delegation_flags({"calls": 0, "ok": 0, "failed_attempts": 0})
    assert flags == ["delegation: Delegator was never called in this run"]


def test_an_answered_run_or_a_native_run_is_not_flagged():
    assert grade_run.delegation_flags({"calls": 2, "ok": 1, "failed_attempts": 5}) == []
    assert grade_run.delegation_flags(None) == []


def test_web_answers_name_their_models(tmp_path):
    metrics = tmp_path / "metrics.jsonl"
    rows = [
        {"ts": "2026-11-04T12:26:36", "stage": "web", "status": "ok", "model": "Gemini 4 Argon"},
        {"ts": "2026-11-04T12:30:40", "stage": "web", "status": "ok", "model": "Gemini 4 Argon"},
        {"ts": "2026-11-04T12:31:00", "stage": "web", "status": "failed", "model": ""},
        {"ts": "2026-11-04T11:00:00", "stage": "web", "status": "ok", "model": "before the run"},
    ]
    metrics.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
    meta = {"mode": "delegator", "started": "2026-11-04T12:23:54", "finished": "2026-11-04T12:52:15",
            "usage_file": "", "metrics_file": str(metrics)}
    stats = grade_run.delegation_stats(meta)
    assert stats["web_calls"] == 2
    assert stats["models"] == {"Gemini 4 Argon": 2}

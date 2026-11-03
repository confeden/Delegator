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

import os
import subprocess
import sys
import types

import pytest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "coding-bench")))

import start  # noqa: E402


def _fake_run(returncode, stdout=b"", stderr=b""):
    def run(*args, **kwargs):
        return types.SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)
    return run


@pytest.fixture
def script_present(monkeypatch):
    monkeypatch.setattr(start.os.path, "exists", lambda path: True)


def test_an_answer_with_exit_zero_passes(monkeypatch, script_present):
    monkeypatch.setattr(subprocess, "run", _fake_run(0, stdout=b"ok\n"))
    ok, detail = start.delegator_answers()
    assert ok and "answered" in detail


def test_exit_zero_with_no_text_does_not_pass(monkeypatch, script_present):
    monkeypatch.setattr(subprocess, "run", _fake_run(0, stdout=b"  \n"))
    assert start.delegator_answers()[0] is False


def test_keep_exit_three_does_not_pass(monkeypatch, script_present):
    monkeypatch.setattr(subprocess, "run", _fake_run(3, stderr=b"[Delegator] keep\n"))
    ok, detail = start.delegator_answers()
    assert not ok and "exit 3" in detail


def test_a_missing_script_does_not_pass(monkeypatch):
    monkeypatch.setattr(start.os.path, "exists", lambda path: False)
    ok, detail = start.delegator_answers()
    assert not ok and "not found" in detail


def test_a_probe_that_times_out_does_not_pass(monkeypatch, script_present):
    def run(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd="ps", timeout=360)
    monkeypatch.setattr(subprocess, "run", run)
    ok, detail = start.delegator_answers()
    assert not ok and "did not finish" in detail

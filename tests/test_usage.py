from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

from delegator_core.usage import build_usage_report


def _record(ts: datetime, **overrides) -> dict:
    base = {
        "ts": ts.isoformat().replace("+00:00", "Z"),
        "requestId": "r-abc",
        "client": "core",
        "stage": "answer",
        "mode": "ask",
        "provider": "gemini",
        "model": "gemini-flash-latest",
        "promptTokens": 100,
        "completionTokens": 50,
        "totalTokens": 150,
        "cost": 0.0,
        "elapsedMs": 1200,
        "ok": True,
    }
    base.update(overrides)
    return base


def test_empty_report_when_file_missing(tmp_path: Path) -> None:
    report = build_usage_report(tmp_path / "usage.jsonl", days=7)
    assert report["today"]["requests"] == 0
    assert report["savedTokensTotal"] == 0
    assert report["daily"] == []
    assert report["byModel"] == []


def test_aggregates_by_model_day_and_saved(tmp_path: Path) -> None:
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    rows = [
        _record(now, requestId="r-1"),
        _record(now, requestId="r-1", stage="advisor", model="opencode/mimo-v2.5-free", provider="opencode-cli", totalTokens=300, promptTokens=200, completionTokens=100),
        _record(now - timedelta(days=1), requestId="r-2", totalTokens=500, promptTokens=400, completionTokens=100),
        "not json at all",
        json.dumps({"ts": "garbage"}),
    ]
    usage_file.write_text(
        "\n".join(json.dumps(row) if isinstance(row, dict) else row for row in rows),
        encoding="utf-8",
    )
    report = build_usage_report(usage_file, days=7)
    # Saved = OUTPUT the caller's own model did not have to generate, so the
    # advisor stage contributes nothing and the input half never counts.
    assert report["savedOutputTokens"] == 50 + 100
    assert report["savedTokensTotal"] == report["savedOutputTokens"]
    # Gross throughput moved off the main model keeps the input side.
    assert report["handledTokens"] == 150 + 500
    # Advisor overhead is real spend even though it replaced nothing.
    assert report["spentTokensTotal"] == 150 + 300 + 500
    assert report["delegations"] == 2
    assert report["today"]["requests"] == 1  # one distinct requestId today
    assert report["today"]["totalTokens"] == 450
    models = {row["model"]: row for row in report["byModel"]}
    assert models["gemini-flash-latest"]["totalTokens"] == 650
    assert models["opencode/mimo-v2.5-free"]["totalTokens"] == 300
    assert len(report["daily"]) == 2


def test_benchmark_records_are_excluded_from_every_figure(tmp_path: Path) -> None:
    """A benchmark solves twelve tasks twice on purpose.

    Counting it would inflate BOTH sides of the ledger and make running the
    measurement look like a saving, so it must vanish from every number.
    """
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    rows = [
        _record(now, requestId="real-1"),
        _record(now, requestId="bench-1", bench=True, totalTokens=90_000, promptTokens=40_000, completionTokens=50_000),
        _record(now, requestId="bench-2", bench="true", totalTokens=1_000, promptTokens=600, completionTokens=400),
    ]
    usage_file.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
    report = build_usage_report(usage_file, days=7)
    assert report["savedOutputTokens"] == 50
    assert report["spentTokensTotal"] == 150
    assert report["delegations"] == 1
    assert report["today"]["requests"] == 1
    assert report["byModel"][0]["totalTokens"] == 150
    assert report["benchmarkRecordsExcluded"] == 2


def test_a_failed_call_is_spent_but_never_saved(tmp_path: Path) -> None:
    """Tokens burned on a call that returned nothing saved the caller nothing."""
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    rows = [
        _record(now, requestId="ok-1"),
        _record(now, requestId="bad-1", ok=False, totalTokens=700, promptTokens=700, completionTokens=0),
    ]
    usage_file.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")
    report = build_usage_report(usage_file, days=7)
    assert report["savedOutputTokens"] == 50
    assert report["handledTokens"] == 150
    assert report["spentTokensTotal"] == 850
    assert report["delegations"] == 1


def test_the_cut_off_hides_old_records_from_the_counter_but_not_from_the_log(
    tmp_path: Path,
) -> None:
    """0.7 resets the COUNTER, not the log.

    The first design renamed `usage.jsonl` aside, which also destroyed the
    latency history `Get-ModelHealth` reads from it — every model then looked
    untested and the strength floor burned 92 s timing out on the strongest id
    it could find. A cut-off keeps the router's samples and still starts the
    user-facing numbers at zero.
    """
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    rows = [
        _record(now - timedelta(days=2), requestId="old-1", totalTokens=9_000, completionTokens=4_000),
        _record(now, requestId="new-1"),
    ]
    usage_file.write_text("\n".join(json.dumps(row) for row in rows), encoding="utf-8")

    # Without a cut-off both records count.
    report = build_usage_report(usage_file, days=7)
    assert report["savedOutputTokens"] == 4_050
    assert report["delegations"] == 2

    cut_off = (now - timedelta(days=1)).isoformat().replace("+00:00", "Z")
    (tmp_path / "usage-counted-from.txt").write_text(cut_off, encoding="utf-8")

    report = build_usage_report(usage_file, days=7)
    assert report["savedOutputTokens"] == 50, "the pre-cut-off line must not count"
    assert report["delegations"] == 1
    # The log itself is untouched, which is the entire point.
    assert usage_file.read_text(encoding="utf-8").count("old-1") == 1


def test_a_cut_off_older_than_the_window_does_not_widen_it(tmp_path: Path) -> None:
    """`days=N` still means N days; the cut-off may only narrow the window."""
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    usage_file.write_text(
        json.dumps(_record(now - timedelta(days=5), requestId="old")), encoding="utf-8"
    )
    (tmp_path / "usage-counted-from.txt").write_text(
        (now - timedelta(days=30)).isoformat().replace("+00:00", "Z"), encoding="utf-8"
    )
    assert build_usage_report(usage_file, days=1)["delegations"] == 0
    assert build_usage_report(usage_file, days=7)["delegations"] == 1


def test_improve_counts_as_saved_work(tmp_path: Path) -> None:
    """`improve` returns a corrected answer the caller did not have to write."""
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    usage_file.write_text(
        json.dumps(_record(now, stage="improve", mode="improve", completionTokens=420, totalTokens=1420, promptTokens=1000)),
        encoding="utf-8",
    )
    report = build_usage_report(usage_file, days=7)
    assert report["savedOutputTokens"] == 420
    assert report["handledTokens"] == 1420


def test_records_without_request_id_count_individually(tmp_path: Path) -> None:
    now = datetime.now(timezone.utc)
    usage_file = tmp_path / "usage.jsonl"
    usage_file.write_text(
        "\n".join(
            json.dumps(_record(now, requestId="", totalTokens=10)) for _ in range(3)
        ),
        encoding="utf-8",
    )
    report = build_usage_report(usage_file, days=1)
    assert report["today"]["requests"] == 3

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
    # Advisor overhead counts in totals but not in saved tokens.
    assert report["savedTokensTotal"] == 150 + 500
    assert report["today"]["requests"] == 1  # one distinct requestId today
    assert report["today"]["totalTokens"] == 450
    models = {row["model"]: row for row in report["byModel"]}
    assert models["gemini-flash-latest"]["totalTokens"] == 650
    assert models["opencode/mimo-v2.5-free"]["totalTokens"] == 300
    assert len(report["daily"]) == 2


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

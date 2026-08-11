from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# Stages that represent user-facing delegated work (tokens the expensive IDE model
# did not have to spend). Internal overhead stages (triage, advisor, synthesis)
# count toward totals but not toward "saved".
SAVED_STAGES = {"answer", "micro", "verify", "plan", "parallel"}


def _parse_ts(value: str | None) -> datetime | None:
    raw = (value or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _as_int(value) -> int:
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _as_float(value) -> float:
    try:
        return float(value or 0.0)
    except (TypeError, ValueError):
        return 0.0


def iter_usage_records(usage_file: Path, *, since: datetime) -> list[dict[str, Any]]:
    if not usage_file.exists():
        return []
    records: list[dict[str, Any]] = []
    try:
        lines = usage_file.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(record, dict):
            continue
        ts = _parse_ts(record.get("ts"))
        if ts is None or ts < since:
            continue
        record["_ts"] = ts
        records.append(record)
    return records


def build_usage_report(usage_file: Path, *, days: int = 7) -> dict[str, Any]:
    days = max(1, min(int(days or 7), 90))
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=days)
    today_key = now.date().isoformat()
    records = iter_usage_records(usage_file, since=since)

    def _bucket() -> dict[str, Any]:
        return {
            "requests": 0,
            "promptTokens": 0,
            "completionTokens": 0,
            "totalTokens": 0,
            "cost": 0.0,
        }

    today = _bucket()
    today_by_provider: dict[str, dict[str, Any]] = defaultdict(_bucket)
    today_by_client: dict[str, dict[str, Any]] = defaultdict(_bucket)
    daily: dict[str, dict[str, Any]] = defaultdict(_bucket)
    by_model: dict[tuple[str, str], dict[str, Any]] = defaultdict(_bucket)
    request_ids_by_day: dict[str, set[str]] = defaultdict(set)
    request_ids_today: set[str] = set()
    saved_tokens_total = 0

    for record in records:
        ts: datetime = record["_ts"]
        day_key = ts.date().isoformat()
        provider = str(record.get("provider") or "unknown")
        client = str(record.get("client") or "cli")
        model = str(record.get("model") or "unknown")
        stage = str(record.get("stage") or "answer")
        request_id = str(record.get("requestId") or "")
        prompt_tokens = _as_int(record.get("promptTokens"))
        completion_tokens = _as_int(record.get("completionTokens"))
        total_tokens = _as_int(record.get("totalTokens"))
        if not total_tokens:
            total_tokens = prompt_tokens + completion_tokens
        cost = _as_float(record.get("cost"))

        def _add(bucket: dict[str, Any]) -> None:
            bucket["promptTokens"] += prompt_tokens
            bucket["completionTokens"] += completion_tokens
            bucket["totalTokens"] += total_tokens
            bucket["cost"] += cost

        _add(daily[day_key])
        if request_id:
            request_ids_by_day[day_key].add(request_id)
        else:
            daily[day_key]["requests"] += 1
        model_bucket = by_model[(model, provider)]
        _add(model_bucket)
        model_bucket["requests"] += 1
        if stage in SAVED_STAGES:
            saved_tokens_total += total_tokens
        if day_key == today_key:
            _add(today)
            if request_id:
                request_ids_today.add(request_id)
            else:
                today["requests"] += 1
            _add(today_by_provider[provider])
            today_by_provider[provider]["requests"] += 1
            _add(today_by_client[client])
            today_by_client[client]["requests"] += 1

    for day_key, ids in request_ids_by_day.items():
        daily[day_key]["requests"] += len(ids)
    today["requests"] += len(request_ids_today)

    daily_rows = [
        {"date": day_key, **bucket}
        for day_key, bucket in sorted(daily.items())
    ]
    model_rows = sorted(
        (
            {"model": model, "provider": provider, **bucket}
            for (model, provider), bucket in by_model.items()
        ),
        key=lambda row: row["totalTokens"],
        reverse=True,
    )
    return {
        "days": days,
        "today": {
            **today,
            "byProvider": dict(today_by_provider),
            "byClient": dict(today_by_client),
        },
        "daily": daily_rows,
        "byModel": model_rows,
        "savedTokensTotal": saved_tokens_total,
    }

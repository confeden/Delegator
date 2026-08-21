from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

# Stages that produced something the IDE's own model would otherwise have had to
# produce. Internal overhead stages (triage, advisor, synthesis, extract) are
# real spend but replace nothing, so they count toward totals and never toward
# "saved".
SAVED_STAGES = {"answer", "micro", "verify", "plan", "parallel", "improve"}


def _as_bool(value) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "1", "yes"}
    return bool(value)


def is_benchmark_record(record: dict[str, Any]) -> bool:
    """A benchmark run must never reach any figure this module reports.

    It deliberately solves twelve tasks twice, so counting it would inflate
    "spent" by the price of the measurement and "saved" by work the user never
    asked for -- the counter would end up rewarding running the benchmark.
    `benchmark.ps1` marks these records via `<RT>\\benchmark-active.json`; records
    written before 0.7 carry no flag at all and are simply not benchmarks as far
    as this function can tell, which is why 0.7 resets the log.
    """
    return _as_bool(record.get("bench"))


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


COUNT_FROM_FILE = "usage-counted-from.txt"


def read_counted_from(runtime_home: Path) -> datetime | None:
    """Timestamp before which records exist but must not be COUNTED.

    0.7 changes what «сэкономлено» means, and pre-0.7 lines carry no `bench`
    flag, so mixing them into the new figures would produce one number with two
    meanings. The first design deleted the log to solve that — and took the
    health history with it, because `Get-ModelHealth` reads the very same file
    to learn which models are slow. Wiping it left every model looking untested,
    so the strength floor reached for the strongest one it had and spent 92 s
    timing out on it.

    A cut-off line keeps both consumers whole: the counter starts at zero, the
    router keeps every latency sample it had.
    """
    marker = runtime_home / COUNT_FROM_FILE
    try:
        raw = marker.read_text(encoding="utf-8-sig").strip()
    except OSError:
        return None
    return _parse_ts(raw)


def build_usage_report(usage_file: Path, *, days: int = 7) -> dict[str, Any]:
    days = max(1, min(int(days or 7), 90))
    now = datetime.now(timezone.utc)
    since = now - timedelta(days=days)
    counted_from = read_counted_from(usage_file.parent)
    if counted_from is not None and counted_from > since:
        since = counted_from
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
    spent_tokens_total = 0
    saved_output_tokens = 0
    handled_tokens = 0
    delegation_ids: set[str] = set()
    benchmark_records = 0

    for record in records:
        if is_benchmark_record(record):
            benchmark_records += 1
            continue
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
        spent_tokens_total += total_tokens

        # What the delegation actually saved the caller. A failed call saved
        # nothing (its tokens still count as spent), and an internal stage
        # replaces no work at all.
        ok = record.get("ok")
        succeeded = True if ok is None else _as_bool(ok)
        if stage in SAVED_STAGES and succeeded:
            # The conservative, defensible figure: OUTPUT the IDE's model did
            # not have to generate. It still pays to read the answer back, but
            # generation is the constrained resource, so this is the saving.
            saved_output_tokens += completion_tokens
            # Gross: everything the free model chewed through instead -- input
            # context included, which is where a long -ContextFile pays off.
            handled_tokens += total_tokens
            if request_id:
                delegation_ids.add(request_id)
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
        # Headline: output tokens the IDE's own model never had to generate.
        # `savedTokensTotal` keeps the old key so an older GUI still renders,
        # but it now carries this honest number instead of gross throughput.
        "savedTokensTotal": saved_output_tokens,
        "savedOutputTokens": saved_output_tokens,
        # Everything the free models processed in place of the main model,
        # input context included.
        "handledTokens": handled_tokens,
        # Everything Delegator's own models burned, overhead and failures too.
        "spentTokensTotal": spent_tokens_total,
        "delegations": len(delegation_ids),
        # Reported so the number is auditable: a run that looks low right after
        # a benchmark should show why.
        "benchmarkRecordsExcluded": benchmark_records,
    }

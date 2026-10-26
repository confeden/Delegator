import asyncio
import json
import time

import pytest

from delegator_core.providers import puter_web
from delegator_core.providers.puter_web import (
    DEFAULT_PUTER_MODEL,
    PuterWebBridge,
    puter_web_choice,
    puter_web_flags,
)


def test_flags_follow_config(tmp_path, monkeypatch):
    cfg = tmp_path / "config.json"
    monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(cfg))
    assert puter_web_flags() == (False, True)  # no file
    cfg.write_text(json.dumps({"puter_web_enabled": True, "delegator_enabled": False}), encoding="utf-8-sig")
    assert puter_web_flags() == (True, False)


def test_choice_defaults_to_claude_opus_5_5(tmp_path, monkeypatch):
    cfg = tmp_path / "config.json"
    monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(cfg))
    assert puter_web_choice() == DEFAULT_PUTER_MODEL == "claude-opus-5-5"  # no file
    cfg.write_text(json.dumps({"puter_web_model": "claude-sonnet-5-5"}), encoding="utf-8")
    assert puter_web_choice() == "claude-sonnet-5-5"
    cfg.write_text(json.dumps({"puter_web_model": "bad model; rm -rf"}), encoding="utf-8")
    assert puter_web_choice() == "claude-opus-5-5"


def test_request_refused_while_switched_off(monkeypatch):
    monkeypatch.setattr(puter_web, "puter_web_flags", lambda: (False, True))
    with pytest.raises(RuntimeError, match="Puter Web выключен"):
        asyncio.run(PuterWebBridge().request(text="hi", model="claude-opus-5-5", mode="delegate"))


def test_request_refused_without_extension(monkeypatch):
    monkeypatch.setattr(puter_web, "puter_web_flags", lambda: (True, True))
    with pytest.raises(RuntimeError, match="не подключено"):
        asyncio.run(PuterWebBridge().request(text="hi", model="claude-opus-5-5", mode="delegate"))


def test_answer_round_trip_through_the_queue(monkeypatch):
    monkeypatch.setattr(puter_web, "puter_web_flags", lambda: (True, True))

    async def scenario():
        bridge = PuterWebBridge()
        bridge._last_seen = time.monotonic()  # the extension is polling
        task = asyncio.create_task(
            bridge.request(text="hello", model="claude-opus-5-5", mode="delegate", timeout_sec=60)
        )
        job = await bridge.next_request(timeout_sec=2)
        assert job is not None and job["text"] == "hello" and job["model"] == "claude-opus-5-5"
        assert bridge.has_demand()
        assert bridge.resolve(job["request_id"], text="ответ по-русски")
        result = await task
        assert result.text == "ответ по-русски"
        assert result.usage.provider == "Puter Web"
        assert result.usage.model == "claude-opus-5-5"
        assert bridge.last["model"] == "claude-opus-5-5"

    asyncio.run(scenario())


def test_page_error_is_raised_to_the_caller(monkeypatch):
    monkeypatch.setattr(puter_web, "puter_web_flags", lambda: (True, True))

    async def scenario():
        bridge = PuterWebBridge()
        bridge._last_seen = time.monotonic()
        task = asyncio.create_task(bridge.request(text="x", model="claude-opus-5-5", mode="delegate", timeout_sec=60))
        job = await bridge.next_request(timeout_sec=2)
        bridge.resolve(job["request_id"], error="Вы не вошли в Puter в этом Chrome")
        with pytest.raises(RuntimeError, match="не вошли в Puter"):
            await task

    asyncio.run(scenario())


def test_empty_reply_is_asked_once_more(monkeypatch):
    bridge = PuterWebBridge()
    calls = []

    async def fake_once(**kwargs):
        calls.append(kwargs["text"])
        if len(calls) == 1:
            raise RuntimeError("Puter вернул пустой ответ.")
        return "ok"

    monkeypatch.setattr(bridge, "_ask_once", fake_once)
    result = asyncio.run(bridge.request(text="x", model="claude-opus-5-5", mode="delegate"))
    assert result == "ok" and len(calls) == 2


def test_second_empty_reply_is_raised(monkeypatch):
    bridge = PuterWebBridge()

    async def always_empty(**kwargs):
        raise RuntimeError("Puter вернул пустой ответ.")

    monkeypatch.setattr(bridge, "_ask_once", always_empty)
    with pytest.raises(RuntimeError, match="пустой ответ"):
        asyncio.run(bridge.request(text="x", model="claude-opus-5-5", mode="delegate"))


def test_other_errors_are_not_retried(monkeypatch):
    bridge = PuterWebBridge()
    calls = []

    async def not_signed_in(**kwargs):
        calls.append(1)
        raise RuntimeError("Вы не вошли в Puter")

    monkeypatch.setattr(bridge, "_ask_once", not_signed_in)
    with pytest.raises(RuntimeError, match="не вошли"):
        asyncio.run(bridge.request(text="x", model="claude-opus-5-5", mode="delegate"))
    assert len(calls) == 1


def test_resolve_unknown_request_is_refused():
    assert PuterWebBridge().resolve("nope", text="x") is False

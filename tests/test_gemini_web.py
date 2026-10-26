import json

from delegator_core.providers.gemini_web import gemini_web_flags


def test_flags_follow_config(tmp_path, monkeypatch):
    cfg = tmp_path / "config.json"
    monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(cfg))
    assert gemini_web_flags() == (False, True)  # no file
    cfg.write_text(json.dumps({"gemini_web_enabled": True, "delegator_enabled": False}), encoding="utf-8-sig")
    assert gemini_web_flags() == (True, False)
    cfg.write_text("{}", encoding="utf-8")
    assert gemini_web_flags() == (False, True)


def test_choice_defaults_to_best_model_and_highest_reasoning(tmp_path, monkeypatch):
    from delegator_core.providers.gemini_web import gemini_web_choice

    cfg = tmp_path / "config.json"
    monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(cfg))
    assert gemini_web_choice() == ("gemini-web/best", "best")  # no file
    cfg.write_text(json.dumps({"gemini_web_model": "argon", "gemini_web_reasoning": "high"}), encoding="utf-8")
    assert gemini_web_choice() == ("gemini-web/argon", "high")
    cfg.write_text(json.dumps({"gemini_web_model": "bogus", "gemini_web_reasoning": "x"}), encoding="utf-8")
    assert gemini_web_choice() == ("gemini-web/best", "best")


def test_answer_reports_the_model_the_page_really_used():
    import asyncio

    from delegator_core.providers.gemini_web import GeminiWebBridge

    async def scenario():
        bridge = GeminiWebBridge()
        bridge._last_seen = __import__("time").monotonic()
        from unittest import mock

        with mock.patch("delegator_core.providers.gemini_web.gemini_web_flags", return_value=(True, True)):
            task = asyncio.create_task(
                bridge.request(text="hi", model="gemini-web/best", reasoning="best", mode="delegate")
            )
            request = await bridge.next_request(timeout_sec=2)
            assert request["model"] == "gemini-web/best"
            assert bridge.resolve(request["request_id"], text="ok", used="Argon 4 Â· High")
            return await task

    result = asyncio.run(scenario())
    assert result.usage.model == "Argon 4 Â· High"


def _bridge_with(script):
    """A bridge whose single-attempt call replays `script`: model id -> text or RuntimeError."""
    import time
    from unittest import mock

    from delegator_core.providers import gemini_web as gw

    bridge = gw.GeminiWebBridge()
    asked = []

    async def once(*, text, model, reasoning, mode, timeout_sec=300):
        asked.append(model)
        outcome = script[model.split("/", 1)[1]]
        if isinstance(outcome, Exception):
            raise outcome
        return gw.ProviderResult(provider="Gemini Web", mode=mode, text=outcome, stderr="", exit_code=0,
                                 usage=gw.ProviderUsage(model=model, provider="Gemini Web"))

    bridge._request_once = once
    return bridge, asked, time


def test_spent_quota_moves_down_the_ladder_and_the_model_rests():
    import asyncio

    quota = RuntimeError("QUOTA[Argon · Высокая]: лимит исчерпан")
    bridge, asked, _ = _bridge_with({"best": quota, "argon": quota, "3.8-flash": "flash answer", "3.1-pro": "pro"})

    async def run():
        first = await bridge.request(text="t", model="gemini-web/best", reasoning="best", mode="delegate")
        second = await bridge.request(text="t", model="gemini-web/best", reasoning="best", mode="delegate")
        return first, second

    first, second = asyncio.run(run())
    assert first.text == second.text == "flash answer"
    # best + argon were refused once; the second request goes straight to Flash 3.8
    assert asked == ["gemini-web/best", "gemini-web/3.8-flash", "gemini-web/3.8-flash"]
    assert set(bridge.exhausted_now()) == {"best", "argon"}


def test_every_model_spent_raises_and_other_errors_do_not_fall_back():
    import asyncio

    import pytest

    quota = RuntimeError("QUOTA[x]: limit reached")
    bridge, asked, _ = _bridge_with({"argon": quota, "3.8-flash": quota, "3.1-pro": quota, "3.5-flash-lite": quota})
    with pytest.raises(RuntimeError, match="Ни одна модель"):
        asyncio.run(bridge.request(text="t", model="gemini-web/argon", reasoning="high", mode="delegate"))
    assert len(asked) == 4

    other, asked2, _ = _bridge_with({"argon": RuntimeError("Не найдено поле запроса. Убедитесь, что Gemini открыт"), "3.8-flash": "no"})
    with pytest.raises(RuntimeError, match="Не найдено поле"):
        asyncio.run(other.request(text="t", model="gemini-web/argon", reasoning="high", mode="delegate"))
    assert asked2 == ["gemini-web/argon"]


def test_a_model_missing_from_the_menu_counts_as_unavailable():
    import asyncio

    gone = RuntimeError("В меню Gemini нет модели gemini-web/argon. Сейчас доступно: Flash")
    bridge, asked, _ = _bridge_with({"argon": gone, "3.8-flash": "ok"})
    result = asyncio.run(bridge.request(text="t", model="gemini-web/argon", reasoning="high", mode="delegate"))
    assert result.text == "ok" and asked == ["gemini-web/argon", "gemini-web/3.8-flash"]


def test_a_frozen_model_is_retried_once_then_replaced():
    import asyncio

    from delegator_core.providers import gemini_web as gw

    calls = {"argon": 0}
    frozen = RuntimeError("SLOW[Argon · Средний]: без признаков работы 120 с")

    class Script(dict):
        pass

    bridge, asked, _ = _bridge_with({"best": frozen, "argon": frozen, "3.8-flash": "flash"})
    result = asyncio.run(bridge.request(text="t", model="gemini-web/best", reasoning="medium", mode="delegate"))
    assert result.text == "flash"
    # "best" is tried, retried once (a frozen model gets a second chance), then the ladder moves on.
    assert asked == ["gemini-web/best", "gemini-web/best", "gemini-web/3.8-flash"]
    assert 0 < bridge.exhausted_now()["argon"] <= gw.SLOW_COOLDOWN_SEC
    assert [f["kind"] for f in bridge.failures] == ["slow", "slow"]


def test_a_frozen_model_that_recovers_on_the_retry_is_not_demoted():
    import asyncio

    state = {"n": 0}
    from delegator_core.providers import gemini_web as gw

    bridge = gw.GeminiWebBridge()

    async def once(*, text, model, reasoning, mode, timeout_sec=300):
        state["n"] += 1
        if state["n"] == 1:
            raise RuntimeError("SLOW[Argon]: без признаков работы 120 с")
        return gw.ProviderResult(provider="Gemini Web", mode=mode, text="late", stderr="", exit_code=0,
                                 usage=gw.ProviderUsage(model=model, provider="Gemini Web"))

    bridge._request_once = once
    result = asyncio.run(bridge.request(text="t", model="gemini-web/argon", reasoning="medium", mode="delegate"))
    assert result.text == "late" and bridge.exhausted_now() == {}


def test_the_whole_ladder_shares_one_budget():
    import asyncio

    import pytest

    bridge, asked, _ = _bridge_with({"argon": RuntimeError("SLOW[Argon]: x")})
    with pytest.raises(RuntimeError):
        asyncio.run(bridge.request(text="t", model="gemini-web/argon", reasoning="medium", mode="delegate", timeout_sec=10))
    assert asked == []  # under 20 s left: nothing is started that cannot finish


def test_tab_demand_follows_requests_and_lingers():
    from delegator_core.providers.gemini_web import GeminiWebBridge

    bridge = GeminiWebBridge()
    assert not bridge.has_demand()
    bridge._pending["r1"] = object()
    assert bridge.has_demand()
    bridge._pending.clear()
    assert not bridge.has_demand()
    bridge.resolve("r1")  # a finished request keeps the tab for the linger window
    assert bridge.has_demand()
    bridge._busy_until = 0.0
    assert not bridge.has_demand()

import asyncio
import json

import pytest

from delegator_core.providers import ProviderResult, ProviderUsage, web_doors
from delegator_core.providers.web_doors import (
    DOOR_BY_ID,
    DOORS,
    DoorBridge,
    WebDoors,
    hedge_delay_sec,
    is_foreign_request,
)


def result(door_id: str) -> ProviderResult:
    return ProviderResult(
        provider=door_id, mode="delegate", text=f"answer from {door_id}", stderr="", exit_code=0,
        usage=ProviderUsage(model=door_id, provider=door_id),
    )


def scripted(script: dict[str, tuple[float, str | None]], started: list[str] | None = None):
    """Each door answers after its delay, or fails with the given error text."""

    async def ask(door, _timeout_sec: float) -> ProviderResult:
        if started is not None:
            started.append(door.id)
        delay, error = script[door.id]
        await asyncio.sleep(delay)
        if error:
            raise RuntimeError(error)
        return result(door.id)

    return ask


def doors(*ids: str):
    return [DOOR_BY_ID[door_id] for door_id in ids]


@pytest.fixture
def config(monkeypatch, tmp_path):
    def write(**flags):
        path = tmp_path / "config.json"
        path.write_text(json.dumps(flags), encoding="utf-8")
        monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(path))

    return write


def test_the_order_is_strength_first_and_gemini_leads():
    assert DOORS[0].id == "gemini"
    strengths = [door.strength for door in DOORS]
    assert strengths == sorted(strengths, reverse=True)
    assert "puter" not in DOOR_BY_ID


def test_a_long_prompt_is_given_longer_before_it_looks_late():
    assert hedge_delay_sec("x") < hedge_delay_sec("x" * 5000) < hedge_delay_sec("x" * 50000)


def test_a_fast_leader_never_wakes_the_second_door():
    started: list[str] = []
    race = WebDoors().race(
        scripted({"kimi": (0.01, None), "zai": (0.01, None)}, started), doors("kimi", "zai"),
        hedge_after=5, timeout_sec=10,
    )
    answer = asyncio.run(race)
    assert answer.door.id == "kimi"
    assert started == ["kimi"]


def test_a_slow_leader_is_hedged_and_the_faster_door_answers(monkeypatch):
    monkeypatch.setattr(web_doors, "WINNER_GRACE_SEC", 0.05)
    started: list[str] = []
    race = WebDoors().race(
        scripted({"kimi": (5, None), "zai": (0.02, None)}, started), doors("kimi", "zai"),
        hedge_after=0.05, timeout_sec=10,
    )
    answer = asyncio.run(asyncio.wait_for(race, 8))
    assert started == ["kimi", "zai"]
    assert answer.door.id == "zai"


def test_a_clearly_stronger_door_about_to_finish_beats_a_weak_one_that_finished_first(monkeypatch):
    monkeypatch.setattr(web_doors, "WINNER_GRACE_SEC", 1.0)
    race = WebDoors().race(
        scripted({"kimi": (0.15, None), "rudder": (0.01, None)}), doors("kimi", "rudder"),
        hedge_after=0.01, timeout_sec=5,
    )
    assert asyncio.run(race).door.id == "kimi"


def test_nothing_waits_for_a_door_of_the_same_tier(monkeypatch):
    monkeypatch.setattr(web_doors, "WINNER_GRACE_SEC", 5.0)
    race = WebDoors().race(
        scripted({"gemini": (3, None), "kimi": (0.01, None)}), doors("gemini", "kimi"),
        hedge_after=0.01, timeout_sec=5,
    )
    answer = asyncio.run(asyncio.wait_for(race, 1))
    assert answer.door.id == "kimi"


def test_the_fastest_of_the_top_tier_leads_and_weaker_doors_keep_their_place(config):
    config(gemini_web_enabled=True, kimi_web_enabled=True, zai_web_enabled=True, deepseek_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    hub._note_success(DOOR_BY_ID["gemini"], 60)
    hub._note_success(DOOR_BY_ID["kimi"], 32)
    hub._note_success(DOOR_BY_ID["zai"], 20)
    hub._note_success(DOOR_BY_ID["deepseek"], 5)  # the fastest of all, but clearly weaker
    assert [door.id for door in hub.ready_doors()] == ["zai", "kimi", "gemini", "deepseek"]


def test_a_new_door_gets_its_turn_ahead_of_a_slow_one(config):
    config(gemini_web_enabled=True, kimi_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    hub._note_success(DOOR_BY_ID["gemini"], 60)
    assert [door.id for door in hub.ready_doors()] == ["kimi", "gemini"]


def test_a_failed_door_hands_over_at_once_without_waiting_for_the_hedge():
    started: list[str] = []
    race = WebDoors().race(
        scripted({"kimi": (0.01, "boom"), "zai": (0.01, None)}, started), doors("kimi", "zai"),
        hedge_after=100, timeout_sec=5,
    )
    answer = asyncio.run(asyncio.wait_for(race, 3))
    assert answer.door.id == "zai"
    assert answer.errors == ["Kimi: boom"]


def test_all_failed_is_an_error_that_names_each_door():
    race = WebDoors().race(
        scripted({"kimi": (0, "one"), "zai": (0, "two")}), doors("kimi", "zai"), hedge_after=5, timeout_sec=5,
    )
    with pytest.raises(RuntimeError, match="Kimi: one .*Z.ai: two"):
        asyncio.run(race)


def test_the_losing_door_is_cancelled():
    cancelled: list[str] = []

    async def ask(door, _timeout):
        try:
            await asyncio.sleep(0.01 if door.id == "kimi" else 30)
        except asyncio.CancelledError:
            cancelled.append(door.id)
            raise
        return result(door.id)

    async def run():
        answer = await WebDoors().race(ask, doors("kimi", "zai"), hedge_after=0.001, timeout_sec=5)
        await asyncio.sleep(0.01)
        return answer

    assert asyncio.run(run()).door.id == "kimi"
    assert cancelled in ([], ["zai"])  # zai may never have started; if it did, it must not keep running


def test_failures_rest_the_door_by_kind(tmp_path):
    hub = WebDoors(tmp_path / "doors.json")
    hub._note_failure(DOOR_BY_ID["kimi"], "LOGIN: сайт просит войти.")
    hub._note_failure(DOOR_BY_ID["zai"], "QUOTA: limit reached")
    hub._note_failure(DOOR_BY_ID["qwen"], "SLOW: нет признаков жизни")
    hub._note_failure(DOOR_BY_ID["deepseek"], "что-то ещё")
    assert hub.status["kimi"].auth == "signed_out"
    resting = [hub.status[d].resting_for() for d in ("zai", "qwen", "deepseek")]
    assert resting[0] > resting[1] > resting[2] > 0


def test_a_success_clears_the_rest_and_proves_the_session(tmp_path):
    hub = WebDoors(tmp_path / "doors.json")
    hub._note_failure(DOOR_BY_ID["zai"], "QUOTA: limit reached")
    hub._note_success(DOOR_BY_ID["zai"], 3.2)
    assert hub.status["zai"].resting_for() == 0
    assert hub.status["zai"].auth == "signed_in"
    assert hub.status["zai"].last_seconds == 3.2


def test_ready_skips_off_signed_out_and_resting_doors(config):
    config(gemini_web_enabled=True, kimi_web_enabled=True, zai_web_enabled=True, qwen_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    hub.report_auth("kimi", "signed_out")
    hub.status["zai"].rest("quota", 1000)
    assert {door.id for door in hub.ready_doors()} == {"gemini", "qwen"}


def test_a_signed_out_door_gets_another_try_once_its_rest_is_over(config):
    """A sign-in in an ordinary tab, or a false alarm, must not switch a door off for good."""
    config(kimi_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    hub._note_failure(DOOR_BY_ID["kimi"], "LOGIN: x")
    assert hub.ready_doors() == []
    hub.status["kimi"].rest_until = 0
    assert [door.id for door in hub.ready_doors()] == ["kimi"]


def test_nothing_ready_still_tries_the_strongest_resting_door_but_never_a_signed_out_one(config):
    config(kimi_web_enabled=True, zai_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    hub.report_auth("kimi", "signed_out")
    hub.status["zai"].rest("quota", 1000)
    assert [door.id for door in hub.ready_doors()] == ["zai"]


def test_a_door_without_the_extension_is_not_ready(config):
    config(gemini_web_enabled=True, kimi_web_enabled=True)
    # Gemini reports its own connection through its bridge; the others need this extension's polls.
    assert [door.id for door in WebDoors().ready_doors()] == ["gemini"]


def test_attachments_go_to_gemini_only(config):
    config(gemini_web_enabled=True, kimi_web_enabled=True)
    hub = WebDoors()
    hub.touch()
    assert [door.id for door in hub.ready_doors(files=True)] == ["gemini"]
    config(kimi_web_enabled=True)
    assert hub.ready_doors(files=True) == []


def test_sign_in_state_survives_a_restart_but_a_login_in_progress_does_not(tmp_path):
    path = tmp_path / "doors.json"
    hub = WebDoors(path)
    hub.report_auth("kimi", "signed_in", "me")
    hub.status["zai"].auth = "checking"
    hub.save()
    again = WebDoors(path)
    assert again.status["kimi"].auth == "signed_in"
    assert again.status["kimi"].auth_label == "me"
    assert again.status["zai"].auth == "unknown"


def test_confirming_a_sign_in_lifts_a_login_rest_only(tmp_path):
    hub = WebDoors(tmp_path / "doors.json")
    hub._note_failure(DOOR_BY_ID["kimi"], "LOGIN: x")
    hub._note_failure(DOOR_BY_ID["zai"], "QUOTA: x")
    hub.report_auth("kimi", "signed_in")
    hub.report_auth("zai", "signed_in")
    assert hub.status["kimi"].resting_for() == 0
    assert hub.status["zai"].resting_for() > 0


def test_a_login_request_reaches_the_extension_once(config):
    config()

    async def run():
        hub = WebDoors()
        assert hub.request_login("qwen") is False  # nothing has called in yet
        assert hub.status["qwen"].auth == "unknown"
        assert hub.login_requests == set()  # it must not steal the focus hours later
        hub.touch()
        assert hub.request_login("qwen") is True
        assert hub.status["qwen"].auth == "checking"
        first = await hub.wait_change([], timeout_sec=1)
        second = await hub.wait_change([], timeout_sec=0.1)
        return first, second, hub.is_connected()

    first, second, connected = asyncio.run(run())
    assert first["login"] == ["qwen"]
    assert second["login"] == []
    assert connected is True


def test_a_turn_nobody_waits_for_is_not_handed_to_the_tab():
    async def run():
        bridge = DoorBridge(DOOR_BY_ID["kimi"])
        task = asyncio.create_task(bridge.request(text="dead", mode="delegate", timeout_sec=30))
        await asyncio.sleep(0.01)
        task.cancel()
        await asyncio.gather(task, return_exceptions=True)
        return bridge.take_turns()

    assert asyncio.run(run()) == []


def test_a_bridge_round_trip_reports_the_model_the_page_showed():
    async def run():
        bridge = DoorBridge(DOOR_BY_ID["zai"])
        task = asyncio.create_task(bridge.request(text="q", mode="delegate", timeout_sec=30))
        await asyncio.sleep(0.01)
        turn = bridge.take_turns()[0]
        assert bridge.is_live(turn["request_id"])
        assert bridge.resolve(turn["request_id"], text=" a ", used="GLM-5.3")
        answer = await task
        assert not bridge.is_live(turn["request_id"])
        return answer

    answer = asyncio.run(run())
    assert answer.text == "a"
    assert answer.usage.model == "GLM-5.3"


def test_an_error_from_the_page_is_raised_as_it_is():
    async def run():
        bridge = DoorBridge(DOOR_BY_ID["zai"])
        task = asyncio.create_task(bridge.request(text="q", mode="delegate", timeout_sec=30))
        await asyncio.sleep(0.01)
        turn = bridge.take_turns()[0]
        bridge.resolve(turn["request_id"], error="QUOTA: limit")
        return await task

    with pytest.raises(RuntimeError, match="QUOTA"):
        asyncio.run(run())


def test_every_door_travels_on_one_poll_and_a_turn_wakes_it_at_once(config):
    """Chrome allows six connections to a host: a poll per door starved the last of them."""
    config(kimi_web_enabled=True, zai_web_enabled=True, qwen_web_enabled=True)

    async def run():
        hub = WebDoors()
        hub.touch()
        asks = [
            asyncio.create_task(hub.bridges[door_id].request(text=door_id, mode="delegate", timeout_sec=30))
            for door_id in ("kimi", "zai", "qwen")
        ]
        await asyncio.sleep(0.01)
        reply = await asyncio.wait_for(hub.wait_change([], timeout_sec=20), timeout=2)
        for ask in asks:
            ask.cancel()
        await asyncio.gather(*asks, return_exceptions=True)
        return reply

    reply = asyncio.run(run())
    assert sorted(turn["door"] for turn in reply["turns"]) == ["kimi", "qwen", "zai"]
    assert {turn["door"]: turn["text"] for turn in reply["turns"]}["zai"] == "zai"


def test_only_the_local_runtime_gui_and_extension_may_reach_the_queues():
    # The runtime and the GUI send neither header.
    assert not is_foreign_request("127.0.0.1:1380", "", "")
    assert not is_foreign_request("127.0.0.1:1380", "chrome-extension://abc", "none")
    # A page's fetch, with no-cors or not, and a DNS-rebound name.
    assert is_foreign_request("127.0.0.1:1380", "", "cross-site")
    assert is_foreign_request("127.0.0.1:1380", "https://evil.example", "cross-site")
    assert is_foreign_request("evil.example:1380", "", "")

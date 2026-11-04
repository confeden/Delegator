"""The web doors: signed-in chat tabs Delegator hands a turn to, and the race between them.

Gemini keeps its own bridge (`gemini_web.py`: model ladder, attachments). Everything else here
is one generic `DoorBridge` per site, driven by `extensions/gemini-web-bridge/door.js`.

The order is strength first (`scripts/model-ratings.json`), but doors within `TIER_MARGIN` of the
strongest ready one are one tier, the same margin the router calls "not a real difference", and the
fastest of that tier leads. Measured: Argon 60 s against 20-30 s for the same question on doors a few
points below it. When the leader runs late the next door starts alongside it, and the first good
answer wins. Only an answer from a clearly weaker door waits a short grace for a stronger one still
running, because a few seconds are cheaper than a weaker answer.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import re
import time
import uuid
from collections.abc import Awaitable, Callable
from pathlib import Path

from .base import ProviderResult, ProviderUsage
from .gemini_web import QUOTA_COOLDOWN_SEC, UNAVAILABLE_COOLDOWN_SEC, _config_payload, model_ladder


@dataclasses.dataclass(frozen=True)
class Door:
    id: str
    label: str
    url: str
    config_flag: str
    strength: int  # the DPR of the model the door aims for


GEMINI = Door("gemini", "Gemini", "https://gemini.google.com/app", "gemini_web_enabled", 156)
# Strength order. Gemini leads by the owner's rule D16, the rest by their DPR row.
DOORS: tuple[Door, ...] = (
    GEMINI,
    # The same Google account as Gemini with quotas of its own, so it can answer when Gemini is spent.
    # Its default was Gemini 4 Argon when checked, Gemini's own top model, so it shares Gemini's tier.
    Door("aistudio", "AI Studio", "https://aistudio.google.com/prompts/new_chat", "aistudio_web_enabled", 156),
    Door("zai", "Z.ai", "https://chat.z.ai/", "zai_web_enabled", 150),
    Door("qwen", "Qwen", "https://chat.qwen.ai/", "qwen_web_enabled", 144),
    Door("deepseek", "DeepSeek", "https://chat.deepseek.com/", "deepseek_web_enabled", 138),
    # A free account gets Instant only: K3.1 Pro and K2.8 answered with a subscription dialog. No DPR row
    # for Instant, so this places it after the rated doors, not at K3's 152.
    Door("kimi", "Kimi", "https://www.kimi.ai/", "kimi_web_enabled", 110),
    # Hy4 preview has no row in the table yet: `unrated` = 100 (§9.1), so it goes after the rated doors.
    Door("tencent", "Tencent Hy", "https://aistudio.tencent.ai/", "tencent_web_enabled", 100),
    # Picks its own model per request, so it has no rating of its own: `unrated` = 100 (§9.1). Last in
    # the order, and worth having for that: the site promises unlimited free chat.
    Door("rudder", "Rudder", "https://rudder.chat/chat", "rudder_web_enabled", 100),
)
DOOR_BY_ID = {door.id: door for door in DOORS}
SHARED_MODEL_DOORS = {"gemini", "aistudio"}  # one «Модель» + «Рассуждение» on «Интеграция → Web»

TURN_ACK_SEC = 8.0  # the extension's next poll starts at once, so this is generous
TAB_LINGER_SEC = 300  # a reopened tab costs 10-20 s of page load; a parked one costs nothing
MAX_WAIT_SEC = 360
QUOTA_REST_SEC = 3 * 3600
SLOW_REST_SEC = 20 * 60
ERROR_REST_SEC = 5 * 60
LOGIN_REST_SEC = 30 * 60
WINNER_GRACE_SEC = 15  # how long a clearly weaker door's answer waits for a stronger door still running
TIER_MARGIN = 8  # DPR points that mean nothing: `CALLER_MARGIN` in router.py, for the same reason
UNKNOWN_LATENCY_SEC = 30.0  # a door with no history yet: about what the doors measured, so it gets its turn
MAX_CONCURRENT_DOORS = 2  # a third door starts only when one of the two has failed
AUTH_STATES = {"unknown", "checking", "signed_in", "signed_out"}


def hedge_delay_sec(text: str) -> float:
    """How long the leader runs alone. A long prompt thinks longer before it looks late."""
    size = len(text or "")
    if size <= 2_000:
        return 25.0
    if size <= 12_000:
        return 50.0
    return 90.0


def classify_door_error(message: str) -> str:
    """`login` | `quota` | `slow` | `` for an error text coming back from a door."""
    text = message or ""
    if text.startswith("LOGIN"):
        return "login"
    if text.startswith("UNAVAILABLE"):
        return "unavailable"
    if text.startswith("QUOTA"):
        return "quota"
    if text.startswith("SLOW") or "не ответил вовремя" in text:
        return "slow"
    return ""


def shipped_extension_version(delegate_cmd: str) -> str:
    """The version of the extension on disk next to the runtime. Chrome keeps running the old code of
    an unpacked extension after an update, so the extension compares itself with this and reloads."""
    try:
        manifest = Path(delegate_cmd).resolve().parent.parent / "extensions" / "gemini-web-bridge" / "manifest.json"
        return str(json.loads(manifest.read_text(encoding="utf-8-sig")).get("version") or "")
    except (OSError, ValueError):
        return ""


def is_foreign_request(host: str, origin: str, fetch_site: str) -> bool:
    """True for a request that did not come from this machine's own runtime, GUI or extension.

    The queues hold the user's prompts on a loopback port any page in any browser can reach. A page's
    `fetch` would empty them, and DNS rebinding would read them."""
    if (host or "").split(":")[0].lower() not in ("127.0.0.1", "localhost", "testserver"):
        return True
    if (origin or "").startswith("chrome-extension://"):
        return False
    return (fetch_site or "").lower() in ("cross-site", "same-site")


def door_enabled(door: Door, payload: dict | None = None) -> bool:
    return bool((payload if payload is not None else _config_payload()).get(door.config_flag, False))


class DoorStatus:
    """What the core knows about one door: sign-in, rest, the last run. Survives a core restart."""

    def __init__(self) -> None:
        self.auth = "unknown"
        self.auth_label = ""
        self.auth_at = 0.0
        self.rest_until = 0.0  # wall clock, so it is still true after a restart
        self.rest_reason = ""
        self.last_error = ""
        self.last_seconds = 0.0
        self.last_at = 0.0
        self.avg_seconds = 0.0  # moving average of answer times: it orders a tier
        self.phase = ""  # the last step the page reported; memory only, it means nothing after a restart

    def resting_for(self) -> int:
        return max(0, int(self.rest_until - time.time()))

    def rest(self, reason: str, seconds: float) -> None:
        self.rest_until = time.time() + seconds
        self.rest_reason = reason

    def clear_rest(self) -> None:
        self.rest_until = 0.0
        self.rest_reason = ""

    def to_dict(self) -> dict:
        return {
            "auth": self.auth, "auth_label": self.auth_label, "auth_at": self.auth_at,
            "rest_until": self.rest_until, "rest_reason": self.rest_reason,
            "last_error": self.last_error, "last_seconds": self.last_seconds, "last_at": self.last_at,
            "avg_seconds": self.avg_seconds,
        }

    @classmethod
    def from_dict(cls, raw: dict) -> "DoorStatus":
        status = cls()
        if isinstance(raw, dict):
            auth = str(raw.get("auth") or "unknown")
            # "checking" belonged to a login tab that is gone with the old core.
            status.auth = auth if auth in AUTH_STATES and auth != "checking" else "unknown"
            status.auth_label = str(raw.get("auth_label") or "")
            status.auth_at = float(raw.get("auth_at") or 0)
            status.rest_until = float(raw.get("rest_until") or 0)
            status.rest_reason = str(raw.get("rest_reason") or "")
            status.last_error = str(raw.get("last_error") or "")
            status.last_seconds = float(raw.get("last_seconds") or 0)
            status.last_at = float(raw.get("last_at") or 0)
            status.avg_seconds = float(raw.get("avg_seconds") or 0)
        return status


class DoorBridge:
    """One site's queue: the core hands a turn over, the extension's tab answers it."""

    def __init__(self, door: Door) -> None:
        self.door = door
        self._requests: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self._pending: dict[str, asyncio.Future[tuple[str, str | None, str]]] = {}
        self._busy_until = 0.0
        self._taken: dict[str, tuple[dict[str, object], float]] = {}

    def has_demand(self) -> bool:
        return bool(self._pending) or not self._requests.empty() or time.monotonic() < self._busy_until

    def is_live(self, request_id: str) -> bool:
        return request_id in self._pending

    def has_pending(self) -> bool:
        return bool(self._pending) or not self._requests.empty()

    def has_queued(self) -> bool:
        return not self._requests.empty()

    async def request(
        self,
        *,
        text: str,
        mode: str,
        timeout_sec: float = 300,
        debug: bool = False,
        model: str = "",
        reasoning: str = "",
    ) -> ProviderResult:
        request_id = uuid.uuid4().hex
        wait_sec = min(timeout_sec, MAX_WAIT_SEC)
        loop = asyncio.get_running_loop()
        future: asyncio.Future[tuple[str, str | None, str]] = loop.create_future()
        self._pending[request_id] = future
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        # The page gives up a little before the race does, so its error (which says what the page shows)
        # gets back in time.
        await self._requests.put({"request_id": request_id, "text": text, "max_wait_ms": int((wait_sec - 8) * 1000), "debug": debug,
                                   "model": model, "reasoning": reasoning})
        try:
            answer, error, used = await asyncio.wait_for(future, timeout=wait_sec + 25)
        except TimeoutError as exc:
            raise RuntimeError(f"{self.door.label} не ответил вовремя.") from exc
        finally:
            self._pending.pop(request_id, None)
        if error:
            raise RuntimeError(error)
        if not answer.strip():
            raise RuntimeError(f"{self.door.label} вернул пустой ответ.")
        return ProviderResult(
            provider=f"{self.door.label} Web",
            mode=mode,
            text=answer.strip(),
            stderr="",
            exit_code=0,
            usage=ProviderUsage(model=used or self.door.label, provider=f"{self.door.label} Web"),
        )

    def take_turns(self) -> list[dict[str, object]]:
        """Everything queued, minus turns nobody waits for any more (the race ended before the tab took them)."""
        turns = []
        while not self._requests.empty():
            request = self._requests.get_nowait()
            if str(request["request_id"]) in self._pending:
                turns.append(request)
                self._taken[str(request["request_id"])] = (request, time.monotonic())
        return turns

    def acknowledge(self, request_ids: list[str]) -> None:
        for request_id in request_ids:
            self._taken.pop(request_id, None)

    def requeue_unacknowledged(self, max_age_sec: float = TURN_ACK_SEC) -> None:
        """A long-poll reply can vanish (Chrome closed, the extension reloaded) and the turn with it. The
        extension acknowledges on its next poll, and a turn it never acknowledged goes out once more."""
        now = time.monotonic()
        for request_id, (request, taken_at) in list(self._taken.items()):
            if now - taken_at < max_age_sec:
                continue
            del self._taken[request_id]
            if request_id in self._pending and not request.get("resent"):
                self._requests.put_nowait({**request, "resent": True})

    def resolve(self, request_id: str, *, text: str = "", error: str | None = None, used: str = "") -> bool:
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        future = self._pending.get(request_id)
        if future is None or future.done():
            return False
        future.set_result((text, error, used))
        return True


Asker = Callable[[Door, float], Awaitable[ProviderResult]]


@dataclasses.dataclass
class WebAnswer:
    result: ProviderResult
    door: Door
    seconds: float
    errors: list[str]


class WebDoors:
    """All doors together: their bridges, what we know about each, and the race."""

    def __init__(self, state_file: Path | None = None, extension_version: str = "") -> None:
        self.extension_version = extension_version
        self.bridges = {door.id: DoorBridge(door) for door in DOORS if door.id != GEMINI.id}
        self.status = {door.id: DoorStatus() for door in DOORS}
        self.login_requests: set[str] = set()
        self.studio_spent: dict[str, float] = {}
        self._state_file = state_file
        self._last_seen = 0.0
        self._load()

    def _load(self) -> None:
        if not self._state_file:
            return
        try:
            raw = json.loads(self._state_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return
        for door_id, entry in (raw if isinstance(raw, dict) else {}).items():
            if door_id in self.status:
                self.status[door_id] = DoorStatus.from_dict(entry)

    def save(self) -> None:
        if not self._state_file:
            return
        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            payload = {door_id: status.to_dict() for door_id, status in self.status.items()}
            self._state_file.write_text(json.dumps(payload), encoding="utf-8")
        except OSError:
            pass  # the state is a convenience: a lost write costs one failed try, nothing more

    def touch(self) -> None:
        self._last_seen = time.monotonic()

    def is_connected(self, max_age_sec: float = 45) -> bool:
        return time.monotonic() - self._last_seen <= max_age_sec

    def seen_age(self) -> float | None:
        """Seconds since the extension last called in; None when it has not since the core started."""
        return round(time.monotonic() - self._last_seen, 1) if self._last_seen else None

    def wanted(self) -> list[str]:
        payload = _config_payload()
        # A turn in flight keeps its tab whatever the checkbox says: unticking a door stops new work, it
        # does not pull the page out from under an answer, and a door named by hand needs a tab too.
        return [door_id for door_id, bridge in self.bridges.items()
                if bridge.has_pending() or (door_enabled(bridge.door, payload) and bridge.has_demand())]

    async def wait_change(self, known: list[str], timeout_sec: float = 20, ack: list[str] | None = None) -> dict:
        """The extension's one long poll: answers with new turns, a change in wanted tabs, or a login.

        One poll for every door, because Chrome allows six connections to a host and everything to the
        core shares them. A poll per door starved the doors at the back of the queue: their turns sat
        untouched with the tab never told, and each one looked like a site that does not answer."""
        known_set = set(known)
        deadline = time.monotonic() + timeout_sec
        self.touch()
        for bridge in self.bridges.values():
            bridge.acknowledge(ack or [])
        while time.monotonic() < deadline:
            for bridge in self.bridges.values():
                bridge.requeue_unacknowledged()
            if (
                set(self.wanted()) != known_set
                or self.login_requests
                or any(bridge.has_queued() for bridge in self.bridges.values())
            ):
                break
            await asyncio.sleep(0.2)
        self.touch()
        login = sorted(self.login_requests)
        self.login_requests.clear()
        turns = [{"door": door_id, **turn} for door_id, bridge in self.bridges.items() for turn in bridge.take_turns()]
        return {"wanted": self.wanted(), "login": login, "turns": turns, "extension_version": self.extension_version}

    def report_auth(self, door_id: str, state: str, label: str = "") -> None:
        status = self.status[door_id]
        status.auth = state if state in AUTH_STATES else "unknown"
        status.auth_label = label[:80]
        status.auth_at = time.time()
        if state == "signed_in" and status.rest_reason == "login":
            status.clear_rest()
        elif state == "signed_out":
            status.rest("login", LOGIN_REST_SEC)
        self.save()

    def request_login(self, door_id: str) -> bool:
        """Asks the extension to open the door's page in front. False when nothing is listening."""
        # Nothing listening: the GUI opens the site itself, and a queued request would steal the focus
        # hours later, whenever the extension next calls in.
        if not self.is_connected():
            return False
        self.status[door_id].auth = "checking"
        self.status[door_id].auth_at = time.time()
        self.login_requests.add(door_id)
        return True

    def describe(self) -> list[dict]:
        """The GUI's rows, in the order the race uses."""
        payload = _config_payload()
        rows = []
        for door in DOORS:
            status = self.status[door.id]
            rows.append({
                "id": door.id, "label": door.label, "url": door.url, "enabled": door_enabled(door, payload),
                "strength": door.strength, "shares_model": door.id in SHARED_MODEL_DOORS,
                "auth": status.auth, "auth_label": status.auth_label, "auth_at": status.auth_at,
                "resting_sec": status.resting_for(), "rest_reason": status.rest_reason,
                "last_error": status.last_error, "last_seconds": status.last_seconds, "phase": status.phase,
            })
        return rows

    def ready_doors(self, *, files: bool = False, only: list[str] | None = None) -> list[Door]:
        """Enabled doors in strength order, minus any resting or known to be signed out.

        Nothing ready but something enabled: the strongest resting door gets the try anyway, because
        a rest is an estimate and an answer from it beats none. `only` names doors outright, enabled or
        not, for checking one site by hand.

        A signed-out door is skipped only while its rest lasts. A sign-in made in an ordinary tab, or a
        false alarm from a page's own "Sign up" link, must not switch the door off for good."""
        if only:
            return [DOOR_BY_ID[door_id] for door_id in only if door_id in DOOR_BY_ID]
        payload = _config_payload()
        connected = self.is_connected()
        enabled = [door for door in DOORS if door_enabled(door, payload)
                   and (door.id == GEMINI.id or connected)
                   and (not files or door.id == GEMINI.id)]
        ready = [door for door in enabled if self.status[door.id].resting_for() == 0]
        if ready:
            return self._by_tier_then_speed(ready)
        fallback = [door for door in enabled if self.status[door.id].auth != "signed_out"]
        return fallback[:1]

    def _by_tier_then_speed(self, doors: list[Door]) -> list[Door]:
        top = max(door.strength for door in doors)
        tier = [door for door in doors if door.strength >= top - TIER_MARGIN]
        rest = [door for door in doors if door.strength < top - TIER_MARGIN]
        tier.sort(key=lambda door: self.status[door.id].avg_seconds or UNKNOWN_LATENCY_SEC)
        return tier + rest

    def _note_failure(self, door: Door, message: str) -> None:
        status = self.status[door.id]
        status.last_error = message[:1500]
        status.last_at = time.time()
        kind = classify_door_error(message)
        if kind == "login":
            status.auth = "signed_out"
            status.auth_at = time.time()
            status.rest("login", LOGIN_REST_SEC)
        elif kind == "quota":
            status.rest("quota", QUOTA_REST_SEC)
        elif kind == "slow":
            status.rest("slow", SLOW_REST_SEC)
        else:
            status.rest("error", ERROR_REST_SEC)
        self.save()

    def _note_success(self, door: Door, seconds: float) -> None:
        status = self.status[door.id]
        status.last_error = ""
        status.last_seconds = round(seconds, 1)
        status.avg_seconds = round(seconds if not status.avg_seconds else status.avg_seconds * 0.6 + seconds * 0.4, 1)
        status.last_at = time.time()
        status.clear_rest()
        # An answer is the best proof of a session there is: every driver refuses a guest page first.
        if status.auth != "signed_in":
            status.auth = "signed_in"
            status.auth_at = time.time()
        self.save()

    async def ask_studio(
        self,
        *,
        text: str,
        model: str,
        reasoning: str,
        timeout_sec: float,
        no_lite: bool = False,
        debug: bool = False,
    ) -> ProviderResult:
        """AI Studio by the choice it shares with Gemini, and the same way down when a model is spent.

        It meters its models apart from Gemini's page, so a spent model is remembered per door. "best" is
        the top of the ladder here: this page has no menu of its own to rank."""
        ladder = [entry for entry in model_ladder(model, no_lite=no_lite) if entry != "best"]
        now = time.monotonic()
        candidates = [entry for entry in ladder if self.studio_spent.get(entry, 0) <= now] or ladder[-1:]
        deadline = now + timeout_sec
        last_error = ""
        for entry in candidates:
            remaining = deadline - time.monotonic()
            if remaining < 20:
                break
            try:
                return await self.bridges["aistudio"].request(
                    text=text, mode="delegate", timeout_sec=remaining, debug=debug, model=entry, reasoning=reasoning,
                )
            except RuntimeError as exc:
                kind = classify_door_error(str(exc))
                if kind not in ("quota", "unavailable"):
                    raise
                last_error = str(exc)
                rest = QUOTA_COOLDOWN_SEC if kind == "quota" else UNAVAILABLE_COOLDOWN_SEC
                self.studio_spent[entry] = time.monotonic() + rest
        raise RuntimeError(f"QUOTA: ни одна модель AI Studio не ответила. {last_error}"[:1500])

    async def race(self, ask: Asker, doors: list[Door], *, hedge_after: float, timeout_sec: float) -> WebAnswer:
        """The first good answer wins; a stronger door still running gets a short grace."""
        started = time.monotonic()
        deadline = started + timeout_sec
        queue = list(doors)
        running: dict[asyncio.Task[ProviderResult], Door] = {}
        begun: dict[str, float] = {}
        errors: list[str] = []
        winner: tuple[ProviderResult, Door] | None = None
        grace_end = 0.0
        next_hedge = started + hedge_after

        def launch() -> None:
            door = queue.pop(0)
            remaining = max(10.0, deadline - time.monotonic())
            begun[door.id] = time.monotonic()
            running[asyncio.create_task(ask(door, remaining))] = door

        try:
            launch()
            while running or queue:
                now = time.monotonic()
                if now >= deadline or (winner is not None and not running):
                    break
                if not running:
                    launch()
                    continue
                if winner is not None:
                    # Only a door clearly stronger than the current winner is still worth waiting for.
                    stronger = [door for door in running.values() if door.strength > winner[1].strength + TIER_MARGIN]
                    wait_until = min(deadline, grace_end)
                    if not stronger or now >= wait_until:
                        break
                elif queue and len(running) < MAX_CONCURRENT_DOORS:
                    wait_until = min(deadline, next_hedge)
                else:
                    wait_until = deadline
                done, _ = await asyncio.wait(
                    running, timeout=max(0.05, wait_until - now), return_when=asyncio.FIRST_COMPLETED,
                )
                for task in done:
                    door = running.pop(task)
                    try:
                        result = task.result()
                    except asyncio.CancelledError:
                        continue
                    except RuntimeError as exc:
                        errors.append(f"{door.label}: {exc}")
                        self._note_failure(door, str(exc))
                        continue
                    self._note_success(door, time.monotonic() - begun[door.id])
                    if winner is None or door.strength > winner[1].strength + TIER_MARGIN:
                        winner = (result, door)
                        grace_end = time.monotonic() + WINNER_GRACE_SEC
                if winner is None and queue and len(running) < MAX_CONCURRENT_DOORS and time.monotonic() >= next_hedge:
                    launch()
                    next_hedge = time.monotonic() + hedge_after
            if winner is None:
                # A door still running at the deadline has reported no error: its last step is all there is.
                silent = [f"{door.label}: не ответил вовремя, последний шаг: {self.status[door.id].phase or 'нет данных'}"
                          for door in running.values()]
                raise RuntimeError(" | ".join(errors + silent) or "Web: ни одна дверь не ответила вовремя.")
            result, door = winner
            return WebAnswer(result=result, door=door, seconds=round(time.monotonic() - started, 1), errors=errors)
        finally:
            for task in running:
                task.cancel()

    async def panel(self, ask: Asker, doors: list[Door], *, size: int, timeout_sec: float) -> list[WebAnswer]:
        """The same turn to the `size` strongest doors at once, for a task worth two opinions."""
        chosen = doors[:max(1, size)]
        started = time.monotonic()

        async def one(door: Door) -> WebAnswer | None:
            begun = time.monotonic()
            try:
                result = await ask(door, timeout_sec)
            except RuntimeError as exc:
                self._note_failure(door, str(exc))
                return None
            self._note_success(door, time.monotonic() - begun)
            return WebAnswer(result=result, door=door, seconds=round(time.monotonic() - started, 1), errors=[])

        answers = await asyncio.gather(*(one(door) for door in chosen))
        return [answer for answer in answers if answer is not None]


_MODEL_LABEL_RE = re.compile(r"[\r\n\t]+")


def clean_used_label(label: str | None) -> str:
    return _MODEL_LABEL_RE.sub(" ", str(label or "")).strip()[:80]

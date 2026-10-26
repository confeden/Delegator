from __future__ import annotations

import asyncio
import re
import time
import uuid

from .base import ProviderResult, ProviderUsage
from .gemini_web import _config_payload

# Claude Opus 5.5 on Puter. The user pays for it from their own Puter account (User-Pays).
DEFAULT_PUTER_MODEL = "claude-opus-5-5"
_MODEL_RE = re.compile(r"^[A-Za-z0-9._/-]{1,100}$")

# How long the builder tab stays open after the last request, for a follow-up task.
TAB_LINGER_SEC = 60
MAX_WAIT_SEC = 540  # the page-side ceiling; the Core waits a little longer than this


def puter_web_flags() -> tuple[bool, bool]:
    """(«Puter Web» switched on, Delegator not paused), read from the GUI's config.json."""
    payload = _config_payload()
    return bool(payload.get("puter_web_enabled", False)), bool(payload.get("delegator_enabled", True))


def puter_web_choice() -> str:
    """The Puter model id the user picked on «Интеграция → Web»."""
    model = str(_config_payload().get("puter_web_model") or DEFAULT_PUTER_MODEL).strip()
    return model if _MODEL_RE.match(model) else DEFAULT_PUTER_MODEL


class PuterWebBridge:
    """Hands a Delegator chat turn to the user's signed-in builder.puter.com tab.

    The page answers through its own puter.js, so no token ever leaves the browser.
    Unlike the Gemini bridge there is no model ladder: one model, one call."""

    def __init__(self) -> None:
        self._requests: asyncio.Queue[dict[str, str]] = asyncio.Queue()
        self._pending: dict[str, asyncio.Future[tuple[str, str | None]]] = {}
        self._last_seen = 0.0
        self._busy_until = 0.0
        self.last: dict[str, object] = {}

    def is_connected(self, max_age_sec: float = 45) -> bool:
        return time.monotonic() - self._last_seen <= max_age_sec

    def has_demand(self) -> bool:
        """True while a request is queued, in flight, or finished within the linger window."""
        return bool(self._pending) or not self._requests.empty() or time.monotonic() < self._busy_until

    async def request(self, *, text: str, model: str, mode: str, timeout_sec: float = 300) -> ProviderResult:
        """One turn. An empty reply is asked once more: the upstream content filter refuses some
        prompts (`content_filter` / `refusal`, content null) and takes the same prompt on the next
        call - measured 2026-10-26, the same prompt went 4 of 4 empty, then passed on a rerun."""
        try:
            return await self._ask_once(text=text, model=model, mode=mode, timeout_sec=timeout_sec)
        except RuntimeError as exc:
            if "пустой ответ" not in str(exc):
                raise
        return await self._ask_once(text=text, model=model, mode=mode, timeout_sec=timeout_sec)

    async def _ask_once(self, *, text: str, model: str, mode: str, timeout_sec: float = 300) -> ProviderResult:
        if not puter_web_flags()[0]:
            raise RuntimeError("Puter Web выключен. Включите «Puter Web» на вкладке «Интеграция» в Delegator.")
        if not self.is_connected():
            raise RuntimeError(
                "Расширение Delegator Gemini Bridge не подключено (оно же ведёт Puter). "
                "Убедитесь, что Chrome запущен и расширение включено."
            )
        request_id = uuid.uuid4().hex
        started = time.monotonic()
        wait_sec = min(timeout_sec, MAX_WAIT_SEC)
        future: asyncio.Future[tuple[str, str | None]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        await self._requests.put({
            "request_id": request_id,
            "text": text,
            "model": model,
            "max_wait_ms": int(wait_sec * 1000),
        })
        try:
            answer, error = await asyncio.wait_for(future, timeout=wait_sec + 25)
        except TimeoutError as exc:
            raise RuntimeError(
                "Puter Web не ответил вовремя. Проверьте, что вы вошли в Puter в Chrome и расширение включено."
            ) from exc
        finally:
            self._pending.pop(request_id, None)
        if error:
            raise RuntimeError(error)
        if not answer.strip():
            raise RuntimeError("Puter Web вернул пустой ответ.")
        self.last = {"model": model, "seconds": round(time.monotonic() - started, 1), "at": time.time()}
        return ProviderResult(
            provider="Puter Web",
            mode=mode,
            text=answer.strip(),
            stderr="",
            exit_code=0,
            usage=ProviderUsage(model=model, provider="Puter Web"),
        )

    async def wait_demand(self, known: bool, timeout_sec: float = 20) -> bool:
        """Long-poll for the extension: returns once demand differs from `known` (or on timeout)."""
        deadline = time.monotonic() + timeout_sec
        self._last_seen = time.monotonic()
        while time.monotonic() < deadline:
            if self.has_demand() != known:
                break
            await asyncio.sleep(0.5)
        self._last_seen = time.monotonic()
        return self.has_demand()

    async def next_request(self, timeout_sec: float = 20) -> dict[str, str] | None:
        self._last_seen = time.monotonic()
        try:
            return await asyncio.wait_for(self._requests.get(), timeout=timeout_sec)
        except TimeoutError:
            return None
        finally:
            self._last_seen = time.monotonic()

    def resolve(self, request_id: str, *, text: str = "", error: str | None = None) -> bool:
        self._last_seen = time.monotonic()
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        future = self._pending.get(request_id)
        if future is None or future.done():
            return False
        future.set_result((text, error))
        return True

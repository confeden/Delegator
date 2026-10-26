from __future__ import annotations

import asyncio
import dataclasses
import json
import os
import re
import time
import uuid
from pathlib import Path

from .base import ProviderResult, ProviderUsage


def _config_file() -> Path:
    override = os.environ.get("DELEGATOR_CONFIG_FILE")
    if override:
        return Path(override)
    roaming = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
    return Path(roaming) / "Delegator" / "DelegatorWin" / "config" / "config.json"


def _config_payload() -> dict:
    try:
        payload = json.loads(_config_file().read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return {}
    return payload if isinstance(payload, dict) else {}


def gemini_web_flags() -> tuple[bool, bool]:
    """(«Gemini Web» switched on, Delegator not paused), read from the GUI's config.json."""
    payload = _config_payload()
    return bool(payload.get("gemini_web_enabled", False)), bool(payload.get("delegator_enabled", True))


# "best" = the newest model in the page's own menu at its highest reasoning
# level; the extension ranks the rows, so a new Gemini release needs no update.
DEFAULT_WEB_MODEL = "best"
DEFAULT_WEB_REASONING = "best"
_MODEL_IDS = {"best", "argon", "3.1-pro", "3.8-flash", "3.5-flash-lite"}
_REASONING_IDS = {"best", "high", "medium", "low", "auto"}

# When a model's quota is spent the bridge moves on to the next one of THIS list,
# strongest first (Argon, then Flash 3.8, then Pro 3.1, then Flash-Lite). "best"
# comes first and stands for whatever the page's own menu ranks highest.
FALLBACK_ORDER = ("argon", "3.8-flash", "3.1-pro", "3.5-flash-lite")
MAX_ALIVE_WAIT_SEC = 360  # ceiling for a model that keeps showing signs of life
QUOTA_COOLDOWN_SEC = 3 * 3600  # a spent quota resets on a daily scale; retry the strong model after this
SLOW_COOLDOWN_SEC = 20 * 60  # a model that stalled on one prompt is not asked again straight away
UNAVAILABLE_COOLDOWN_SEC = 10 * 60  # a model missing from the menu may come back with the next page load
_LABEL_TO_ID = (
    ("argon", re.compile(r"argon", re.I)),
    ("3.5-flash-lite", re.compile(r"flash[\s-]*lite", re.I)),
    ("3.8-flash", re.compile(r"flash", re.I)),
    ("3.1-pro", re.compile(r"pro", re.I)),
)


def model_id_from_label(label: str) -> str:
    """`Argon · Высокая` -> `argon`; `` when the label names none of ours."""
    for model_id, pattern in _LABEL_TO_ID:
        if pattern.search(label or ""):
            return model_id
    return ""


def classify_failure(message: str) -> str:
    """`quota` | `unavailable` | `` for an error text coming back from the extension."""
    text = message or ""
    if text.startswith("QUOTA"):
        return "quota"
    if text.startswith("SLOW"):
        return "slow"
    if "не ответил вовремя" in text:  # the extension went silent altogether: same as a frozen model
        return "slow"
    if "В меню Gemini нет модели" in text or "Gemini не выбрал модель" in text:
        return "unavailable"
    return ""


def gemini_web_choice() -> tuple[str, str]:
    """(`gemini-web/<model>`, reasoning) the user picked on «Интеграция → Web»."""
    payload = _config_payload()
    model = str(payload.get("gemini_web_model") or DEFAULT_WEB_MODEL).strip().lower()
    reasoning = str(payload.get("gemini_web_reasoning") or DEFAULT_WEB_REASONING).strip().lower()
    if model.startswith("gemini-web/"):
        model = model.split("/", 1)[1]
    if model not in _MODEL_IDS:
        model = DEFAULT_WEB_MODEL
    if reasoning not in _REASONING_IDS:
        reasoning = DEFAULT_WEB_REASONING
    return f"gemini-web/{model}", reasoning


# How long the tab stays open after the last request, for a follow-up task.
TAB_LINGER_SEC = 60


class GeminiWebBridge:
    """Hands a Delegator chat turn to the signed-in Gemini Web browser tab."""

    def __init__(self) -> None:
        self._requests: asyncio.Queue[dict[str, str]] = asyncio.Queue()
        self._pending: dict[str, asyncio.Future[tuple[str, str | None]]] = {}
        self._last_seen = 0.0
        self._busy_until = 0.0
        self._used: dict[str, str] = {}
        self.last: dict[str, object] = {}
        self.phase: dict[str, object] = {}
        self.exhausted: dict[str, float] = {}
        self.failures: list[dict[str, object]] = []

    def is_connected(self, max_age_sec: float = 45) -> bool:
        # The extension long-polls for 20 s and touches `_last_seen` at both ends
        # of every poll, so a live one is never older than ~20 s. 15 s here made
        # the state flap false for a quarter of every poll cycle.
        return time.monotonic() - self._last_seen <= max_age_sec

    def has_demand(self) -> bool:
        """True while a request is queued, in flight, or finished within the linger window.

        The extension keeps the Gemini tab open only while this holds, so an idle
        Delegator leaves no tab behind."""
        return bool(self._pending) or not self._requests.empty() or time.monotonic() < self._busy_until

    def _mark(self, model_id: str, kind: str) -> None:
        if model_id:
            cooldown = {"quota": QUOTA_COOLDOWN_SEC, "slow": SLOW_COOLDOWN_SEC}.get(kind, UNAVAILABLE_COOLDOWN_SEC)
            self.exhausted[model_id] = time.monotonic() + cooldown

    def exhausted_now(self) -> dict[str, int]:
        """Model id -> seconds until it is tried again (empty when none is resting)."""
        now = time.monotonic()
        return {key: int(until - now) for key, until in self.exhausted.items() if until > now}

    async def request(
        self,
        *,
        text: str,
        model: str,
        reasoning: str | None,
        mode: str,
        timeout_sec: float = 300,
    ) -> ProviderResult:
        """One turn, with a way down the model ladder when a model's quota is spent.

        The requested model goes first; when the page reports its quota (or the model
        is not offered any more) the next one of FALLBACK_ORDER is tried, and the
        spent one rests for a while so the following requests do not pay for the
        same refusal again. Any other failure is raised as it is.
        """
        wanted = model.split("/", 1)[1] if model.startswith("gemini-web/") else model
        if wanted == "best":
            ladder = ["best", *FALLBACK_ORDER]
        elif wanted in FALLBACK_ORDER:
            ladder = list(FALLBACK_ORDER[FALLBACK_ORDER.index(wanted):])
        else:
            ladder = [wanted]
        now = time.monotonic()
        resting = {key for key, until in self.exhausted.items() if until > now}
        candidates = [entry for entry in ladder if entry not in resting] or ladder[-1:]
        budget_end = now + timeout_sec  # one budget for the whole ladder, not per model
        last_error: RuntimeError | None = None
        for position, entry in enumerate(candidates):
            # A refusal can reveal that a later candidate is the same spent model
            # ("best" turned out to be Argon): do not ask it again.
            if entry in self.exhausted_now() and position < len(candidates) - 1:
                continue
            tries = 0
            while True:
                remaining = budget_end - time.monotonic()
                if remaining < 20:
                    raise last_error or RuntimeError("Gemini Web: время на запрос вышло до ответа.")
                tries += 1
                try:
                    result = await self._request_once(
                        text=text, model=f"gemini-web/{entry}", reasoning=reasoning, mode=mode,
                        timeout_sec=remaining,
                    )
                except RuntimeError as exc:
                    kind = classify_failure(str(exc))
                    if not kind:
                        raise
                    last_error = exc
                    self.failures.append({"model": entry, "kind": kind, "at": time.time(), "error": str(exc)[:300]})
                    del self.failures[:-20]
                    if kind == "slow" and tries == 1:
                        continue  # a frozen model gets exactly one more try, in a fresh chat
                    label = re.match(r"(?:QUOTA|SLOW)\[([^\]]*)\]", str(exc))
                    self._mark(entry, kind)
                    if label:
                        self._mark(model_id_from_label(label.group(1)), kind)
                    break  # next model
                if last_error is not None:
                    result = dataclasses.replace(result, stderr=f"fallback: {entry} after {last_error}")
                return result
        raise RuntimeError(
            "Ни одна модель Gemini Web не ответила (квота, зависание или недоступна): "
            f"{last_error}. Повторная попытка через {max(self.exhausted_now().values(), default=0) // 60} мин."
        )

    async def _request_once(
        self,
        *,
        text: str,
        model: str,
        reasoning: str | None,
        mode: str,
        timeout_sec: float = 300,
    ) -> ProviderResult:
        if not gemini_web_flags()[0]:
            raise RuntimeError(
                "Gemini Web выключен. Включите «Gemini Web (через Chrome)» на вкладке «Интеграция» в Delegator."
            )
        if not self.is_connected():
            raise RuntimeError(
                "Расширение Gemini Bridge не подключено. Оно открывает Gemini само; "
                "убедитесь, что Chrome запущен и расширение установлено и включено."
            )
        request_id = uuid.uuid4().hex
        started = time.monotonic()
        self.phase = {"phase": "в очереди", "at": time.time()}
        future: asyncio.Future[tuple[str, str | None]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        await self._requests.put({
            "request_id": request_id,
            "text": text,
            "model": model,
            "reasoning": reasoning or "auto",
            # How long the extension may keep waiting for a model that is still alive.
            "max_wait_ms": int(min(timeout_sec, MAX_ALIVE_WAIT_SEC) * 1000),
        })
        try:
            answer, error = await asyncio.wait_for(future, timeout=min(timeout_sec, MAX_ALIVE_WAIT_SEC) + 25)  # the extension reports its own ceiling first
        except TimeoutError as exc:
            step = self.phase.get("phase") or "нет данных"
            raise RuntimeError(
                f"Gemini Web не ответил вовремя (последний шаг расширения: {step}). Проверьте, что "
                "расширение Delegator Gemini Bridge включено и вкладка Gemini открыта в Chrome."
            ) from exc
        finally:
            self._pending.pop(request_id, None)
        used = self._used.pop(request_id, "")
        if error:
            raise RuntimeError(error)
        if not answer.strip():
            raise RuntimeError("Gemini Web вернул пустой ответ.")
        self.last = {
            "model": used or model,
            "requested": model,
            "reasoning": reasoning or "auto",
            "seconds": round(time.monotonic() - started, 1),
            "at": time.time(),
        }
        return ProviderResult(
            provider="Gemini Web",
            mode=mode,
            text=answer.strip(),
            stderr="",
            exit_code=0,
            usage=ProviderUsage(model=used or model, provider="Gemini Web"),
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

    def resolve(self, request_id: str, *, text: str = "", error: str | None = None, used: str | None = None) -> bool:
        # The page was busy until now; count the answer as a sign of life too,
        # so a request that arrives right after is not refused as "not connected".
        self._last_seen = time.monotonic()
        self._busy_until = time.monotonic() + TAB_LINGER_SEC
        future = self._pending.get(request_id)
        if future is None or future.done():
            return False
        if used:
            self._used[request_id] = used
        future.set_result((text, error))
        return True

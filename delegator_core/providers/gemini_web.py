from __future__ import annotations

import asyncio
import json
import os
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


def gemini_web_flags() -> tuple[bool, bool]:
    """(«Gemini Web» switched on, Delegator not paused), read from the GUI's config.json."""
    try:
        payload = json.loads(_config_file().read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return False, True
    return bool(payload.get("gemini_web_enabled", False)), bool(payload.get("delegator_enabled", True))


class GeminiWebBridge:
    """Hands a Delegator chat turn to the signed-in Gemini Web browser tab."""

    def __init__(self) -> None:
        self._requests: asyncio.Queue[dict[str, str]] = asyncio.Queue()
        self._pending: dict[str, asyncio.Future[tuple[str, str | None]]] = {}
        self._last_seen = 0.0

    def is_connected(self, max_age_sec: float = 15) -> bool:
        return time.monotonic() - self._last_seen <= max_age_sec

    async def request(
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
        future: asyncio.Future[tuple[str, str | None]] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        await self._requests.put({
            "request_id": request_id,
            "text": text,
            "model": model,
            "reasoning": reasoning or "auto",
        })
        try:
            answer, error = await asyncio.wait_for(future, timeout=timeout_sec)
        except TimeoutError as exc:
            raise RuntimeError(
                "Gemini Web не ответил за 5 минут. Проверьте, что расширение Delegator Gemini Bridge "
                "включено и вкладка Gemini открыта в Chrome."
            ) from exc
        finally:
            self._pending.pop(request_id, None)
        if error:
            raise RuntimeError(error)
        if not answer.strip():
            raise RuntimeError("Gemini Web вернул пустой ответ.")
        return ProviderResult(
            provider="Gemini Web",
            mode=mode,
            text=answer.strip(),
            stderr="",
            exit_code=0,
            usage=ProviderUsage(model=model, provider="Gemini Web"),
        )

    async def next_request(self, timeout_sec: float = 20) -> dict[str, str] | None:
        self._last_seen = time.monotonic()
        try:
            return await asyncio.wait_for(self._requests.get(), timeout=timeout_sec)
        except TimeoutError:
            return None

    def resolve(self, request_id: str, *, text: str = "", error: str | None = None) -> bool:
        future = self._pending.get(request_id)
        if future is None or future.done():
            return False
        future.set_result((text, error))
        return True

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable


@dataclass(frozen=True)
class ProviderUsage:
    model: str | None = None
    provider: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    cost: float | None = None
    elapsed_ms: int | None = None
    request_id: str | None = None


@dataclass(frozen=True)
class ProviderResult:
    provider: str
    mode: str
    text: str
    stderr: str
    exit_code: int
    usage: ProviderUsage | None = None


StreamCallback = Callable[[str], None]

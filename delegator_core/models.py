from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field


Mode = Literal["micro", "delegate", "boost", "verify"]
Role = Literal["system", "user", "assistant"]
TaskStatus = Literal["queued", "running", "completed", "failed"]


class SessionCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    client: str | None = Field(default=None, max_length=120)


class SessionUpdate(BaseModel):
    title: str = Field(min_length=1, max_length=200)


class SessionRecord(BaseModel):
    id: str
    title: str
    client: str | None = None
    source_kind: str | None = None
    source_id: str | None = None
    source_title: str | None = None
    workspace_root: str | None = None
    workspace_id: str | None = None
    search_text: str | None = None
    created_at: datetime
    updated_at: datetime


class MessageRecord(BaseModel):
    id: str
    session_id: str
    role: Role
    content: str
    provider: str | None = None
    mode: str | None = None
    model: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    cost: float | None = None
    elapsed_ms: int | None = None
    created_at: datetime


class ChatTurnRequest(BaseModel):
    session_id: str
    text: str = Field(min_length=1)
    mode: Mode | None = None
    client: str | None = Field(default=None, max_length=120)
    model: str | None = Field(default=None, max_length=200)
    reasoning: str | None = Field(default=None, max_length=40)


class GeminiWebResultRequest(BaseModel):
    request_id: str = Field(min_length=1, max_length=64)
    text: str = Field(default="", max_length=500_000)
    error: str | None = Field(default=None, max_length=2_000)
    # What the page really had selected when it answered, e.g. "Argon 4 · High".
    used: str | None = Field(default=None, max_length=200)


class WebDoorResultRequest(BaseModel):
    """A web door's answer (or its failure), posted by the extension."""

    request_id: str = Field(min_length=1, max_length=64)
    text: str = Field(default="", max_length=2_000_000)
    error: str | None = Field(default=None, max_length=4000)
    used: str | None = Field(default=None, max_length=200)


class WebDoorAuthRequest(BaseModel):
    """The extension's sign-in report for one door."""

    door: str = Field(min_length=1, max_length=20)
    state: str = Field(min_length=1, max_length=20)
    label: str = Field(default="", max_length=200)


class WebLoginRequest(BaseModel):
    """«Войти» on «Интеграция → Web»."""

    door: str = Field(min_length=1, max_length=20)


class GeminiWebPhaseRequest(BaseModel):
    phase: str = Field(min_length=1, max_length=300)


class WebFile(BaseModel):
    """A file the Gemini upload accepts, carried as base64 (the page attaches it, the bridge never reads it)."""

    name: str = Field(min_length=1, max_length=255)
    mime: str = Field(default="application/octet-stream", max_length=200)
    data_base64: str = Field(min_length=1, max_length=17_000_000)


class WebAskRequest(BaseModel):
    """One delegated turn for the web integration (the IDE runtime's door)."""

    text: str = Field(min_length=1, max_length=500_000)
    files: list[WebFile] = Field(default_factory=list, max_length=10)
    # Empty = whatever «Интеграция → Web» says; otherwise "gemini-web/<id>".
    model: str | None = Field(default=None, max_length=200)
    reasoning: str | None = Field(default=None, max_length=40)
    timeout_sec: float = Field(default=300, ge=10, le=900)
    # A short plain question: Gemini answers it at a lower level when the user left the level on auto.
    light: bool = False
    # Checking one site by hand: only these doors, in this order.
    doors: list[str] | None = Field(default=None, max_length=10)
    # Also return the shape of the answer's markup, for when a site changes it.
    debug: bool = False


class WebPanelRequest(BaseModel):
    """One turn for the strongest web doors at once (boost)."""

    text: str = Field(min_length=1, max_length=500_000)
    size: int = Field(default=2, ge=1, le=4)
    reasoning: str | None = Field(default=None, max_length=40)
    timeout_sec: float = Field(default=240, ge=10, le=900)


class ChatTurnResponse(BaseModel):
    session: SessionRecord
    user_message: MessageRecord
    assistant_message: MessageRecord
    provider: str
    mode: str


class ChatTaskRecord(BaseModel):
    id: str
    session_id: str
    user_message_id: str
    assistant_message_id: str | None = None
    status: TaskStatus
    provider: str | None = None
    mode: str
    error: str | None = None
    model: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    cost: float | None = None
    elapsed_ms: int | None = None
    created_at: datetime
    updated_at: datetime
    completed_at: datetime | None = None


class ChatTurnStartResponse(BaseModel):
    session: SessionRecord
    user_message: MessageRecord
    task: ChatTaskRecord


class ChatTaskEvent(BaseModel):
    task_id: str
    session_id: str
    status: TaskStatus
    provider: str | None = None
    mode: str
    error: str | None = None
    stream_text: str | None = None
    assistant_message: MessageRecord | None = None
    model: str | None = None
    prompt_tokens: int | None = None
    completion_tokens: int | None = None
    total_tokens: int | None = None
    cost: float | None = None
    elapsed_ms: int | None = None


class ImportSessionsResponse(BaseModel):
    source: str
    scanned_files: int
    imported_sessions: int
    updated_sessions: int
    skipped_sessions: int
    imported_session_ids: list[str]


class WorkspacePreferredSessionResponse(BaseModel):
    workspace_id: str
    workspace_root: str | None = None
    session: SessionRecord


class UploadRecord(BaseModel):
    id: str
    name: str
    size: int
    media_type: str | None = None
    kind: str
    local_path: str
    content_url: str


class SessionMemoryRecord(BaseModel):
    session_id: str
    summary: str | None = None
    topic_hints: str | None = None
    source_message_count: int = 0
    updated_at: datetime

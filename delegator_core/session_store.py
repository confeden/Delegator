from __future__ import annotations

import sqlite3
import threading
import uuid
from datetime import datetime, timezone

from .models import ChatTaskRecord, MessageRecord, SessionCreate, SessionMemoryRecord, SessionRecord


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _canonical_timestamp(value: str | None) -> str:
    raw = str(value or "").strip()
    if not raw:
        return ""
    try:
        normalized = raw.replace("Z", "+00:00")
        dt = datetime.fromisoformat(normalized)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt.isoformat()
    except ValueError:
        return raw


class SessionStore:
    def __init__(self, conn: sqlite3.Connection) -> None:
        self.conn = conn
        self._lock = threading.RLock()
        self._search_cache: dict[str, tuple[str, str | None]] = {}

    def get_session_memory(self, session_id: str) -> SessionMemoryRecord | None:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT session_id, summary, topic_hints, source_message_count, updated_at
                FROM session_memory
                WHERE session_id = ?
                """,
                (session_id,),
            ).fetchone()
        if row is None:
            return None
        return SessionMemoryRecord.model_validate(dict(row))

    def upsert_session_memory(
        self,
        session_id: str,
        *,
        summary: str | None,
        topic_hints: str | None,
        source_message_count: int,
    ) -> SessionMemoryRecord:
        now = _now_iso()
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO session_memory (session_id, summary, topic_hints, source_message_count, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    summary = excluded.summary,
                    topic_hints = excluded.topic_hints,
                    source_message_count = excluded.source_message_count,
                    updated_at = excluded.updated_at
                """,
                (session_id, summary, topic_hints, int(source_message_count), now),
            )
            self.conn.commit()
        return self.get_session_memory(session_id)  # type: ignore[return-value]

    def create_session(self, payload: SessionCreate) -> SessionRecord:
        session_id = str(uuid.uuid4())
        now = _now_iso()
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO sessions (
                    id, title, client, source_kind, source_id, workspace_root, workspace_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (session_id, payload.title, payload.client, None, None, None, None, now, now),
            )
            self.conn.commit()
        return self.get_session(session_id)

    def _build_search_text(self, session_id: str) -> str | None:
        rows = self.conn.execute(
            """
            SELECT content
            FROM messages
            WHERE session_id = ?
            ORDER BY created_at ASC
            """,
            (session_id,),
        ).fetchall()
        if not rows:
            return None
        parts = []
        for row in rows:
            content = str(row["content"] or "").strip()
            if content:
                parts.append(content[:120])
            if len(parts) >= 12:
                break
        return " ".join(dict.fromkeys(parts)) if parts else None

    def _session_from_row(self, row: sqlite3.Row) -> SessionRecord:
        payload = dict(row)
        session_id = str(row["id"])
        updated_at = str(row["updated_at"])
        cached = self._search_cache.get(session_id)
        if cached and cached[0] == updated_at:
            payload["search_text"] = cached[1]
        else:
            payload["search_text"] = self._build_search_text(session_id)
            self._search_cache[session_id] = (updated_at, payload["search_text"])
        return SessionRecord.model_validate(payload)

    def _invalidate_search_cache(self, session_id: str) -> None:
        self._search_cache.pop(session_id, None)

    def list_sessions(self) -> list[SessionRecord]:
        with self._lock:
            rows = self.conn.execute(
                """
                SELECT id, title, client, source_kind, source_id, source_title, workspace_root, workspace_id, created_at, updated_at
                FROM sessions
                ORDER BY updated_at DESC
                """
            ).fetchall()
        return [self._session_from_row(row) for row in rows]

    def get_session(self, session_id: str) -> SessionRecord:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT id, title, client, source_kind, source_id, source_title, workspace_root, workspace_id, created_at, updated_at
                FROM sessions
                WHERE id = ?
                """,
                (session_id,),
            ).fetchone()
        if row is None:
            raise KeyError(f"session not found: {session_id}")
        return self._session_from_row(row)

    def find_session_by_source(self, source_kind: str, source_id: str) -> SessionRecord | None:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT id, title, client, source_kind, source_id, source_title, workspace_root, workspace_id, created_at, updated_at
                FROM sessions
                WHERE source_kind = ? AND source_id = ?
                """,
                (source_kind, source_id),
            ).fetchone()
        if row is None:
            return None
        return self._session_from_row(row)

    def touch_session(self, session_id: str) -> SessionRecord:
        now = _now_iso()
        with self._lock:
            self.conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return self.get_session(session_id)

    def set_session_updated_at(self, session_id: str, updated_at: str) -> SessionRecord:
        with self._lock:
            self.conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (updated_at, session_id))
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return self.get_session(session_id)

    def update_session_metadata(
        self,
        session_id: str,
        *,
        title: str | None = None,
        client: str | None = None,
        workspace_root: str | None = None,
        workspace_id: str | None = None,
        source_title: str | None = None,
    ) -> SessionRecord:
        existing = self.get_session(session_id)
        next_title = title if title is not None else existing.title
        next_client = client if client is not None else existing.client
        next_workspace_root = workspace_root if workspace_root is not None else existing.workspace_root
        next_workspace_id = workspace_id if workspace_id is not None else existing.workspace_id
        next_source_title = source_title if source_title is not None else existing.source_title
        with self._lock:
            self.conn.execute(
                """
                UPDATE sessions
                SET title = ?, client = ?, workspace_root = ?, workspace_id = ?, source_title = ?
                WHERE id = ?
                """,
                (next_title, next_client, next_workspace_root, next_workspace_id, next_source_title, session_id),
            )
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return self.get_session(session_id)

    def set_preferred_session_for_workspace(
        self,
        *,
        workspace_id: str,
        workspace_root: str | None,
        session_id: str,
    ) -> None:
        now = _now_iso()
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO workspace_state (workspace_id, workspace_root, preferred_session_id, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(workspace_id) DO UPDATE SET
                    workspace_root = excluded.workspace_root,
                    preferred_session_id = excluded.preferred_session_id,
                    updated_at = excluded.updated_at
                """,
                (workspace_id, workspace_root, session_id, now),
            )
            self.conn.commit()

    def get_preferred_session_for_workspace(
        self,
        *,
        workspace_id: str,
    ) -> SessionRecord | None:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT preferred_session_id
                FROM workspace_state
                WHERE workspace_id = ?
                """,
                (workspace_id,),
            ).fetchone()
        if row is None or not row["preferred_session_id"]:
            return None
        try:
            return self.get_session(str(row["preferred_session_id"]))
        except KeyError:
            return None

    def get_latest_session_for_workspace(
        self,
        *,
        workspace_id: str,
    ) -> SessionRecord | None:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT id, title, client, source_kind, source_id, source_title, workspace_root, workspace_id, created_at, updated_at
                FROM sessions
                WHERE workspace_id = ?
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (workspace_id,),
            ).fetchone()
        if row is None:
            return None
        return self._session_from_row(row)

    def append_message(
        self,
        *,
        session_id: str,
        role: str,
        content: str,
        provider: str | None = None,
        mode: str | None = None,
        model: str | None = None,
        prompt_tokens: int | None = None,
        completion_tokens: int | None = None,
        total_tokens: int | None = None,
        cost: float | None = None,
        elapsed_ms: int | None = None,
    ) -> MessageRecord:
        message_id = str(uuid.uuid4())
        now = _now_iso()
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO messages (
                    id, session_id, role, content, provider, mode,
                    model, prompt_tokens, completion_tokens, total_tokens, cost, elapsed_ms,
                    created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    message_id,
                    session_id,
                    role,
                    content,
                    provider,
                    mode,
                    model,
                    prompt_tokens,
                    completion_tokens,
                    total_tokens,
                    cost,
                    elapsed_ms,
                    now,
                ),
            )
            self.conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return self.get_message(message_id)

    def get_message(self, message_id: str) -> MessageRecord:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT id, session_id, role, content, provider, mode, model, prompt_tokens, completion_tokens, total_tokens, cost, elapsed_ms, created_at
                FROM messages WHERE id = ?
                """,
                (message_id,),
            ).fetchone()
        if row is None:
            raise KeyError(f"message not found: {message_id}")
        return MessageRecord.model_validate(dict(row))

    def list_messages(self, session_id: str) -> list[MessageRecord]:
        with self._lock:
            rows = self.conn.execute(
                """
                SELECT id, session_id, role, content, provider, mode, model, prompt_tokens, completion_tokens, total_tokens, cost, elapsed_ms, created_at
                FROM messages
                WHERE session_id = ?
                ORDER BY created_at ASC
                """,
                (session_id,),
            ).fetchall()
        return [MessageRecord.model_validate(dict(row)) for row in rows]

    def create_imported_session(
        self,
        *,
        title: str,
        client: str | None,
        source_kind: str,
        source_id: str,
        workspace_root: str | None,
        workspace_id: str | None,
        created_at: str,
        updated_at: str,
    ) -> SessionRecord:
        session_id = str(uuid.uuid4())
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO sessions (
                    id, title, client, source_kind, source_id, source_title,
                    workspace_root, workspace_id, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (session_id, title, client, source_kind, source_id, title, workspace_root, workspace_id, created_at, updated_at),
            )
            self.conn.commit()
        return self.get_session(session_id)

    def append_imported_message(
        self,
        *,
        session_id: str,
        role: str,
        content: str,
        created_at: str,
        provider: str | None = None,
        mode: str | None = None,
    ) -> MessageRecord:
        canonical_created_at = _canonical_timestamp(created_at)
        existing_row = None
        with self._lock:
            existing = self.conn.execute(
                """
                SELECT id, session_id, role, content, provider, mode, model, prompt_tokens, completion_tokens, total_tokens, cost, elapsed_ms, created_at
                FROM messages
                WHERE session_id = ? AND role = ? AND content = ? AND created_at IN (?, ?)
                ORDER BY id ASC
                LIMIT 1
                """,
                (session_id, role, content, created_at, canonical_created_at),
            ).fetchone()
            if existing is not None:
                existing_row = existing
        if existing_row is not None:
            return MessageRecord.model_validate(dict(existing_row))
        message_id = str(uuid.uuid4())
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO messages (id, session_id, role, content, provider, mode, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (message_id, session_id, role, content, provider, mode, canonical_created_at),
            )
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return self.get_message(message_id)

    def update_message_content(
        self,
        message_id: str,
        *,
        content: str,
        provider: str | None = None,
        mode: str | None = None,
    ) -> MessageRecord:
        current = self.get_message(message_id)
        next_provider = provider if provider is not None else current.provider
        next_mode = mode if mode is not None else current.mode
        with self._lock:
            self.conn.execute(
                """
                UPDATE messages
                SET content = ?, provider = ?, mode = ?
                WHERE id = ?
                """,
                (content, next_provider, next_mode, message_id),
            )
            self.conn.commit()
        self._invalidate_search_cache(current.session_id)
        return self.get_message(message_id)

    def dedupe_messages(self, session_id: str) -> int:
        with self._lock:
            rows = self.conn.execute(
                """
                SELECT id, role, content, provider, mode, created_at
                FROM messages
                WHERE session_id = ?
                ORDER BY created_at ASC, id ASC
                """,
                (session_id,),
            ).fetchall()
            seen: set[tuple[str, str, str]] = set()
            duplicate_ids: list[str] = []
            for row in rows:
                key = (
                    str(row["role"] or ""),
                    str(row["content"] or ""),
                    _canonical_timestamp(str(row["created_at"] or "")),
                )
                if key in seen:
                    duplicate_ids.append(str(row["id"]))
                    continue
                seen.add(key)
            if not duplicate_ids:
                return 0
            self.conn.executemany("DELETE FROM messages WHERE id = ?", [(value,) for value in duplicate_ids])
            self.conn.commit()
        self._invalidate_search_cache(session_id)
        return len(duplicate_ids)

    def create_chat_task(
        self,
        *,
        session_id: str,
        user_message_id: str,
        mode: str,
        provider: str | None = None,
        status: str = "queued",
    ) -> ChatTaskRecord:
        task_id = str(uuid.uuid4())
        now = _now_iso()
        with self._lock:
            self.conn.execute(
                """
                INSERT INTO chat_tasks (
                    id, session_id, user_message_id, assistant_message_id,
                    status, provider, mode, error, created_at, updated_at, completed_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (task_id, session_id, user_message_id, None, status, provider, mode, None, now, now, None),
            )
            self.conn.commit()
        return self.get_chat_task(task_id)

    def get_chat_task(self, task_id: str) -> ChatTaskRecord:
        with self._lock:
            row = self.conn.execute(
                """
                SELECT id, session_id, user_message_id, assistant_message_id, status, provider,
                       mode, error, model, prompt_tokens, completion_tokens, total_tokens, cost, elapsed_ms,
                       created_at, updated_at, completed_at
                FROM chat_tasks
                WHERE id = ?
                """,
                (task_id,),
            ).fetchone()
        if row is None:
            raise KeyError(f"chat task not found: {task_id}")
        return ChatTaskRecord.model_validate(dict(row))

    def update_chat_task(
        self,
        task_id: str,
        *,
        status: str | None = None,
        provider: str | None = None,
        mode: str | None = None,
        error: str | None = None,
        assistant_message_id: str | None = None,
        completed: bool = False,
        model: str | None = None,
        prompt_tokens: int | None = None,
        completion_tokens: int | None = None,
        total_tokens: int | None = None,
        cost: float | None = None,
        elapsed_ms: int | None = None,
    ) -> ChatTaskRecord:
        existing = self.get_chat_task(task_id)
        now = _now_iso()
        next_status = status or existing.status
        next_provider = provider if provider is not None else existing.provider
        next_mode = mode or existing.mode
        next_error = error
        next_assistant_message_id = assistant_message_id or existing.assistant_message_id
        next_model = model if model is not None else existing.model
        next_prompt_tokens = prompt_tokens if prompt_tokens is not None else existing.prompt_tokens
        next_completion_tokens = completion_tokens if completion_tokens is not None else existing.completion_tokens
        next_total_tokens = total_tokens if total_tokens is not None else existing.total_tokens
        next_cost = cost if cost is not None else existing.cost
        next_elapsed_ms = elapsed_ms if elapsed_ms is not None else existing.elapsed_ms
        completed_at = now if completed else existing.completed_at.isoformat() if existing.completed_at else None
        with self._lock:
            self.conn.execute(
                """
                UPDATE chat_tasks
                SET status = ?, provider = ?, mode = ?, error = ?, assistant_message_id = ?,
                    model = ?, prompt_tokens = ?, completion_tokens = ?, total_tokens = ?, cost = ?, elapsed_ms = ?,
                    updated_at = ?, completed_at = ?
                WHERE id = ?
                """,
                (
                    next_status,
                    next_provider,
                    next_mode,
                    next_error,
                    next_assistant_message_id,
                    next_model,
                    next_prompt_tokens,
                    next_completion_tokens,
                    next_total_tokens,
                    next_cost,
                    next_elapsed_ms,
                    now,
                    completed_at,
                    task_id,
                ),
            )
            self.conn.commit()
        return self.get_chat_task(task_id)

    def interrupt_inflight_tasks(self, reason: str) -> int:
        now = _now_iso()
        with self._lock:
            rows = self.conn.execute(
                """
                SELECT id, session_id, assistant_message_id
                FROM chat_tasks
                WHERE status IN ('queued', 'running')
                """
            ).fetchall()
            if not rows:
                return 0
            touched_sessions: set[str] = set()
            interrupted = 0
            for row in rows:
                task_id = str(row["id"])
                session_id = str(row["session_id"])
                assistant_message_id = str(row["assistant_message_id"]) if row["assistant_message_id"] else None
                if not assistant_message_id:
                    assistant_message_id = str(uuid.uuid4())
                    self.conn.execute(
                        """
                        INSERT INTO messages (id, session_id, role, content, provider, mode, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            assistant_message_id,
                            session_id,
                            "assistant",
                            f"[delegate-error] {reason}",
                            "delegator-core",
                            "delegate",
                            now,
                        ),
                    )
                self.conn.execute(
                    """
                    UPDATE chat_tasks
                    SET status = 'failed', error = ?, assistant_message_id = ?, updated_at = ?, completed_at = ?
                    WHERE id = ?
                    """,
                    (reason, assistant_message_id, now, now, task_id),
                )
                self.conn.execute("UPDATE sessions SET updated_at = ? WHERE id = ?", (now, session_id))
                touched_sessions.add(session_id)
                interrupted += 1
            self.conn.commit()
        for session_id in touched_sessions:
            self._invalidate_search_cache(session_id)
        return interrupted

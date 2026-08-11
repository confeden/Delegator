from __future__ import annotations

from pathlib import Path

from delegator_core.db import connect
from delegator_core.importers import (
    ImportedMessage,
    ImportedSession,
    _fill_missing_timestamps,
    _sync_existing_session,
)
from delegator_core.models import SessionCreate
from delegator_core.session_store import SessionStore


def _store(tmp_path: Path) -> SessionStore:
    return SessionStore(connect(tmp_path / "test.db"))


def _imported(title: str = "Source title", updated_at: str = "2026-08-10T10:00:00+00:00") -> ImportedSession:
    return ImportedSession(
        source_kind="codex",
        source_id="main:abc",
        title=title,
        client="codex/main",
        workspace_root=None,
        workspace_id=None,
        created_at="2026-08-10T09:00:00+00:00",
        updated_at=updated_at,
        messages=[
            ImportedMessage(role="user", content="hello", created_at="2026-08-10T09:00:00+00:00"),
            ImportedMessage(role="assistant", content="hi", created_at="2026-08-10T09:01:00+00:00"),
        ],
    )


def test_message_usage_fields_roundtrip(tmp_path: Path) -> None:
    store = _store(tmp_path)
    session = store.create_session(SessionCreate(title="t"))
    message = store.append_message(
        session_id=session.id,
        role="assistant",
        content="answer",
        provider="gemini-flash-latest",
        mode="delegate",
        model="gemini-flash-latest",
        prompt_tokens=10,
        completion_tokens=20,
        total_tokens=30,
        cost=0.001,
        elapsed_ms=1500,
    )
    fetched = store.get_message(message.id)
    assert fetched.total_tokens == 30
    assert fetched.prompt_tokens == 10
    assert fetched.completion_tokens == 20
    assert fetched.cost == 0.001
    assert fetched.elapsed_ms == 1500
    assert fetched.model == "gemini-flash-latest"


def test_chat_task_usage_fields_roundtrip(tmp_path: Path) -> None:
    store = _store(tmp_path)
    session = store.create_session(SessionCreate(title="t"))
    user_message = store.append_message(session_id=session.id, role="user", content="q")
    task = store.create_chat_task(
        session_id=session.id, user_message_id=user_message.id, mode="delegate"
    )
    updated = store.update_chat_task(
        task.id,
        status="completed",
        completed=True,
        model="stub-model",
        prompt_tokens=5,
        completion_tokens=7,
        total_tokens=12,
        elapsed_ms=900,
    )
    assert updated.total_tokens == 12
    assert updated.model == "stub-model"


def test_user_rename_survives_reimport(tmp_path: Path) -> None:
    store = _store(tmp_path)
    parsed = _imported()
    created = store.create_imported_session(
        title=parsed.title,
        client=parsed.client,
        source_kind=parsed.source_kind,
        source_id=parsed.source_id,
        workspace_root=None,
        workspace_id=None,
        created_at=parsed.created_at,
        updated_at=parsed.updated_at,
    )
    # User renames the session locally.
    store.update_session_metadata(created.id, title="Моё название")
    # Re-import with the same source title must keep the user title.
    _sync_existing_session(store, created.id, parsed)
    assert store.get_session(created.id).title == "Моё название"
    # Even when the source title changes upstream, the user title wins.
    _sync_existing_session(store, created.id, _imported(title="New source title"))
    session = store.get_session(created.id)
    assert session.title == "Моё название"
    assert session.source_title == "New source title"


def test_updated_at_never_moves_backwards(tmp_path: Path) -> None:
    store = _store(tmp_path)
    parsed = _imported()
    created = store.create_imported_session(
        title=parsed.title,
        client=parsed.client,
        source_kind=parsed.source_kind,
        source_id=parsed.source_id,
        workspace_root=None,
        workspace_id=None,
        created_at=parsed.created_at,
        updated_at="2026-08-10T12:00:00+00:00",
    )
    before = store.get_session(created.id).updated_at
    # Import carrying an OLDER updated_at with a new message must not regress it.
    older = _imported(updated_at="2026-08-09T00:00:00+00:00")
    _sync_existing_session(store, created.id, older)
    after = store.get_session(created.id).updated_at
    assert after >= before


def test_fill_missing_timestamps() -> None:
    messages = [
        ImportedMessage(role="user", content="a", created_at=""),
        ImportedMessage(role="assistant", content="b", created_at="2026-08-10T10:00:00+00:00"),
        ImportedMessage(role="user", content="c", created_at=""),
    ]
    filled = _fill_missing_timestamps(messages, "2026-08-01T00:00:00+00:00")
    assert filled[0].created_at == "2026-08-10T10:00:00+00:00"
    assert filled[1].created_at == "2026-08-10T10:00:00+00:00"
    assert filled[2].created_at == "2026-08-10T10:00:00+00:00"
    empty_all = [ImportedMessage(role="user", content="x", created_at="")]
    assert _fill_missing_timestamps(empty_all, "2026-08-01T00:00:00+00:00")[0].created_at == "2026-08-01T00:00:00+00:00"

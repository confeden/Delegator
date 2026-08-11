from __future__ import annotations

import sqlite3
from pathlib import Path


SCHEMA = """
CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    client TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    role TEXT NOT NULL,
    content TEXT NOT NULL,
    provider TEXT,
    mode TEXT,
    created_at TEXT NOT NULL,
    FOREIGN KEY(session_id) REFERENCES sessions(id)
);

CREATE INDEX IF NOT EXISTS idx_messages_session_created
ON messages(session_id, created_at);

CREATE TABLE IF NOT EXISTS chat_tasks (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    user_message_id TEXT NOT NULL,
    assistant_message_id TEXT,
    status TEXT NOT NULL,
    provider TEXT,
    mode TEXT NOT NULL,
    error TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed_at TEXT,
    FOREIGN KEY(session_id) REFERENCES sessions(id),
    FOREIGN KEY(user_message_id) REFERENCES messages(id),
    FOREIGN KEY(assistant_message_id) REFERENCES messages(id)
);

CREATE INDEX IF NOT EXISTS idx_chat_tasks_session_created
ON chat_tasks(session_id, created_at);

CREATE TABLE IF NOT EXISTS workspace_state (
    workspace_id TEXT PRIMARY KEY,
    workspace_root TEXT,
    preferred_session_id TEXT,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(preferred_session_id) REFERENCES sessions(id)
);

CREATE TABLE IF NOT EXISTS session_memory (
    session_id TEXT PRIMARY KEY,
    summary TEXT,
    topic_hints TEXT,
    source_message_count INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL,
    FOREIGN KEY(session_id) REFERENCES sessions(id)
);
"""


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(db_path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.executescript(SCHEMA)
    _ensure_column(conn, "sessions", "source_kind", "TEXT")
    _ensure_column(conn, "sessions", "source_id", "TEXT")
    _ensure_column(conn, "sessions", "workspace_root", "TEXT")
    _ensure_column(conn, "sessions", "workspace_id", "TEXT")
    _ensure_column(conn, "sessions", "source_title", "TEXT")
    _ensure_column(conn, "messages", "model", "TEXT")
    _ensure_column(conn, "messages", "prompt_tokens", "INTEGER")
    _ensure_column(conn, "messages", "completion_tokens", "INTEGER")
    _ensure_column(conn, "messages", "total_tokens", "INTEGER")
    _ensure_column(conn, "messages", "cost", "REAL")
    _ensure_column(conn, "messages", "elapsed_ms", "INTEGER")
    _ensure_column(conn, "chat_tasks", "model", "TEXT")
    _ensure_column(conn, "chat_tasks", "prompt_tokens", "INTEGER")
    _ensure_column(conn, "chat_tasks", "completion_tokens", "INTEGER")
    _ensure_column(conn, "chat_tasks", "total_tokens", "INTEGER")
    _ensure_column(conn, "chat_tasks", "cost", "REAL")
    _ensure_column(conn, "chat_tasks", "elapsed_ms", "INTEGER")
    conn.execute(
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_source
        ON sessions(source_kind, source_id)
        """
    )
    conn.execute(
        """
        CREATE INDEX IF NOT EXISTS idx_sessions_workspace
        ON sessions(workspace_id, updated_at)
        """
    )
    conn.commit()
    return conn


def _ensure_column(conn: sqlite3.Connection, table: str, column: str, column_type: str) -> None:
    existing = {
        row["name"]
        for row in conn.execute(f"PRAGMA table_info({table})").fetchall()
    }
    if column in existing:
        return
    conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {column_type}")

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, replace
from datetime import datetime, timezone
from pathlib import Path

from .models import ImportSessionsResponse
from .session_store import SessionStore


def _parse_iso(value: str | None) -> datetime | None:
    raw = (value or "").strip()
    if not raw:
        return None
    try:
        dt = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _fill_missing_timestamps(messages: list["ImportedMessage"], fallback: str) -> list["ImportedMessage"]:
    """Empty timestamps sort before everything and defeat dedupe keying — forward-fill
    from neighbours, then fall back to the given timestamp."""
    if not messages:
        return messages
    first_known = next((m.created_at for m in messages if m.created_at), "") or fallback
    filled: list[ImportedMessage] = []
    last = first_known
    for message in messages:
        if message.created_at:
            last = message.created_at
            filled.append(message)
        else:
            filled.append(replace(message, created_at=last))
    return filled


@dataclass(frozen=True)
class ImportedMessage:
    role: str
    content: str
    created_at: str


@dataclass(frozen=True)
class ImportedSession:
    source_kind: str
    source_id: str
    title: str
    client: str
    workspace_root: str | None
    workspace_id: str | None
    created_at: str
    updated_at: str
    messages: list[ImportedMessage]


def _file_mtime_iso(file_path: Path) -> str:
    try:
        mtime = file_path.stat().st_mtime
    except OSError:
        return datetime.now(timezone.utc).isoformat()
    return datetime.fromtimestamp(mtime, tz=timezone.utc).isoformat()


def _extract_image_url(item: dict) -> str:
    raw = item.get("image_url")
    if isinstance(raw, dict):
        value = raw.get("url")
        return str(value or "").strip()
    return str(raw or "").strip()


def _content_without_image_markup(value: str) -> str:
    text = (value or "").replace("\r\n", "\n")
    text = text.replace("<image>", "").replace("</image>", "")
    text = "\n".join(
        line for line in text.split("\n")
        if not line.strip().startswith("![image](")
    )
    return " ".join(text.split()).strip().lower()


def _contains_renderable_image(value: str) -> bool:
    return "![image](" in (value or "")


def import_codex_sessions(store: SessionStore, *, user_home: Path, source_id: str | None = None) -> ImportSessionsResponse:
    """Import sessions from Codex IDE."""
    thread_names = _load_codex_thread_names(user_home)
    scanned_files = 0
    imported_sessions = 0
    updated_sessions = 0
    skipped_sessions = 0
    imported_session_ids: list[str] = []
    seen_session_ids: set[str] = set()

    for file_path, profile_name in _discover_codex_session_files(user_home, source_id=source_id):
        scanned_files += 1
        parsed = _parse_codex_session_file(file_path, profile_name, thread_names)
        if parsed is None:
            skipped_sessions += 1
            continue

        existing = store.find_session_by_source(parsed.source_kind, parsed.source_id)
        if existing:
            updated = _sync_existing_session(store, existing.id, parsed)
            if updated:
                updated_sessions += 1
                if existing.id not in seen_session_ids:
                    imported_session_ids.append(existing.id)
                    seen_session_ids.add(existing.id)
            else:
                skipped_sessions += 1
            continue

        session = store.create_imported_session(
            title=parsed.title,
            client=parsed.client,
            source_kind=parsed.source_kind,
            source_id=parsed.source_id,
            workspace_root=parsed.workspace_root,
            workspace_id=parsed.workspace_id,
            created_at=parsed.created_at,
            updated_at=parsed.updated_at,
        )
        for message in parsed.messages:
            store.append_imported_message(
                session_id=session.id,
                role=message.role,
                content=message.content,
                created_at=message.created_at,
            )
        store.dedupe_messages(session.id)
        if parsed.workspace_id:
            store.set_preferred_session_for_workspace(
                workspace_id=parsed.workspace_id,
                workspace_root=parsed.workspace_root,
                session_id=session.id,
            )
        imported_sessions += 1
        if session.id not in seen_session_ids:
            imported_session_ids.append(session.id)
            seen_session_ids.add(session.id)

    return ImportSessionsResponse(
        source="codex",
        scanned_files=scanned_files,
        imported_sessions=imported_sessions,
        updated_sessions=updated_sessions,
        skipped_sessions=skipped_sessions,
        imported_session_ids=imported_session_ids,
    )


def _discover_codex_session_files(user_home: Path, source_id: str | None = None) -> list[tuple[Path, str]]:
    discovered: list[tuple[Path, str]] = []
    target_profile = None
    target_session_id = None
    if source_id and ":" in source_id:
        target_profile, target_session_id = source_id.split(":", 1)

    main_root = user_home / ".codex" / "sessions"
    if main_root.exists() and (target_profile in {None, "main"}):
        if target_session_id:
            for path in sorted(main_root.rglob(f"*{target_session_id}*.jsonl")):
                discovered.append((path, "main"))
        else:
            for path in sorted(main_root.rglob("*.jsonl")):
                discovered.append((path, "main"))

    delegate_root = user_home / ".gemini-delegate"
    if delegate_root.exists():
        for profile_home in sorted(delegate_root.glob("codex-home-*")):
            profile_name = profile_home.name.removeprefix("codex-home-")
            if target_profile and profile_name != target_profile:
                continue
            sessions_root = profile_home / "sessions"
            if not sessions_root.exists():
                continue
            if target_session_id:
                for path in sorted(sessions_root.rglob(f"*{target_session_id}*.jsonl")):
                    discovered.append((path, profile_name))
            else:
                for path in sorted(sessions_root.rglob("*.jsonl")):
                    discovered.append((path, profile_name))

    return discovered


def _parse_codex_session_file(file_path: Path, profile_name: str, thread_names: dict[str, str]) -> ImportedSession | None:
    session_meta_id: str | None = None
    session_started_at: str | None = None
    workspace_root: str | None = None
    display_name: str | None = None
    messages: list[ImportedMessage] = []

    try:
        lines = file_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None

    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            row = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        row_type = row.get("type")
        payload = row.get("payload") or {}
        timestamp = str(row.get("timestamp") or "")

        if row_type == "session_meta":
            session_meta_id = str((payload or {}).get("id") or "")
            session_started_at = str((payload or {}).get("timestamp") or timestamp or "")
            cwd = (payload or {}).get("cwd")
            if isinstance(cwd, str) and cwd.strip():
                workspace_root = cwd.strip()
            continue

        if row_type == "event_msg":
            payload_type = str(payload.get("type") or "")
            if payload_type == "thread_name_updated":
                thread_name = payload.get("thread_name")
                if isinstance(thread_name, str) and thread_name.strip():
                    display_name = thread_name.strip()
            continue

        if row_type != "response_item":
            continue
        if payload.get("type") != "message":
            continue
        if str(payload.get("phase") or "") == "mirror":
            continue

        role = str(payload.get("role") or "")
        if role not in {"user", "assistant"}:
            continue

        content_items = payload.get("content") or []
        text_parts: list[str] = []
        image_parts: list[str] = []
        for item in content_items:
            if not isinstance(item, dict):
                continue
            item_type = str(item.get("type") or "")
            if item_type in {"input_text", "output_text"}:
                text = str(item.get("text") or "").strip()
                if text in {"<image>", "</image>"}:
                    continue
                if text:
                    text_parts.append(text)
                continue
            if item_type in {"input_image", "image_url"}:
                image_url = _extract_image_url(item)
                if image_url:
                    image_parts.append(f"![image]({image_url})")
                continue

        parts = []
        if text_parts:
            parts.append("\n".join(text_parts).strip())
        if image_parts:
            parts.append("\n\n".join(image_parts))
        content = "\n\n".join(part for part in parts if part).strip()
        if not content:
            continue
        if role == "user" and content.startswith("<environment_context>"):
            continue
        if messages and messages[-1].role == role and messages[-1].content == content:
            continue

        messages.append(
            ImportedMessage(
                role=role,
                content=content,
                created_at=timestamp or session_started_at or "",
            )
        )

    if not session_meta_id or not messages:
        return None

    file_fallback = _file_mtime_iso(file_path)
    messages = _fill_missing_timestamps(messages, session_started_at or file_fallback)
    first_user = next((message.content for message in messages if message.role == "user"), "")
    title = display_name or thread_names.get(session_meta_id, "") or _build_title(first_user, file_path.stem)
    created_at = session_started_at or messages[0].created_at
    updated_at = messages[-1].created_at
    return ImportedSession(
        source_kind="codex",
        source_id=f"{profile_name}:{session_meta_id}",
        title=title,
        client=f"codex/{profile_name}",
        workspace_root=workspace_root,
        workspace_id=_workspace_id(workspace_root),
        created_at=created_at,
        updated_at=updated_at,
        messages=messages,
    )


def _build_title(first_user_message: str, fallback: str) -> str:
    text = " ".join(first_user_message.split()).strip()
    if not text:
        return fallback
    if len(text) <= 72:
        return text
    return text[:69].rstrip() + "..."


def _sync_existing_session(store: SessionStore, session_id: str, parsed: ImportedSession) -> bool:
    current = store.get_session(session_id)
    # A user rename (PATCH /api/sessions/{id}) must survive re-imports: only follow
    # the source title while the local title still matches the last imported one.
    user_renamed = bool(current.source_title) and current.title != current.source_title
    next_title = current.title if user_renamed else parsed.title
    metadata_changed = (
        current.title != next_title
        or current.client != parsed.client
        or current.workspace_root != parsed.workspace_root
        or current.workspace_id != parsed.workspace_id
        or current.source_title != parsed.title
    )
    if metadata_changed:
        store.update_session_metadata(
            session_id,
            title=next_title,
            client=parsed.client,
            workspace_root=parsed.workspace_root,
            workspace_id=parsed.workspace_id,
            source_title=parsed.title,
        )

    existing_messages = store.list_messages(session_id)
    changed = False
    prefix = 0
    limit = min(len(existing_messages), len(parsed.messages))
    while prefix < limit:
        current = existing_messages[prefix]
        source = parsed.messages[prefix]
        if current.role != source.role:
            break
        if current.content != source.content:
            current_text = (current.content or "").strip()
            source_text = (source.content or "").strip()
            current_has_placeholder = "<image>" in current_text or "</image>" in current_text
            source_has_renderable_image = _contains_renderable_image(source_text)
            current_is_image_truncated = bool(current_text) and source_has_renderable_image and source_text.startswith(current_text)
            same_text_without_images = (
                _content_without_image_markup(current_text) == _content_without_image_markup(source_text)
            )
            if (current_has_placeholder or current_is_image_truncated or same_text_without_images) and source_has_renderable_image:
                store.update_message_content(current.id, content=source.content)
                changed = True
                prefix += 1
                continue
            break
        prefix += 1

    for source in parsed.messages[prefix:]:
        store.append_imported_message(
            session_id=session_id,
            role=source.role,
            content=source.content,
            created_at=source.created_at,
        )
        changed = True

    removed = store.dedupe_messages(session_id)
    existing_messages = store.list_messages(session_id)
    source_candidates = [
        message for message in parsed.messages
        if _contains_renderable_image(message.content)
    ]
    if source_candidates:
        source_by_key: dict[tuple[str, str], ImportedMessage] = {}
        for message in source_candidates:
            key = (message.role, _content_without_image_markup(message.content))
            if key[1]:
                source_by_key.setdefault(key, message)
        for current in existing_messages:
            current_text = (current.content or "").strip()
            if "<image>" not in current_text and "</image>" not in current_text:
                continue
            key = (current.role, _content_without_image_markup(current_text))
            candidate = source_by_key.get(key)
            if not candidate:
                continue
            if current.content != candidate.content:
                store.update_message_content(current.id, content=candidate.content)
                changed = True
    if changed or removed or metadata_changed:
        # Only move updated_at forward: a locally-active session must not drop down
        # the recency ordering because the source file carries an older timestamp.
        current_updated = store.get_session(session_id).updated_at
        parsed_updated = _parse_iso(parsed.updated_at)
        if parsed_updated is None or current_updated is None or parsed_updated > current_updated:
            store.set_session_updated_at(session_id, parsed.updated_at)
    if parsed.workspace_id:
        store.set_preferred_session_for_workspace(
            workspace_id=parsed.workspace_id,
            workspace_root=parsed.workspace_root,
            session_id=session_id,
        )
    return changed or metadata_changed or (removed > 0)


def _workspace_id(workspace_root: str | None) -> str | None:
    if not workspace_root:
        return None
    normalized = workspace_root.strip().lower()
    if not normalized:
        return None
    return hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]


def _load_codex_thread_names(user_home: Path) -> dict[str, str]:
    """Load thread names for Codex sessions from index file."""
    result: dict[str, str] = {}
    index_path = user_home / ".codex" / "session_index.jsonl"
    if not index_path.exists():
        return result
    try:
        for raw_line in index_path.read_text(encoding="utf-8").splitlines():
            raw_line = raw_line.strip()
            if not raw_line:
                continue
            try:
                row = json.loads(raw_line)
            except json.JSONDecodeError:
                continue
            session_id = str(row.get("id") or "").strip()
            thread_name = str(row.get("thread_name") or "").strip()
            if session_id and thread_name:
                result[session_id] = thread_name
    except OSError:
        return {}
    return result


def _parse_antigravity_session_file(file_path: Path, conversation_id: str) -> ImportedSession | None:
    try:
        lines = file_path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None

    messages: list[ImportedMessage] = []
    workspace_root: str | None = None
    created_at: str | None = None
    updated_at: str | None = None

    for raw_line in lines:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            row = json.loads(raw_line)
        except json.JSONDecodeError:
            continue

        row_type = row.get("type")
        source = row.get("source")
        content = row.get("content") or ""
        timestamp = str(row.get("created_at") or row.get("timestamp") or "")

        # Try to find workspace_root from tool_calls arguments if not found yet
        if not workspace_root and "tool_calls" in row:
            for tc in row["tool_calls"]:
                args = tc.get("args") or {}
                if isinstance(args, dict):
                    for val in args.values():
                        if isinstance(val, str) and (val.startswith("d:\\") or val.startswith("c:\\") or val.startswith("D:\\") or val.startswith("C:\\")):
                            workspace_root = val
                            break
                elif isinstance(args, str):
                    try:
                        args_dict = json.loads(args)
                        if isinstance(args_dict, dict):
                            for val in args_dict.values():
                                if isinstance(val, str) and (val.startswith("d:\\") or val.startswith("c:\\") or val.startswith("D:\\") or val.startswith("C:\\")):
                                    workspace_root = val
                                    break
                    except Exception:
                        pass
                if workspace_root:
                    break

        if row_type == "USER_INPUT" or source == "USER_EXPLICIT":
            # Extract clean request from <USER_REQUEST> if present
            clean_content = content
            if "<USER_REQUEST>" in content and "</USER_REQUEST>" in content:
                start = content.find("<USER_REQUEST>") + len("<USER_REQUEST>")
                end = content.find("</USER_REQUEST>")
                clean_content = content[start:end].strip()
            
            # Extract workspace if user_information has it
            if "<user_information>" in content and not workspace_root:
                for line in content.splitlines():
                    if "->" in line and (line.strip().startswith("d:\\") or line.strip().startswith("c:\\") or line.strip().startswith("D:\\") or line.strip().startswith("C:\\")):
                        workspace_root = line.split("->")[0].strip()
                        break

            if clean_content:
                messages.append(
                    ImportedMessage(
                        role="user",
                        content=clean_content,
                        created_at=timestamp,
                    )
                )
                if not created_at:
                    created_at = timestamp
                updated_at = timestamp

        elif source == "MODEL" and row_type == "PLANNER_RESPONSE":
            if content and content.strip():
                messages.append(
                    ImportedMessage(
                        role="assistant",
                        content=content.strip(),
                        created_at=timestamp,
                    )
                )
                updated_at = timestamp

    if not messages:
        return None

    file_fallback = _file_mtime_iso(file_path)
    messages = _fill_missing_timestamps(messages, file_fallback)
    first_user = next((msg.content for msg in messages if msg.role == "user"), "")
    title = _build_title(first_user, conversation_id)
    if not created_at:
        created_at = messages[0].created_at
    if not updated_at:
        updated_at = messages[-1].created_at

    return ImportedSession(
        source_kind="antigravity",
        source_id=conversation_id,
        title=title,
        client="antigravity",
        workspace_root=workspace_root,
        workspace_id=_workspace_id(workspace_root),
        created_at=created_at,
        updated_at=updated_at,
        messages=messages,
    )


def import_antigravity_sessions(
    store: SessionStore,
    *,
    user_home: Path,
    target_workspace_root: str | None = None,
    source_id: str | None = None,
) -> ImportSessionsResponse:
    """Import sessions from Antigravity."""
    brain_root = user_home / ".gemini" / "antigravity" / "brain"
    scanned_files = 0
    imported_sessions = 0
    updated_sessions = 0
    skipped_sessions = 0
    imported_session_ids: list[str] = []
    seen_session_ids: set[str] = set()

    if not brain_root.exists():
        return ImportSessionsResponse(
            source="antigravity",
            scanned_files=0,
            imported_sessions=0,
            updated_sessions=0,
            skipped_sessions=0,
            imported_session_ids=[],
        )

    conv_dirs = []
    if source_id:
        target_dir = brain_root / source_id
        if target_dir.exists() and target_dir.is_dir():
            conv_dirs = [target_dir]
    else:
        conv_dirs = sorted(brain_root.iterdir())

    for conv_dir in conv_dirs:
        if not conv_dir.is_dir():
            continue
        transcript_file = conv_dir / ".system_generated" / "logs" / "transcript.jsonl"
        if not transcript_file.exists():
            continue

        scanned_files += 1
        parsed = _parse_antigravity_session_file(transcript_file, conv_dir.name)
        if parsed is None:
            skipped_sessions += 1
            continue

        if target_workspace_root and parsed.workspace_root:
            try:
                p1 = Path(parsed.workspace_root).resolve()
                p2 = Path(target_workspace_root).resolve()
                if p1 != p2:
                    skipped_sessions += 1
                    continue
            except Exception:
                if parsed.workspace_root.lower().strip() != target_workspace_root.lower().strip():
                    skipped_sessions += 1
                    continue

        existing = store.find_session_by_source(parsed.source_kind, parsed.source_id)
        if existing:
            updated = _sync_existing_session(store, existing.id, parsed)
            if updated:
                updated_sessions += 1
                if existing.id not in seen_session_ids:
                    imported_session_ids.append(existing.id)
                    seen_session_ids.add(existing.id)
            else:
                skipped_sessions += 1
            continue

        session = store.create_imported_session(
            title=parsed.title,
            client=parsed.client,
            source_kind=parsed.source_kind,
            source_id=parsed.source_id,
            workspace_root=parsed.workspace_root,
            workspace_id=parsed.workspace_id,
            created_at=parsed.created_at,
            updated_at=parsed.updated_at,
        )
        for message in parsed.messages:
            store.append_imported_message(
                session_id=session.id,
                role=message.role,
                content=message.content,
                created_at=message.created_at,
            )
        store.dedupe_messages(session.id)
        if parsed.workspace_id:
            store.set_preferred_session_for_workspace(
                workspace_id=parsed.workspace_id,
                workspace_root=parsed.workspace_root,
                session_id=session.id,
            )
        imported_sessions += 1
        if session.id not in seen_session_ids:
            imported_session_ids.append(session.id)
            seen_session_ids.add(session.id)

    return ImportSessionsResponse(
        source="antigravity",
        scanned_files=scanned_files,
        imported_sessions=imported_sessions,
        updated_sessions=updated_sessions,
        skipped_sessions=skipped_sessions,
        imported_session_ids=imported_session_ids,
    )

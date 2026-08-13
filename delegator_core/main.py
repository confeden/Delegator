from __future__ import annotations

import asyncio
import logging
import mimetypes
import hashlib
import json
import re
import shutil
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import uvicorn
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.responses import FileResponse
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import __version__
from .benchmark import (
    ARM_MODEL,
    BENCHMARK_VERSION,
    BenchmarkStore,
    export_report,
    finish_run,
    generate_run,
    known_template_ids,
    load_items,
    missing_answers,
    record_answer,
    run_status,
    summarise,
)
from .config import CoreConfig, load_config
from .db import connect
from .importers import import_codex_sessions, import_antigravity_sessions
from .models import (
    ChatTaskEvent,
    ImportSessionsResponse,
    ChatTurnRequest,
    ChatTurnResponse,
    ChatTurnStartResponse,
    SessionMemoryRecord,
    SessionCreate,
    SessionUpdate,
    UploadRecord,
    WorkspacePreferredSessionResponse,
)
from .providers import ProviderResult, ProviderUsage, ShellDelegateProvider
from .session_store import SessionStore
from .usage import build_usage_report


class TaskEventBus:
    def __init__(self) -> None:
        self._subscribers: dict[str, list[asyncio.Queue[ChatTaskEvent]]] = {}
        self._lock = asyncio.Lock()

    async def subscribe(self, task_id: str) -> asyncio.Queue[ChatTaskEvent]:
        queue: asyncio.Queue[ChatTaskEvent] = asyncio.Queue()
        async with self._lock:
            self._subscribers.setdefault(task_id, []).append(queue)
        return queue

    async def unsubscribe(self, task_id: str, queue: asyncio.Queue[ChatTaskEvent]) -> None:
        async with self._lock:
            queues = self._subscribers.get(task_id, [])
            if queue in queues:
                queues.remove(queue)
            if not queues and task_id in self._subscribers:
                del self._subscribers[task_id]

    async def publish(self, task_id: str, event: ChatTaskEvent) -> None:
        async with self._lock:
            queues = list(self._subscribers.get(task_id, []))
        for queue in queues:
            await queue.put(event)


class AppState:
    def __init__(self, config: CoreConfig) -> None:
        self.config = config
        
        # Setup logging
        self.logger = logging.getLogger("delegator_core")
        self.logger.setLevel(logging.INFO)
        
        # Ensure file handler exists so that logs are always written to delegator-core.log
        has_file_handler = any(isinstance(h, logging.FileHandler) for h in self.logger.handlers)
        if not has_file_handler:
            formatter = logging.Formatter("[%(asctime)s] %(levelname)s in %(module)s: %(message)s")
            self.config.home_dir.mkdir(parents=True, exist_ok=True)
            log_file = self.config.home_dir / "delegator-core.log"
            try:
                fh = logging.FileHandler(log_file, encoding="utf-8")
                fh.setFormatter(formatter)
                self.logger.addHandler(fh)
            except Exception as e:
                print(f"Failed to setup FileHandler for delegator-core.log: {e}")
                
        # Ensure we have a StreamHandler if no handlers exist
        if not self.logger.handlers:
            formatter = logging.Formatter("[%(asctime)s] %(levelname)s in %(module)s: %(message)s")
            ch = logging.StreamHandler()
            ch.setFormatter(formatter)
            self.logger.addHandler(ch)

        # Track background tasks to prevent garbage collection mid-execution
        self.background_tasks: set[asyncio.Task] = set()

        self.logger.info("Initializing Delegator Core AppState")
        self.conn = connect(config.db_path)
        self.sessions = SessionStore(self.conn)
        self.sessions.interrupt_inflight_tasks(
            "Задача была прервана перезапуском Delegator Core. Отправьте запрос ещё раз."
        )
        self.provider = ShellDelegateProvider(
            command=config.shell_delegate_cmd,
            timeout_sec=config.shell_timeout_sec,
        )
        self.static_dir = Path(__file__).parent / "static"
        self.index_file = self.static_dir / "index.html"
        self.upload_dir = self.config.home_dir / "uploads"
        self.upload_dir.mkdir(parents=True, exist_ok=True)
        self.events = TaskEventBus()
        self.workspace_labels = _load_workspace_labels()
        # Benchmark runs live next to the other runtime state, not in the DB:
        # one machine has at most one last result and a handful of live runs.
        self.benchmark = BenchmarkStore(self.config.runtime_home)


def _preferred_output_language(text: str) -> str:
    if not text:
        return "English"
    lowered = text.lower()
    if "answer in english" in lowered or "respond in english" in lowered or "write in english" in lowered or "на английском" in lowered:
        return "English"
    if "answer in russian" in lowered or "respond in russian" in lowered or "write in russian" in lowered or "на русском" in lowered or "по-русски" in lowered:
        return "Russian"
    return "Russian" if any("\u0400" <= ch <= "\u04ff" for ch in text) else "English"


def _message_needs_context(text: str) -> bool:
    value = (text or "").strip()
    if not value:
        return False
    if len(value) >= 120:
        return True
    lowered = value.lower()
    context_markers = (
        "это",
        "этот",
        "эта",
        "эти",
        "контекст",
        "бесед",
        "диалог",
        "разговор",
        "истори",
        "прошл",
        "выше",
        "до этого",
        "до сих пор",
        "помнишь",
        "видишь",
        "то есть",
        "исправь",
        "поправь",
        "продолж",
        "что дальше",
        "what next",
        "continue",
        "fix this",
        "update this",
        "context",
        "conversation",
        "history",
        "previous",
        "earlier",
        "above",
        "remember",
        "do you see",
        "that",
        "this",
    )
    if any(marker in lowered for marker in context_markers):
        return True
    # Word-boundary match for short pronouns: the old "it "/"they " substring
    # check missed sentence-final uses like "fix it".
    return re.search(r"\b(it|they|them)\b", lowered) is not None


def _message_explicitly_references_conversation(text: str) -> bool:
    value = (text or "").strip().lower()
    if not value:
        return False
    markers = (
        "контекст",
        "нашей бесед",
        "нашего диал",
        "этой бесед",
        "этого диал",
        "предыдущ",
        "выше",
        "до этого",
        "видишь контекст",
        "помнишь",
        "remember",
        "conversation",
        "history",
        "previous messages",
        "earlier messages",
        "see the context",
        "видишь ли ты контекст",
        "видишь ли контекст",
        "контекст беседы",
        "контекст диалога",
        "контекст чата",
    )
    return any(marker in value for marker in markers)


_ACTION_WORD_PREFIXES = (
    "исправ",
    "поправ",
    "почин",
    "сдела",
    "добав",
    "удали",
    "убер",
    "измен",
    "перепиш",
    "напиш",
    "создай",
    "обнови",
    "загрузи",
    "проверь",
    "запусти",
    "fix",
    "repair",
    "add",
    "remove",
    "delete",
    "change",
    "update",
    "rewrite",
    "write",
    "create",
    "make",
    "implement",
    "load",
    "debug",
    "run",
    "check",
)


def _message_is_imperative_request(compact: str) -> bool:
    words = [word for word in re.split(r"\s+", compact.strip(" ?!.,;:")) if word]
    return any(
        word.startswith(prefix) for word in words for prefix in _ACTION_WORD_PREFIXES
    )


def _message_is_context_probe(text: str) -> bool:
    value = (text or "").strip().lower()
    if not value:
        return False
    compact = re.sub(r"\s+", " ", value)
    # An imperative request that merely mentions the context ("исправь контекст
    # беседы", "fix the chat context bug") is real work, never a probe.
    if _message_is_imperative_request(compact):
        return False
    markers = (
        "видишь контекст",
        "видишь ли контекст",
        "помнишь контекст",
        "помнишь нашу беседу",
        "видишь нашу беседу",
        "видишь контекст нашей беседы",
        "о чем мы говорили",
        "какой контекст",
        "do you see the context",
        "do you remember the context",
        "do you remember our conversation",
        "what context do you see",
        "what were we discussing",
    )
    if any(marker in compact for marker in markers):
        return True
    words = [word for word in re.split(r"\s+", compact.strip(" ?!.,;:")) if word]
    if len(words) <= 6:
        has_context_word = any(
            token.startswith(prefix)
            for token in words
            for prefix in ("контекст", "context")
        )
        has_conversation_word = any(
            token.startswith(prefix)
            for token in words
            for prefix in (
                "бесед",
                "диалог",
                "чат",
                "разговор",
                "conversation",
                "dialog",
                "chat",
            )
        )
        # Require an interrogative cue: a bare noun phrase without a question mark
        # or probe verb ("chat context loading bug") is not a probe.
        has_question_cue = "?" in compact or any(
            words[0].startswith(prefix)
            for prefix in ("вид", "помн", "знаешь", "do", "can", "what", "which")
        )
        if has_context_word and has_conversation_word and has_question_cue:
            return True
    if re.search(r"^контекст(?:\s+(?:нашей|этой))?\s+(?:беседы|переписки|разговора|диалога|чата)\??$", compact):
        return True
    if re.search(r"^(?:видишь|помнишь)(?:\s+ли)?(?:\s+ты)?\s+контекст(?:\s+(?:нашей|этой))?(?:\s+(?:беседы|переписки|разговора|диалога|чата))?\??$", compact):
        return True
    if re.search(r"^(?:the\s+)?context(?:\s+of)?(?:\s+our|\s+this)?\s+(?:conversation|dialog|chat)\??$", compact):
        return True
    return False


def _message_is_greeting(text: str) -> bool:
    value = (text or "").strip().lower()
    return value in {
        "привет",
        "здравствуй",
        "здравствуйте",
        "добрый день",
        "добрый вечер",
        "hello",
        "hi",
        "hey",
    }


def _message_requires_exact_output(text: str) -> bool:
    value = (text or "").strip().lower()
    markers = (
        "reply exactly:",
        "print exactly:",
        "ответь одним словом",
        "только одним словом",
        "без пояснений",
        "without explanation",
        "one word only",
        "exactly:",
    )
    return any(marker in value for marker in markers)


def _resolve_execution_mode(requested_mode: str, latest_text: str) -> str:
    if requested_mode == "delegate" and not _message_needs_context(latest_text):
        return "micro"
    return requested_mode


def _trim_recent_messages(messages, max_messages: int = 5, max_chars: int = 2500):
    recent = list(messages)[-max_messages:]
    kept = []
    total = 0
    for message in reversed(recent):
        chunk = len(message.content or "")
        if kept and total + chunk > max_chars:
            break
        kept.append(message)
        total += chunk
    kept.reverse()
    return kept


def _is_unhelpful_context_message(role: str, content: str, latest_text: str = "") -> bool:
    value = (content or "").strip()
    lowered = value.lower()
    if not value:
        return True
    if lowered.startswith("[delegate-error]"):
        return True
    if role == "assistant":
        generic = (
            "ready.",
            "ready",
            "ok.",
            "ok",
            "okay.",
            "okay",
            "хорошо.",
            "хорошо",
            "ок.",
            "ок",
            "понял.",
            "понял",
            "принято.",
            "принято",
        )
        if lowered in generic:
            return True
        if len(value) <= 120 and (
            "буду отвечать коротко" in lowered
            or "буду отвечать по-русски" in lowered
            or "i will answer briefly" in lowered
            or "i will answer in russian" in lowered
        ):
            return True
        if (
            "предоставьте текст диалога" in lowered
            or "предоставьте текст" in lowered
            or "предоставьте диалог" in lowered
            or "пришлите диалог" in lowered
            or "пришлите историю" in lowered
            or "предоставьте историю" in lowered
            or "диалог не предоставлен" in lowered
            or "нет существующего диалога" in lowered
            or "история диалога не предоставлена" in lowered
            or "please provide the text dialogue" in lowered
            or "please provide the dialogue" in lowered
            or "dialogue history was not provided" in lowered
            or "no existing dialogue" in lowered
            or "no conversation history" in lowered
            or "please provide your prompt" in lowered
            or "i don't see a specific request" in lowered
        ):
            return True
    if latest_text and lowered == latest_text.strip().lower():
        return True
    return False


def _collapse_context_messages(messages):
    source = list(messages or [])
    result = []
    index = 0
    while index < len(source):
        current = source[index]
        if current.role != "assistant":
            result.append(current)
            index += 1
            continue
        end = index
        while end + 1 < len(source) and source[end + 1].role == "assistant":
            end += 1
        result.append(source[end])
        index = end + 1
    return result


def _sanitize_context_messages(messages, latest_text: str):
    collapsed = _collapse_context_messages(messages)
    filtered = []
    for message in collapsed:
        if _is_unhelpful_context_message(message.role, message.content or "", latest_text):
            continue
        filtered.append(message)
    return filtered


def _compress_older_messages(messages, max_items: int = 6, max_chars: int = 900) -> list[str]:
    if not messages:
        return []
    lines: list[str] = []
    total = 0
    candidates = list(messages)[-max_items:]
    for message in candidates:
        content = (message.content or "").replace("\r\n", "\n").strip()
        if not content:
            continue
        short = content.split("\n", 1)[0].strip()
        if len(short) > 140:
            short = short[:137].rstrip() + "..."
        line = f"{message.role.upper()}: {short}"
        total += len(line)
        if lines and total > max_chars:
            break
        lines.append(line)
    return lines


def _extract_context_topics(messages, limit: int = 2) -> list[str]:
    topics: list[str] = []
    seen: set[str] = set()
    weak_lines = {
        "исправил.",
        "исправил",
        "сделал.",
        "сделал",
        "поправил.",
        "поправил",
        "готово.",
        "готово",
        "done.",
        "done",
        "fixed.",
        "fixed",
    }
    for message in reversed(list(messages or [])):
        if getattr(message, "role", None) != "user":
            continue
        content = (message.content or "").replace("\r\n", "\n").strip()
        if not content:
            continue
        lowered_content = content.lower()
        if _message_is_context_probe(content):
            continue
        lines = [line.strip() for line in content.split("\n") if line.strip()]
        if not lines:
            continue
        first_line = lines[0]
        if first_line.lower() in weak_lines and len(lines) > 1:
            first_line = lines[1]
        first_line = re.sub(r"\s+", " ", first_line)
        if len(first_line) > 110:
            first_line = first_line[:107].rstrip() + "..."
        key = first_line.lower()
        if key in seen:
            continue
        seen.add(key)
        topics.append(first_line)
        if len(topics) >= limit:
            break
    topics.reverse()
    return topics


def _build_session_memory_payload(messages) -> tuple[str | None, str | None, int]:
    sanitized = _sanitize_context_messages(messages, "")
    clean_count = len(sanitized)
    if clean_count <= 8:
        return None, None, clean_count
    older = sanitized[:-6]
    if not older:
        return None, None, clean_count
    user_topics = _extract_context_topics(older, limit=6)
    if not user_topics:
        return None, None, clean_count
    summary_lines = ["КРАТКАЯ ПАМЯТЬ СЕССИИ:"]
    summary_lines.extend(f"- {item}" for item in user_topics)
    return "\n".join(summary_lines), json.dumps(user_topics, ensure_ascii=False), clean_count


def _ensure_session_memory(store: SessionStore, session_id: str, messages) -> SessionMemoryRecord | None:
    summary, topic_hints, clean_count = _build_session_memory_payload(messages)
    current = store.get_session_memory(session_id)
    if current and current.source_message_count == clean_count and current.summary == summary and current.topic_hints == topic_hints:
        return current
    if not summary:
        if current and current.source_message_count != clean_count:
            return store.upsert_session_memory(
                session_id,
                summary=None,
                topic_hints=None,
                source_message_count=clean_count,
            )
        return current
    return store.upsert_session_memory(
        session_id,
        summary=summary,
        topic_hints=topic_hints,
        source_message_count=clean_count,
    )


def _build_local_context_probe_reply(messages, latest_text: str) -> str | None:
    if not _message_is_context_probe(latest_text):
        return None
    sanitized = _sanitize_context_messages(messages, latest_text)
    if not sanitized:
        return None
    topics = _extract_context_topics(sanitized, limit=2)
    preferred_language = _preferred_output_language(latest_text)
    if preferred_language == "Russian":
        if topics:
            if len(topics) == 1:
                return f"Да, вижу контекст. Последняя заметная тема: {topics[0]}"
            return f"Да, вижу контекст. Недавно мы обсуждали: {topics[0]}; {topics[1]}"
        return "Да, вижу контекст последних сообщений этой беседы."
    if topics:
        if len(topics) == 1:
            return f"Yes, I do see the context. One recent topic was: {topics[0]}"
        return f"Yes, I do see the context. Recent topics included: {topics[0]}; {topics[1]}"
    return "Yes, I do see the recent context of this conversation."


def _should_use_local_context_probe(messages, latest_text: str) -> bool:
    if not _message_is_context_probe(latest_text):
        return False
    sanitized = _sanitize_context_messages(messages, latest_text)
    return len(sanitized) >= 1


def _should_repair_context_failure(messages, latest_text: str, assistant_text: str) -> bool:
    if not (_message_explicitly_references_conversation(latest_text) or _message_is_context_probe(latest_text)):
        return False
    if not _is_unhelpful_context_message("assistant", assistant_text or "", latest_text):
        return False
    sanitized = _sanitize_context_messages(messages, latest_text)
    return len(sanitized) >= 1


def _build_context_failure_fallback(messages, latest_text: str) -> str | None:
    if not (_message_explicitly_references_conversation(latest_text) or _message_is_context_probe(latest_text)):
        return None
    sanitized = _sanitize_context_messages(messages, latest_text)
    if not sanitized:
        return None
    topics = _extract_context_topics(sanitized, limit=2)
    preferred_language = _preferred_output_language(latest_text)
    if preferred_language == "Russian":
        if topics:
            if len(topics) == 1:
                return f"Да, я вижу контекст беседы. Последняя заметная тема: {topics[0]}"
            return f"Да, я вижу контекст беседы. Недавно мы обсуждали: {topics[0]}; {topics[1]}"
        return "Да, я вижу контекст последних сообщений этой беседы."
    if topics:
        if len(topics) == 1:
            return f"Yes, I can see the conversation context. One recent topic was: {topics[0]}"
        return f"Yes, I can see the conversation context. Recent topics included: {topics[0]}; {topics[1]}"
    return "Yes, I can see the recent context of this conversation."


def _build_context_guard_line(latest_text: str) -> str | None:
    if not _message_explicitly_references_conversation(latest_text):
        return None
    preferred_language = _preferred_output_language(latest_text)
    if preferred_language == "Russian":
        return (
            "Ниже уже передан достаточный контекст беседы. "
            "Не проси пользователя прислать историю, лог или диалог заново."
        )
    return (
        "Sufficient conversation context is already included below. "
        "Do not ask the user to provide the history, transcript, or dialogue again."
    )


def _build_delegate_prompt(core: AppState, session, messages, latest_text: str) -> str:
    preferred_language = _preferred_output_language(latest_text)
    references_conversation = _message_explicitly_references_conversation(latest_text)
    memory = _ensure_session_memory(core.sessions, session.id, messages)
    if _message_requires_exact_output(latest_text):
        return latest_text
    if not _message_needs_context(latest_text) and not references_conversation and not _session_has_history(messages):
        is_greeting = _message_is_greeting(latest_text)
        greeting_hint_ru = "Если это простое приветствие, коротко поздоровайся и предложи помочь." if is_greeting else "Если это короткий вопрос, ответь коротко и по делу."
        greeting_hint_en = "If this is a greeting, greet briefly and offer help." if is_greeting else "If this is a short question, answer briefly and directly."
        if preferred_language == "Russian":
            lead_ru = "Коротко ответь по-русски." if not is_greeting else "Коротко поздоровайся по-русски и предложи помочь."
            return "\n".join(
                [
                    lead_ru,
                    "Отвечай прямо на сообщение пользователя.",
                    "Не описывай политики, кодовую базу, архитектуру, инструкции, workspace или внутреннюю логику, если пользователь этого не просил.",
                    greeting_hint_ru,
                    "",
                    "СООБЩЕНИЕ ПОЛЬЗОВАТЕЛЯ:",
                    latest_text,
                ]
            )
        return "\n".join(
            [
                "Reply briefly in English.",
                "Reply directly to the user's message.",
                "Do not describe policies, codebase details, architecture, instructions, workspace, or internal logic unless the user explicitly asked for that.",
                greeting_hint_en,
                "",
                "USER MESSAGE:",
                latest_text,
            ]
        )
    recent_messages = _sanitize_context_messages(messages, latest_text)
    while recent_messages and recent_messages[-1].role == "user" and (recent_messages[-1].content or "").strip() == latest_text.strip():
        recent_messages = recent_messages[:-1]
    if references_conversation:
        latest_normalized = latest_text.strip().lower()
        recent_messages = [
            message
            for message in recent_messages
            if not (
                message.role == "user"
                and (message.content or "").strip().lower() != latest_normalized
                and _message_is_context_probe(message.content or "")
            )
        ]
    recent_limit = 6 if references_conversation else 8
    recent_chars = 4200 if references_conversation else 5000
    recent = _trim_recent_messages(recent_messages, max_messages=recent_limit, max_chars=recent_chars)
    older = recent_messages[:-len(recent)] if recent else recent_messages
    older_summary = _compress_older_messages(older, max_items=6 if references_conversation else 4, max_chars=1000 if references_conversation else 600)
    memory_block = memory.summary if memory and memory.summary else None
    history_lines = []
    for message in recent:
        role = message.role.upper()
        history_lines.append(f"{role}:")
        history_lines.append(message.content)
        history_lines.append("")
    if preferred_language == "Russian":
        instructions = [
            "Продолжи существующий диалог одной следующей репликой ASSISTANT.",
            "Отвечай только по-русски.",
            "Не начинай разговор заново и не отвечай на служебные инструкции отдельно.",
        ]
        context_guard = _build_context_guard_line(latest_text)
        if context_guard:
            instructions.append(context_guard)
        if references_conversation:
            instructions.extend(
                [
                    "Считай переданные ниже ПАМЯТЬ СЕССИИ и НЕДАВНИЙ ДИАЛОГ достаточным источником контекста этой беседы.",
                    "Если пользователь спрашивает про контекст беседы, коротко подтверди, что он виден, и назови 1-2 конкретные недавние темы.",
                    "Не проси пользователя прислать историю, лог или текст диалога заново, если ниже уже есть контекст.",
                    "Не отвечай как на новое приветствие и не ограничивайся общей фразой согласия.",
                ]
            )
        return "\n".join(
            instructions
            + [
                *(["ПАМЯТЬ СЕССИИ:"] + [memory_block] + [""] if memory_block else []),
                *(["СЖАТЫЙ БОЛЕЕ РАННИЙ КОНТЕКСТ:"] + older_summary + [""] if (older_summary and not memory_block) else []),
                "НЕДАВНИЙ ДИАЛОГ:",
                *history_lines,
                "",
                "USER:",
                latest_text,
                "",
                "ASSISTANT:",
            ]
        )
    instructions = [
        "Continue the existing conversation with exactly one next ASSISTANT reply.",
        "Answer only in English.",
        "Do not restart the conversation or reply to the framing instructions separately.",
    ]
    context_guard = _build_context_guard_line(latest_text)
    if context_guard:
        instructions.append(context_guard)
    if references_conversation:
        instructions.extend(
            [
                "Treat the SESSION MEMORY and RECENT DIALOGUE below as sufficient transcript context for this conversation.",
                "If the user asks about conversation context, briefly confirm it and mention 1-2 concrete recent topics.",
                "Do not ask the user to provide the history, transcript, or dialogue again if context is already present below.",
                "Do not answer as if this were a brand-new greeting or with a generic acknowledgment like 'Okay.'",
            ]
        )
    return "\n".join(
        instructions
        + [
            *(["SESSION MEMORY:"] + [memory_block] + [""] if memory_block else []),
            *(["COMPRESSED EARLIER CONTEXT:"] + older_summary + [""] if (older_summary and not memory_block) else []),
            "RECENT DIALOGUE:",
            *history_lines,
            "",
            "USER:",
            latest_text,
            "",
            "ASSISTANT:",
        ]
    )


def _session_has_history(messages) -> bool:
    return len(list(messages)) > 1


def _codex_session_file(source_id: str) -> Path | None:
    if ":" not in (source_id or ""):
        return None
    profile, session_id = source_id.split(":", 1)
    user_home = Path.home()
    root = user_home / ".codex" / "sessions" if profile == "main" else user_home / ".gemini-delegate" / f"codex-home-{profile}" / "sessions"
    if not root.exists():
        return None
    matches = list(root.rglob(f"*{session_id}.jsonl"))
    return matches[0] if matches else None


def _mirror_codex_message(session, role: str, content: str, timestamp: datetime | None = None) -> None:
    if not session or session.source_kind != "codex" or not session.source_id:
        return
    target = _codex_session_file(session.source_id)
    if target is None:
        return
    when = (timestamp or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z")
    row = {
        "timestamp": when,
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": role,
            "content": [{"type": "input_text" if role == "user" else "output_text", "text": content}],
            "phase": "mirror",
        },
    }
    with target.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def _sse_event(name: str, data: dict[str, Any]) -> str:
    return f"event: {name}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _load_workspace_labels() -> dict[str, str]:
    path = Path.home() / ".codex" / ".codex-global-state.json"
    if not path.exists():
        return {}
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    labels = payload.get("electron-workspace-root-labels") or {}
    if not isinstance(labels, dict):
        return {}
    result: dict[str, str] = {}
    for key, value in labels.items():
        if isinstance(key, str) and isinstance(value, str) and key.strip() and value.strip():
            result[key.strip()] = value.strip()
    return result


def _normalize_upload_kind(media_type: str | None) -> str:
    value = (media_type or "").lower()
    if value.startswith("image/"):
        return "image"
    if value.startswith("video/"):
        return "video"
    if value.startswith("audio/"):
        return "audio"
    if any(token in value for token in ("pdf", "word", "officedocument", "excel", "sheet", "presentation", "powerpoint", "zip", "json", "text")):
        return "document"
    return "file"


def _build_upload_record(core: AppState, stored_name: str, original_name: str, media_type: str | None) -> UploadRecord:
    target = core.upload_dir / stored_name
    upload_id = stored_name.split("_", 1)[0]
    return UploadRecord(
        id=upload_id,
        name=original_name,
        size=target.stat().st_size if target.exists() else 0,
        media_type=media_type,
        kind=_normalize_upload_kind(media_type),
        local_path=str(target),
        content_url=f"/api/uploads/{upload_id}/content",
    )


def _find_upload_file(core: AppState, upload_id: str) -> Path | None:
    matches = list(core.upload_dir.glob(f"{upload_id}_*"))
    return matches[0] if matches else None


async def _emit_task_event(
    core: AppState,
    task_id: str,
    *,
    session_id: str,
    status: str,
    mode: str,
    provider: str | None = None,
    error: str | None = None,
    stream_text: str | None = None,
    assistant_message=None,
    usage: ProviderUsage | None = None,
) -> None:
    event = ChatTaskEvent(
        task_id=task_id,
        session_id=session_id,
        status=status,
        provider=provider,
        mode=mode,
        error=error,
        stream_text=stream_text,
        assistant_message=assistant_message,
        model=usage.model if usage else None,
        prompt_tokens=usage.prompt_tokens if usage else None,
        completion_tokens=usage.completion_tokens if usage else None,
        total_tokens=usage.total_tokens if usage else None,
        cost=usage.cost if usage else None,
        elapsed_ms=usage.elapsed_ms if usage else None,
    )
    await core.events.publish(task_id, event)


async def _run_chat_task(
    core: AppState,
    task_id: str,
    session_id: str,
    mode: str,
    text: str,
    model: str | None = None,
    reasoning: str | None = None,
) -> None:
    core.logger.info(f"Starting background chat task {task_id} for session {session_id} in mode {mode}")
    try:
        # Mode is already resolved by the caller (start_chat_turn keeps the requested
        # mode when the session has history) — do not downgrade it again here.
        effective_mode = mode
        task = core.sessions.update_chat_task(task_id, status="running", mode=effective_mode)
        await _emit_task_event(
            core,
            task_id,
            session_id=session_id,
            status=task.status,
            mode=task.mode,
            provider=task.provider,
        )

        session = core.sessions.get_session(session_id)
        messages = core.sessions.list_messages(session_id)
        prompt = _build_delegate_prompt(core, session, messages, text)
        loop = asyncio.get_running_loop()
        stream_state = {"text": "", "last_len": 0}

        def publish_stream_chunk(chunk: str) -> None:
            if not chunk:
                return
            stream_state["text"] += chunk
            current = stream_state["text"]
            if len(current) - stream_state["last_len"] < 56 and not current.endswith("\n"):
                return
            stream_state["last_len"] = len(current)
            asyncio.run_coroutine_threadsafe(
                _emit_task_event(
                    core,
                    task_id,
                    session_id=session_id,
                    status="running",
                    mode=task.mode,
                    provider=model or "auto",
                    stream_text=current,
                ),
                loop,
            )

        try:
            core.logger.info(f"Running stream request for task {task_id} with provider {model or 'auto'}")
            result = await asyncio.to_thread(
                core.provider.run_stream,
                mode=effective_mode,
                text=prompt,
                model=model,
                reasoning=reasoning,
                on_stdout=publish_stream_chunk,
            )
            core.logger.info(f"Stream request completed successfully for task {task_id}")
        except Exception as exc:
            core.logger.exception(f"Delegate provider execution failed for task {task_id}")
            assistant_message = core.sessions.append_message(
                session_id=session_id,
                role="assistant",
                content=f"[delegate-error] {exc}",
                provider=model or "delegate-error",
                mode=effective_mode,
            )
            task = core.sessions.update_chat_task(
                task_id,
                status="failed",
                provider=model or "delegate-error",
                error=str(exc),
                assistant_message_id=assistant_message.id,
                completed=True,
            )
            core.sessions.touch_session(session_id)
            await _emit_task_event(
                core,
                task_id,
                session_id=session_id,
                status=task.status,
                mode=task.mode,
                provider=task.provider,
                error=task.error,
                assistant_message=assistant_message,
            )
            return

        if _should_repair_context_failure(messages, text, result.text):
            core.logger.info(f"Repairing context failure for task {task_id}")
            fallback_text = _build_context_failure_fallback(messages, text)
            if fallback_text:
                result = ProviderResult(
                    provider=f"{result.provider or model or 'auto'} -> delegator-core-context",
                    mode=result.mode,
                    text=fallback_text,
                    stderr=result.stderr,
                    exit_code=result.exit_code,
                    usage=result.usage,
                )

        usage = result.usage
        assistant_message = core.sessions.append_message(
            session_id=session_id,
            role="assistant",
            content=result.text,
            provider=result.provider,
            mode=result.mode,
            model=usage.model if usage else None,
            prompt_tokens=usage.prompt_tokens if usage else None,
            completion_tokens=usage.completion_tokens if usage else None,
            total_tokens=usage.total_tokens if usage else None,
            cost=usage.cost if usage else None,
            elapsed_ms=usage.elapsed_ms if usage else None,
        )
        try:
            _mirror_codex_message(session, "assistant", assistant_message.content, assistant_message.created_at)
        except Exception as mirror_exc:
            core.logger.warning(f"Failed to mirror Codex message for session {session_id}: {mirror_exc}")

        task = core.sessions.update_chat_task(
            task_id,
            status="completed",
            provider=result.provider,
            assistant_message_id=assistant_message.id,
            completed=True,
            model=usage.model if usage else None,
            prompt_tokens=usage.prompt_tokens if usage else None,
            completion_tokens=usage.completion_tokens if usage else None,
            total_tokens=usage.total_tokens if usage else None,
            cost=usage.cost if usage else None,
            elapsed_ms=usage.elapsed_ms if usage else None,
        )
        core.sessions.touch_session(session_id)
        await _emit_task_event(
            core,
            task_id,
            session_id=session_id,
            status=task.status,
            mode=task.mode,
            provider=task.provider,
            stream_text=result.text,
            assistant_message=assistant_message,
            usage=usage,
        )
        core.logger.info(f"Task {task_id} completed successfully")

    except Exception as exc:
        core.logger.exception(f"Unhandled exception in background task {task_id}")
        try:
            assistant_message = core.sessions.append_message(
                session_id=session_id,
                role="assistant",
                content=f"[delegate-unhandled-error] {exc}",
                provider=model or "delegate-error",
                mode=mode,
            )
            task = core.sessions.update_chat_task(
                task_id,
                status="failed",
                provider=model or "delegate-error",
                error=str(exc),
                assistant_message_id=assistant_message.id,
                completed=True,
            )
            core.sessions.touch_session(session_id)
            await _emit_task_event(
                core,
                task_id,
                session_id=session_id,
                status=task.status,
                mode=task.mode,
                provider=task.provider,
                error=task.error,
                assistant_message=assistant_message,
            )
        except Exception as inner_exc:
            core.logger.exception(f"Failed to record unhandled task error for task {task_id}: {inner_exc}")


def create_app() -> FastAPI:
    config = load_config()

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        app.state.core = AppState(config)
        yield
        app.state.core.conn.close()

    app = FastAPI(title="Delegator Core", version=__version__, lifespan=lifespan)
    static_dir = Path(__file__).parent / "static"
    app.mount("/assets", StaticFiles(directory=static_dir), name="assets")

    @app.get("/", include_in_schema=False)
    def root():
        core: AppState = app.state.core
        return FileResponse(core.index_file)

    @app.get("/health")
    def health() -> dict[str, object]:
        core: AppState = app.state.core
        return {
            "ok": True,
            "service": "delegator-core",
            "version": __version__,
            "host": core.config.host,
            "port": core.config.port,
            "db_path": str(core.config.db_path),
            "default_mode": core.config.default_mode,
            "delegate_cmd": core.config.shell_delegate_cmd,
        }

    @app.post("/api/restart")
    def restart():
        def do_restart():
            import os
            import sys
            import time
            time.sleep(0.5)
            if os.environ.get("DELEGATOR_SUPERVISED") == "1":
                # The GUI supervisor watches the child and respawns it. os.execv on
                # Windows creates a NEW pid, which would orphan the core from the
                # supervisor's Child handle — a clean exit is the correct restart.
                os._exit(0)
            python = sys.executable
            os.execv(python, [python] + sys.argv)

        import threading
        threading.Thread(target=do_restart, daemon=True).start()
        return {"ok": True, "message": "Server restarting..."}

    @app.get("/api/usage")
    def usage_report(days: int = 7) -> dict[str, Any]:
        core: AppState = app.state.core
        return build_usage_report(core.config.runtime_home / "usage.jsonl", days=days)

    # ── Benchmark (DEV_CONTRACTS section 10) ──
    # The IDE agent drives this: it answers every task itself first, then (in
    # compare mode) the same task through Delegator. Grading happens here and
    # is entirely mechanical - the agent must never grade its own work.

    @app.post("/api/benchmark/start")
    def benchmark_start(payload: dict[str, Any]) -> dict[str, Any]:
        core: AppState = app.state.core
        mode = str(payload.get("mode") or "compare")
        model = str(payload.get("model") or "")
        seed = payload.get("seed")
        return generate_run(
            core.benchmark,
            mode=mode,
            model_label=model,
            seed=int(seed) if seed not in (None, "") else None,
        )

    @app.post("/api/benchmark/answer")
    def benchmark_answer(payload: dict[str, Any]) -> dict[str, Any]:
        core: AppState = app.state.core
        state = core.benchmark.get(str(payload.get("runId") or ""))
        if state is None:
            raise HTTPException(status_code=404, detail="Неизвестный прогон бенчмарка")
        try:
            record_answer(
                state,
                task_index=int(payload.get("task") or 0),
                arm=str(payload.get("arm") or ""),
                text=str(payload.get("answer") or ""),
                elapsed_ms=int(payload.get("elapsedMs") or 0),
            )
        except ValueError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error
        return {"ok": True, "accepted": len(state.answers)}

    @app.post("/api/benchmark/finish")
    def benchmark_finish(payload: dict[str, Any]) -> dict[str, Any]:
        core: AppState = app.state.core
        state = core.benchmark.get(str(payload.get("runId") or ""))
        if state is None:
            raise HTTPException(status_code=404, detail="Неизвестный прогон бенчмарка")
        # Finishing early scores every missing answer as zero and pins the loss
        # on an arm that was never asked. Refuse, and say exactly what is left.
        gaps = missing_answers(state)
        if gaps and not bool(payload.get("force")):
            raise HTTPException(
                status_code=409,
                detail={
                    "error": "incomplete",
                    "message": "Прогон ещё не завершён: не все ответы отправлены",
                    "missing": gaps,
                },
            )
        report = finish_run(core.benchmark, state)
        exported = export_report(report)
        report = dict(report)
        report["files"] = exported
        core.benchmark.save_last(report)
        return report

    @app.post("/api/benchmark/progress")
    def benchmark_progress(payload: dict[str, Any]) -> dict[str, Any]:
        """Where the run is right now. Pinged by benchmark.ps1 before a slow
        step so the GUI shows movement instead of a frozen screen."""
        core: AppState = app.state.core
        state = core.benchmark.get(str(payload.get("runId") or ""))
        if state is None:
            raise HTTPException(status_code=404, detail="Неизвестный прогон бенчмарка")
        state.touch(int(payload.get("task") or 0), str(payload.get("stage") or "waiting"))
        return {"ok": True}

    @app.get("/api/benchmark/status")
    def benchmark_status() -> dict[str, Any]:
        core: AppState = app.state.core
        return {
            "ok": True,
            "benchmarkVersion": BENCHMARK_VERSION,
            "active": run_status(core.benchmark.active()),
        }

    @app.get("/api/benchmark/last")
    def benchmark_last() -> dict[str, Any]:
        core: AppState = app.state.core
        report = core.benchmark.load_last()
        return {
            "ok": True,
            "benchmarkVersion": BENCHMARK_VERSION,
            "report": report,
        }

    @app.post("/api/benchmark/cancel")
    def benchmark_cancel(payload: dict[str, Any]) -> dict[str, Any]:
        """Drops a run nobody is driving any more.

        The benchmark lives in the IDE chat, and that chat can die mid-run — the
        agent hits a "servers are overloaded" error and never calls `finish`.
        Without this the app kept announcing «Бенчмарк идёт» until the run aged
        out an hour later, and no partial result was ever going to arrive.
        """
        core: AppState = app.state.core
        run_id = str(payload.get("runId") or "")
        state = core.benchmark.get(run_id) if run_id else core.benchmark.active()
        if state is None:
            return {"ok": True, "cancelled": None}
        core.benchmark.drop(state.run_id)
        return {
            "ok": True,
            "cancelled": state.run_id,
            "answeredModel": state.answered(ARM_MODEL),
            "tasksTotal": len(state.tasks),
        }

    @app.get("/api/benchmark/items")
    def benchmark_items() -> dict[str, Any]:
        """Difficulty and discrimination per task template, across every run.

        This is what turns a level from an opinion into a measurement: an item
        nobody ever fails measures nothing, and an item that does not separate
        strong runs from weak ones only adds noise. Applying a suggestion
        changes the task set, so it belongs with a BENCHMARK_VERSION bump —
        nothing here rewrites a template by itself.
        """
        core: AppState = app.state.core
        items = load_items(core.benchmark.items_path)
        summary = summarise(items, known_template_ids())
        return {"ok": True, "benchmarkVersion": BENCHMARK_VERSION, **summary}

    @app.post("/api/benchmark/export")
    def benchmark_export(payload: dict[str, Any]) -> dict[str, Any]:
        core: AppState = app.state.core
        report = core.benchmark.load_last()
        if report is None:
            raise HTTPException(status_code=404, detail="Бенчмарк ещё не запускался")
        wanted = payload.get("formats") or ["txt", "png"]
        formats = tuple(str(item) for item in wanted if str(item) in ("txt", "png", "svg"))
        if not formats:
            raise HTTPException(status_code=400, detail="Неизвестный формат экспорта")
        return {"ok": True, "files": export_report(report, formats)}

    @app.get("/api/config")
    def get_config() -> dict[str, object]:
        core: AppState = app.state.core
        return {
            "default_mode": core.config.default_mode,
            "shell_delegate_cmd": core.config.shell_delegate_cmd,
            "shell_timeout_sec": core.config.shell_timeout_sec,
            "home_dir": str(core.config.home_dir),
            "workspace_labels": core.workspace_labels,
        }

    @app.get("/api/sessions")
    def list_sessions():
        core: AppState = app.state.core
        return core.sessions.list_sessions()

    @app.post("/api/sessions")
    def create_session(payload: SessionCreate):
        core: AppState = app.state.core
        return core.sessions.create_session(payload)

    @app.post("/api/import/codex")
    def import_codex(source_id: str | None = None) -> ImportSessionsResponse:
        core: AppState = app.state.core
        codex_res = import_codex_sessions(core.sessions, user_home=Path.home(), source_id=source_id)
        try:
            antigrav_res = import_antigravity_sessions(core.sessions, user_home=Path.home(), source_id=source_id)
            return ImportSessionsResponse(
                source="codex_and_antigravity",
                scanned_files=codex_res.scanned_files + antigrav_res.scanned_files,
                imported_sessions=codex_res.imported_sessions + antigrav_res.imported_sessions,
                updated_sessions=codex_res.updated_sessions + antigrav_res.updated_sessions,
                skipped_sessions=codex_res.skipped_sessions + antigrav_res.skipped_sessions,
                imported_session_ids=codex_res.imported_session_ids + antigrav_res.imported_session_ids,
            )
        except Exception:
            return codex_res

    @app.post("/api/sessions/{session_id}/activate")
    def activate_session(session_id: str):
        core: AppState = app.state.core
        try:
            session = core.sessions.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        if session.workspace_id:
            core.sessions.set_preferred_session_for_workspace(
                workspace_id=session.workspace_id,
                workspace_root=session.workspace_root,
                session_id=session.id,
            )
        return session

    @app.get("/api/workspaces/preferred")
    def get_preferred_workspace_session(
        workspace_id: str | None = None,
        workspace_root: str | None = None,
    ) -> WorkspacePreferredSessionResponse:
        core: AppState = app.state.core
        resolved_workspace_id = workspace_id
        if not resolved_workspace_id and workspace_root:
            normalized = workspace_root.strip().lower()
            if normalized:
                resolved_workspace_id = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:16]
        if not resolved_workspace_id:
            raise HTTPException(status_code=400, detail="workspace_id or workspace_root is required")

        session = core.sessions.get_preferred_session_for_workspace(workspace_id=resolved_workspace_id)
        if session is None:
            session = core.sessions.get_latest_session_for_workspace(workspace_id=resolved_workspace_id)
        if session is None:
            raise HTTPException(status_code=404, detail=f"workspace not found: {resolved_workspace_id}")
        return WorkspacePreferredSessionResponse(
            workspace_id=resolved_workspace_id,
            workspace_root=session.workspace_root,
            session=session,
        )

    @app.get("/api/sessions/{session_id}")
    def get_session(session_id: str):
        core: AppState = app.state.core
        try:
            return core.sessions.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.patch("/api/sessions/{session_id}")
    def update_session(session_id: str, payload: SessionUpdate):
        core: AppState = app.state.core
        try:
            return core.sessions.update_session_metadata(session_id, title=payload.title.strip())
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.get("/api/sessions/{session_id}/messages")
    def list_messages(session_id: str):
        core: AppState = app.state.core
        try:
            core.sessions.get_session(session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return core.sessions.list_messages(session_id)

    @app.post("/api/uploads")
    async def upload_file(file: UploadFile = File(...)) -> UploadRecord:
        core: AppState = app.state.core
        filename = Path(file.filename or "upload.bin").name
        suffix = Path(filename).suffix or mimetypes.guess_extension(file.content_type or "") or ""
        upload_id = uuid.uuid4().hex
        stored_name = f"{upload_id}_{Path(filename).stem}{suffix}"
        target = core.upload_dir / stored_name
        with target.open("wb") as handle:
            shutil.copyfileobj(file.file, handle)
        return _build_upload_record(core, stored_name, filename, file.content_type)

    @app.get("/api/uploads/{upload_id}/content")
    def upload_content(upload_id: str):
        core: AppState = app.state.core
        target = _find_upload_file(core, upload_id)
        if target is None or not target.exists():
            raise HTTPException(status_code=404, detail="upload not found")
        media_type, _ = mimetypes.guess_type(str(target))
        return FileResponse(target, media_type=media_type or "application/octet-stream", filename=target.name.split("_", 1)[-1])

    @app.get("/api/chat/tasks/{task_id}")
    def get_chat_task(task_id: str):
        core: AppState = app.state.core
        try:
            return core.sessions.get_chat_task(task_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

    @app.post("/api/chat/turn/start")
    async def start_chat_turn(payload: ChatTurnRequest) -> ChatTurnStartResponse:
        core: AppState = app.state.core
        try:
            session = core.sessions.get_session(payload.session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

        mode = payload.mode or core.config.default_mode
        existing_messages = core.sessions.list_messages(session.id)
        effective_mode = mode if _session_has_history(existing_messages) else _resolve_execution_mode(mode, payload.text)
        user_message = core.sessions.append_message(
            session_id=session.id,
            role="user",
            content=payload.text,
            mode=effective_mode,
        )
        try:
            _mirror_codex_message(session, "user", user_message.content, user_message.created_at)
        except Exception:
            pass
        local_probe_reply = _build_local_context_probe_reply(existing_messages, payload.text) if _should_use_local_context_probe(existing_messages, payload.text) else None
        if local_probe_reply:
            assistant_message = core.sessions.append_message(
                session_id=session.id,
                role="assistant",
                content=local_probe_reply,
                provider="delegator-core-context",
                mode=effective_mode,
            )
            task = core.sessions.create_chat_task(
                session_id=session.id,
                user_message_id=user_message.id,
                mode=effective_mode,
                provider="delegator-core-context",
                status="completed",
            )
            task = core.sessions.update_chat_task(
                task.id,
                status="completed",
                provider="delegator-core-context",
                assistant_message_id=assistant_message.id,
                completed=True,
            )
            try:
                _mirror_codex_message(session, "assistant", assistant_message.content, assistant_message.created_at)
            except Exception:
                pass
            session = core.sessions.touch_session(session.id)
            await _emit_task_event(
                core,
                task.id,
                session_id=session.id,
                status=task.status,
                mode=task.mode,
                provider=task.provider,
                assistant_message=assistant_message,
            )
            return ChatTurnStartResponse(
                session=session,
                user_message=user_message,
                task=task,
            )
        task = core.sessions.create_chat_task(
            session_id=session.id,
            user_message_id=user_message.id,
            mode=effective_mode,
            provider=payload.model or "auto",
            status="queued",
        )
        await _emit_task_event(
            core,
            task.id,
            session_id=session.id,
            status=task.status,
            mode=task.mode,
        )
        bg_task = asyncio.create_task(
            _run_chat_task(
                core,
                task.id,
                session.id,
                effective_mode,
                payload.text,
                payload.model,
                payload.reasoning,
            )
        )
        core.background_tasks.add(bg_task)
        bg_task.add_done_callback(core.background_tasks.discard)
        session = core.sessions.touch_session(session.id)
        return ChatTurnStartResponse(
            session=session,
            user_message=user_message,
            task=task,
        )

    @app.get("/api/chat/tasks/{task_id}/events")
    async def stream_chat_task_events(task_id: str):
        core: AppState = app.state.core
        try:
            task = core.sessions.get_chat_task(task_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

        async def event_stream():
            if task.status in {"completed", "failed"}:
                assistant_message = None
                if task.assistant_message_id:
                    assistant_message = core.sessions.get_message(task.assistant_message_id)
                event = ChatTaskEvent(
                    task_id=task.id,
                    session_id=task.session_id,
                    status=task.status,
                    provider=task.provider,
                    mode=task.mode,
                    error=task.error,
                    assistant_message=assistant_message,
                )
                yield _sse_event("task", event.model_dump(mode="json"))
                return

            queue = await core.events.subscribe(task_id)
            try:
                initial = ChatTaskEvent(
                    task_id=task.id,
                    session_id=task.session_id,
                    status=task.status,
                    provider=task.provider,
                    mode=task.mode,
                    error=task.error,
                )
                yield _sse_event("task", initial.model_dump(mode="json"))
                while True:
                    event = await queue.get()
                    yield _sse_event("task", event.model_dump(mode="json"))
                    if event.status in {"completed", "failed"}:
                        return
            finally:
                await core.events.unsubscribe(task_id, queue)

        return StreamingResponse(event_stream(), media_type="text/event-stream")

    @app.post("/api/chat/turn")
    def chat_turn(payload: ChatTurnRequest) -> ChatTurnResponse:
        core: AppState = app.state.core
        try:
            session = core.sessions.get_session(payload.session_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc

        mode = payload.mode or core.config.default_mode
        existing_messages = core.sessions.list_messages(session.id)
        effective_mode = mode if _session_has_history(existing_messages) else _resolve_execution_mode(mode, payload.text)
        user_message = core.sessions.append_message(
            session_id=session.id,
            role="user",
            content=payload.text,
            mode=effective_mode,
        )
        try:
            _mirror_codex_message(session, "user", user_message.content, user_message.created_at)
        except Exception:
            pass
        local_probe_reply = _build_local_context_probe_reply(existing_messages, payload.text) if _should_use_local_context_probe(existing_messages, payload.text) else None
        if local_probe_reply:
            assistant_message = core.sessions.append_message(
                session_id=session.id,
                role="assistant",
                content=local_probe_reply,
                provider="delegator-core-context",
                mode=effective_mode,
            )
            try:
                _mirror_codex_message(session, "assistant", assistant_message.content, assistant_message.created_at)
            except Exception:
                pass
            session = core.sessions.touch_session(session.id)
            return ChatTurnResponse(
                session=session,
                user_message=user_message,
                assistant_message=assistant_message,
                provider="delegator-core-context",
                mode=effective_mode,
            )
        try:
            prompt = _build_delegate_prompt(core, session, core.sessions.list_messages(session.id), payload.text)
            result = core.provider.run(mode=effective_mode, text=prompt, model=payload.model, reasoning=payload.reasoning)
        except Exception as exc:
            assistant_message = core.sessions.append_message(
                session_id=session.id,
                role="assistant",
                content=f"[delegate-error] {exc}",
                provider=payload.model or "delegate-error",
                mode=effective_mode,
            )
            session = core.sessions.touch_session(session.id)
            return ChatTurnResponse(
                session=session,
                user_message=user_message,
                assistant_message=assistant_message,
                provider="shell-delegate",
                mode=effective_mode,
            )

        if _should_repair_context_failure(core.sessions.list_messages(session.id), payload.text, result.text):
            fallback_text = _build_context_failure_fallback(core.sessions.list_messages(session.id), payload.text)
            if fallback_text:
                result = ProviderResult(
                    provider=f"{result.provider or payload.model or 'auto'} -> delegator-core-context",
                    mode=result.mode,
                    text=fallback_text,
                    stderr=result.stderr,
                    exit_code=result.exit_code,
                    usage=result.usage,
                )

        turn_usage = result.usage
        assistant_message = core.sessions.append_message(
            session_id=session.id,
            role="assistant",
            content=result.text,
            provider=result.provider,
            mode=result.mode,
            model=turn_usage.model if turn_usage else None,
            prompt_tokens=turn_usage.prompt_tokens if turn_usage else None,
            completion_tokens=turn_usage.completion_tokens if turn_usage else None,
            total_tokens=turn_usage.total_tokens if turn_usage else None,
            cost=turn_usage.cost if turn_usage else None,
            elapsed_ms=turn_usage.elapsed_ms if turn_usage else None,
        )
        try:
            _mirror_codex_message(session, "assistant", assistant_message.content, assistant_message.created_at)
        except Exception:
            pass
        session = core.sessions.touch_session(session.id)
        return ChatTurnResponse(
            session=session,
            user_message=user_message,
            assistant_message=assistant_message,
            provider=result.provider,
            mode=result.mode,
        )

    return app


app = create_app()


def run() -> None:
    config = load_config()
    uvicorn.run(app, host=config.host, port=config.port, reload=False)


if __name__ == "__main__":
    run()

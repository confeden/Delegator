from __future__ import annotations

from delegator_core.main import (
    _message_is_context_probe,
    _message_needs_context,
    _resolve_execution_mode,
)


def test_context_probe_positive_cases() -> None:
    assert _message_is_context_probe("видишь контекст?")
    assert _message_is_context_probe("Видишь контекст нашей беседы?")
    assert _message_is_context_probe("помнишь нашу беседу")
    assert _message_is_context_probe("do you see the context")
    assert _message_is_context_probe("контекст беседы?")


def test_context_probe_rejects_imperative_requests() -> None:
    # These are real work items mentioning the context, not probes.
    assert not _message_is_context_probe("исправь контекст беседы")
    assert not _message_is_context_probe("Fix the chat context loading bug")
    assert not _message_is_context_probe("почини контекст диалога")
    assert not _message_is_context_probe("update the conversation context handling")


def test_context_probe_requires_question_cue_for_short_phrases() -> None:
    # Bare noun phrases without a question cue must not short-circuit.
    assert not _message_is_context_probe("chat context loading bug")
    # But question-shaped ones still count.
    assert _message_is_context_probe("контекст чата?")


def test_needs_context_word_boundary_pronouns() -> None:
    assert _message_needs_context("please fix it")
    assert _message_needs_context("rename them")
    assert not _message_needs_context("visit italy")


def test_resolve_execution_mode_downgrade() -> None:
    assert _resolve_execution_mode("delegate", "hi") == "micro"
    assert _resolve_execution_mode("delegate", "продолжи рефакторинг этой функции") == "delegate"
    assert _resolve_execution_mode("boost", "hi") == "boost"

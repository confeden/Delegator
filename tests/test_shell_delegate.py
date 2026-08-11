from __future__ import annotations

import os
import textwrap
from pathlib import Path

import pytest

from delegator_core.providers.shell_delegate import (
    ShellDelegateProvider,
    _parse_usage_marker,
)


def test_parse_usage_marker_strips_and_parses() -> None:
    stdout = "Answer line one\nline two\n##DELEGATOR_USAGE## " + (
        '{"requestId":"r-1","model":"gemini-flash-latest","provider":"gemini",'
        '"promptTokens":10,"completionTokens":20,"totalTokens":30,"cost":0.5,"elapsedMs":700,"ok":true}'
    )
    text, usage = _parse_usage_marker(stdout)
    assert text == "Answer line one\nline two"
    assert usage is not None
    assert usage.model == "gemini-flash-latest"
    assert usage.prompt_tokens == 10
    assert usage.completion_tokens == 20
    assert usage.total_tokens == 30
    assert usage.cost == 0.5
    assert usage.elapsed_ms == 700
    assert usage.request_id == "r-1"


def test_parse_usage_marker_absent() -> None:
    text, usage = _parse_usage_marker("plain answer")
    assert text == "plain answer"
    assert usage is None


def test_parse_usage_marker_malformed_json() -> None:
    text, usage = _parse_usage_marker("answer\n##DELEGATOR_USAGE## {broken")
    assert text == "answer"
    assert usage is None


@pytest.mark.skipif(os.name != "nt", reason="requires powershell.exe")
def test_transport_preserves_multiline_cyrillic_and_percent(tmp_path: Path) -> None:
    """End-to-end regression for the .cmd transport bugs: the prompt must reach the
    delegate byte-for-byte (newlines, Cyrillic, %VAR%, quotes) and the usage marker
    must be parsed out of the stream."""
    stub = tmp_path / "ai-delegate.ps1"
    stub.write_text(
        textwrap.dedent(
            """
            param(
                [Parameter(Position = 0)] [string]$Mode,
                [string]$PromptFile,
                [string]$Model
            )
            $prompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
            $stdout = [System.Console]::OpenStandardOutput()
            $writer = New-Object System.IO.StreamWriter($stdout, (New-Object System.Text.UTF8Encoding($false)))
            $writer.WriteLine("ECHO-BEGIN")
            $writer.WriteLine($prompt)
            $writer.WriteLine("ECHO-END")
            if ($env:DELEGATOR_EMIT_USAGE -eq '1') {
                $marker = '##DELEGATOR_USAGE## {"requestId":"' + $env:DELEGATOR_REQUEST_ID + '","model":"stub-model","provider":"stub","promptTokens":1,"completionTokens":2,"totalTokens":3,"cost":0,"elapsedMs":5,"ok":true}'
                $writer.WriteLine($marker)
            }
            $writer.Flush()
            exit 0
            """
        ).strip(),
        encoding="utf-8-sig",
    )
    cmd_path = tmp_path / "ai-delegate.cmd"
    cmd_path.write_text("@echo off\r\n", encoding="ascii")

    provider = ShellDelegateProvider(command=str(cmd_path), timeout_sec=60)
    prompt = "Первая строка по-русски\nSecond line with %PATH% and \"quotes\"\nТретья строка"
    chunks: list[str] = []
    result = provider.run_stream(mode="ask", text=prompt, on_stdout=chunks.append)

    assert "ECHO-BEGIN" in result.text
    assert prompt in result.text.replace("\r\n", "\n")
    assert "##DELEGATOR_USAGE##" not in result.text
    streamed = "".join(chunks)
    assert "##DELEGATOR_USAGE##" not in streamed
    assert result.usage is not None
    assert result.usage.model == "stub-model"
    assert result.usage.total_tokens == 3

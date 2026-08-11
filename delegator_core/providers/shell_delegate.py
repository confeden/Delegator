from __future__ import annotations

import json
import logging
import os
import queue
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

from .base import ProviderResult, ProviderUsage, StreamCallback

USAGE_MARKER = "##DELEGATOR_USAGE##"


def _kill_process_tree(pid: int, logger: logging.Logger) -> None:
    """Kill the whole child tree: plain kill() leaves powershell.exe grandchildren
    alive, still holding model locks and burning API quota."""
    try:
        subprocess.run(
            ["taskkill", "/PID", str(pid), "/T", "/F"],
            capture_output=True,
            timeout=15,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    except Exception as exc:
        logger.warning(f"taskkill of process tree {pid} failed: {exc}")


def _parse_usage_marker(stdout: str) -> tuple[str, ProviderUsage | None]:
    """Strip the trailing ##DELEGATOR_USAGE## marker line from stdout and parse it."""
    usage: ProviderUsage | None = None
    kept_lines: list[str] = []
    for line in stdout.splitlines():
        stripped = line.strip()
        if stripped.startswith(USAGE_MARKER):
            payload = stripped[len(USAGE_MARKER):].strip()
            try:
                data = json.loads(payload)
                usage = ProviderUsage(
                    model=data.get("model"),
                    provider=data.get("provider"),
                    prompt_tokens=_as_int(data.get("promptTokens")),
                    completion_tokens=_as_int(data.get("completionTokens")),
                    total_tokens=_as_int(data.get("totalTokens")),
                    cost=_as_float(data.get("cost")),
                    elapsed_ms=_as_int(data.get("elapsedMs")),
                    request_id=data.get("requestId"),
                )
            except (json.JSONDecodeError, TypeError):
                pass
            continue
        kept_lines.append(line)
    return "\n".join(kept_lines).strip(), usage


def _as_int(value) -> int | None:
    try:
        if value is None:
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_float(value) -> float | None:
    try:
        if value is None:
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


class ShellDelegateProvider:
    def __init__(self, command: str, timeout_sec: int) -> None:
        self.command = command
        self.timeout_sec = timeout_sec
        self.logger = logging.getLogger("delegator_core.providers.shell_delegate")

    def _delegate_script(self) -> Path | None:
        """Sibling ai-delegate.ps1 of the configured .cmd entry point.

        Prompts must NOT be routed through the .cmd: cmd.exe truncates argv at the
        first newline, expands %VAR% sequences, and re-interprets metacharacters.
        """
        cmd_path = Path(self.command)
        candidate = cmd_path.with_suffix(".ps1")
        if candidate.exists():
            return candidate
        return None

    def run(self, *, mode: str, text: str, model: str | None = None, reasoning: str | None = None) -> ProviderResult:
        return self.run_stream(mode=mode, text=text, model=model, reasoning=reasoning)

    def run_stream(
        self,
        *,
        mode: str,
        text: str,
        model: str | None = None,
        reasoning: str | None = None,
        on_stdout: StreamCallback | None = None,
        on_stderr: StreamCallback | None = None,
    ) -> ProviderResult:
        request_id = f"r-{uuid.uuid4().hex[:8]}"
        prompt_file = self._write_prompt_file(text)
        script = self._delegate_script()
        if script is not None:
            args = [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(script),
                mode,
                "-PromptFile",
                str(prompt_file),
            ]
        else:
            # Fallback for exotic setups where only the .cmd exists. Single-line
            # prompts only — the .cmd transport is unsafe for anything else.
            args = [self.command, mode, "-PromptFile", str(prompt_file)]
        if model:
            args.extend(["-Model", model])
        env = os.environ.copy()
        env["DELEGATOR_EMIT_USAGE"] = "1"
        env["DELEGATOR_REQUEST_ID"] = request_id
        env["DELEGATOR_CLIENT"] = "core"
        if reasoning:
            env["CODEX_OPENCODE_VARIANT"] = reasoning
        self.logger.info(f"Starting delegate subprocess ({request_id}): {args}")
        try:
            process = subprocess.Popen(
                args,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                shell=False,
                env=env,
                bufsize=1,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
        except Exception as exc:
            self.logger.error(f"Failed to start subprocess: {exc}")
            self._cleanup_prompt_file(prompt_file)
            raise
        try:
            return self._pump_process(
                process,
                mode=mode,
                model=model,
                on_stdout=on_stdout,
                on_stderr=on_stderr,
            )
        finally:
            self._cleanup_prompt_file(prompt_file)

    def _write_prompt_file(self, text: str) -> Path:
        handle = tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            prefix="delegator-prompt-",
            suffix=".txt",
            delete=False,
        )
        try:
            handle.write(text)
        finally:
            handle.close()
        return Path(handle.name)

    def _cleanup_prompt_file(self, path: Path) -> None:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            pass

    def _pump_process(
        self,
        process: subprocess.Popen,
        *,
        mode: str,
        model: str | None,
        on_stdout: StreamCallback | None,
        on_stderr: StreamCallback | None,
    ) -> ProviderResult:
        stdout_parts: list[str] = []
        stderr_parts: list[str] = []
        events: queue.Queue[tuple[str, str | None]] = queue.Queue()

        def reader(stream, kind: str) -> None:
            try:
                while True:
                    chunk = stream.read(1)
                    if chunk == "":
                        break
                    events.put((kind, chunk))
            finally:
                events.put((kind, None))

        threads = [
            threading.Thread(target=reader, args=(process.stdout, "stdout"), daemon=True),
            threading.Thread(target=reader, args=(process.stderr, "stderr"), daemon=True),
        ]
        for thread in threads:
            thread.start()

        # The usage marker is machine metadata: hold back any line that could be
        # the marker so it never reaches the user-visible stream.
        stream_guard = {"buffer": ""}

        def forward_stdout(chunk: str) -> None:
            if on_stdout is None:
                return
            buffered = stream_guard["buffer"] + chunk
            emit = ""
            while True:
                newline_at = buffered.find("\n")
                if newline_at < 0:
                    break
                line = buffered[: newline_at + 1]
                buffered = buffered[newline_at + 1:]
                if not line.strip().startswith(USAGE_MARKER):
                    emit += line
            partial = buffered.lstrip()
            could_be_marker = bool(partial) and (
                USAGE_MARKER.startswith(partial) or partial.startswith(USAGE_MARKER)
            )
            if buffered and not could_be_marker:
                emit += buffered
                buffered = ""
            stream_guard["buffer"] = buffered
            if emit:
                on_stdout(emit)

        completed_streams = 0
        deadline = time.monotonic() + float(self.timeout_sec)
        while completed_streams < 2:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _kill_process_tree(process.pid, self.logger)
                raise TimeoutError(f"delegate command timed out after {self.timeout_sec} sec")
            try:
                kind, chunk = events.get(timeout=min(0.2, remaining))
            except queue.Empty:
                if process.poll() is not None:
                    # Parent process has exited. Drain remaining bytes and break
                    # to avoid hanging on orphan grandchild processes.
                    time.sleep(0.1)
                    while not events.empty():
                        try:
                            kind, chunk = events.get_nowait()
                            if chunk is None:
                                completed_streams += 1
                            elif kind == "stdout":
                                stdout_parts.append(chunk)
                                forward_stdout(chunk)
                            else:
                                stderr_parts.append(chunk)
                                if on_stderr:
                                    on_stderr(chunk)
                        except queue.Empty:
                            break
                    break
                continue
            if chunk is None:
                completed_streams += 1
                continue
            if kind == "stdout":
                stdout_parts.append(chunk)
                forward_stdout(chunk)
            else:
                stderr_parts.append(chunk)
                if on_stderr:
                    on_stderr(chunk)

        for thread in threads:
            thread.join(timeout=0.2)
        return_code = process.wait(timeout=1)
        raw_stdout = "".join(stdout_parts).strip()
        stderr = "".join(stderr_parts).strip()
        text, usage = _parse_usage_marker(raw_stdout)
        if return_code != 0:
            raise RuntimeError(
                f"delegate command failed with exit code {return_code}: {stderr or text or '<no output>'}"
            )
        provider_label = model or "auto"
        if usage and usage.model:
            provider_label = usage.model
        return ProviderResult(
            provider=provider_label,
            mode=mode,
            text=text,
            stderr=stderr,
            exit_code=return_code,
            usage=usage,
        )

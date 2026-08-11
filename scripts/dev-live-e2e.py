"""Manual live end-to-end smoke test for the dev tree (costs a little free-model quota).

Starts the dev core on a scratch port/db, runs one real chat turn through the dev
PowerShell runtime, and prints what came back (answer preview, usage fields, /api/usage).

Usage:  .venv312\\Scripts\\python.exe scripts\\dev-live-e2e.py
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

REPO = Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DELEGATOR_E2E_PORT", "1385"))
BASE = f"http://127.0.0.1:{PORT}"


def api(method: str, path: str, payload: dict | None = None, timeout: float = 240.0):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(
        BASE + path,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def main() -> int:
    scratch = Path(tempfile.mkdtemp(prefix="delegator-e2e-"))
    env = os.environ.copy()
    env.update(
        {
            "DELEGATOR_CORE_PORT": str(PORT),
            "DELEGATOR_CORE_HOME": str(scratch / "core"),
            "DELEGATOR_CORE_DELEGATE_CMD": str(REPO / "scripts" / "ai-delegate.cmd"),
            "DELEGATOR_CORE_SHELL_TIMEOUT_SEC": "220",
        }
    )
    core = subprocess.Popen(
        [sys.executable, str(REPO / "run_server.py")],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    try:
        for _ in range(60):
            try:
                health = api("GET", "/health", timeout=2)
                break
            except Exception:
                time.sleep(0.5)
        else:
            print("FAIL: core did not become healthy")
            return 1
        print(f"health: ok service={health['service']} version={health['version']}")

        session = api("POST", "/api/sessions", {"title": "e2e live test"})
        prompt = (
            "Ответь по-русски одним коротким абзацем: какие три главных принципа "
            "надёжного логирования в серверных приложениях? Это живой тест системы "
            "делегирования, проверяющий кириллицу и передачу многострочного текста.\n"
            "Вторая строка промпта: проверка перевода строки и символов %PATH% и \"кавычек\".\n"
            f"Уникальный маркер запуска (не упоминай его в ответе): {int(time.time())}"
        )
        print("sending chat turn (delegate mode, live model call)...")
        started = time.time()
        turn = api(
            "POST",
            "/api/chat/turn",
            {"session_id": session["id"], "text": prompt, "mode": "delegate"},
        )
        elapsed = time.time() - started
        assistant = turn["assistant_message"]
        text = (assistant.get("content") or "").strip()
        print(f"turn completed in {elapsed:.1f}s; provider={turn.get('provider')}")
        print(f"answer preview: {text[:220]!r}")
        usage_fields = {
            k: assistant.get(k)
            for k in ("model", "prompt_tokens", "completion_tokens", "total_tokens", "cost", "elapsed_ms")
        }
        print(f"assistant usage fields: {usage_fields}")

        report = api("GET", "/api/usage?days=1")
        today = report.get("today", {})
        print(
            "usage report today: requests={} totalTokens={} savedTotal={}".format(
                today.get("requests"), today.get("totalTokens"), report.get("savedTokensTotal")
            )
        )
        by_model = report.get("byModel", [])[:3]
        for row in by_model:
            print(f"  model={row.get('model')} requests={row.get('requests')} tokens={row.get('totalTokens')}")

        problems = []
        if not text or text.startswith("[delegate-error]"):
            problems.append(f"assistant answer is an error: {text[:200]}")
        if not any("Ѐ" <= ch <= "ӿ" for ch in text):
            problems.append("answer contains no Cyrillic (language routing suspect)")
        if usage_fields.get("total_tokens") in (None, 0):
            problems.append("no token usage propagated to the assistant message")
        if problems:
            print("RESULT: FAIL")
            for p in problems:
                print("  -", p)
            return 1
        print("RESULT: PASS")
        return 0
    finally:
        try:
            subprocess.run(
                ["taskkill", "/PID", str(core.pid), "/T", "/F"],
                capture_output=True,
                timeout=15,
            )
        except Exception:
            core.kill()


if __name__ == "__main__":
    raise SystemExit(main())

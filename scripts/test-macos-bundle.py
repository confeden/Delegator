#!/usr/bin/env python3
"""Exercise a packaged macOS core without touching the user's data or keys."""
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


def check_bundle(app: Path) -> None:
    resources = app / "Contents/Resources"
    runtime = resources / "runtime"
    core = app / "Contents/MacOS/delegator-core"
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("DELEGATOR_", "PYTHON", "DYLD_"))}
    # A clean PATH prevents accidentally depending on Homebrew or developer
    # tools. The bundle must supply its own Python and PowerShell.
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    subprocess.run([runtime / "python/python3", "-I", "-c",
                    "import ssl,sqlite3,ctypes; print(ssl.OPENSSL_VERSION)"],
                   env=env, check=True, timeout=30)
    subprocess.run([resources / "powershell/pwsh", "-NoLogo", "-NoProfile",
                    "-NonInteractive", "-Command", "$PSVersionTable.PSVersion.ToString()"],
                   env=env, check=True, timeout=30)
    with tempfile.TemporaryDirectory(prefix="delegator-bundle-test-") as directory:
        state = Path(directory)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        env.update({
            "DELEGATOR_CORE_HOST": "127.0.0.1",
            "DELEGATOR_CORE_PORT": str(port),
            "DELEGATOR_CORE_HOME": str(state / "core"),
            "DELEGATOR_RUNTIME_HOME": str(state / "runtime"),
            "DELEGATOR_RUNTIME_DIR": str(runtime),
            "DELEGATOR_CORE_DELEGATE_CMD": str(runtime / "ai-delegate"),
            "DELEGATOR_CONFIG_FILE": str(state / "config.json"),
        })
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        base_url = f"http://127.0.0.1:{port}"
        with (state / "startup.log").open("w+") as log:
            process = subprocess.Popen([core], cwd=core.parent, env=env,
                                       stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic() + 60
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"Packaged core exited with {process.returncode}")
                    try:
                        with opener.open(base_url + "/health", timeout=2) as response:
                            health = json.load(response)
                        break
                    except (urllib.error.URLError, TimeoutError):
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Packaged core did not become healthy within 60 seconds")
                        time.sleep(0.2)
                if not (health.get("ok") is True
                        and health.get("service") == "delegator-core"
                        and health.get("delegate_cmd") == str(runtime / "ai-delegate")):
                    raise RuntimeError(f"Unexpected packaged core health: {health}")
                for path in ("/", "/assets/app.js", "/api/usage"):
                    with opener.open(base_url + path, timeout=5) as response:
                        if not response.read():
                            raise RuntimeError(f"Empty response from {path}")
                request = urllib.request.Request(
                    base_url + "/api/route", data=json.dumps({"prompt": "hello"}).encode(),
                    headers={"Content-Type": "application/json"})
                with opener.open(request, timeout=5) as response:
                    decision = json.load(response)
                if decision.get("mode") not in ("keep", "improve", "delegate", "boost"):
                    raise RuntimeError(f"Unexpected router response: {decision}")
                print(f"Bundle smoke test passed: core {health['version']}, assets, usage and router")
            except Exception:
                log.flush()
                log.seek(0)
                print(log.read(), flush=True)
                raise
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    check_bundle(parser.parse_args().app.resolve())

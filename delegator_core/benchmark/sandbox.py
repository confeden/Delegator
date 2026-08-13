"""Executes candidate code in a separate process.

The code being run was written by a language model, so it never runs inside the
core: it goes to a child process with a timeout and a result file. On an
installed machine there is no Python interpreter, so the child is THIS
executable re-invoked with `--benchmark-exec` (the frozen core carries its own
Python runtime). The result travels through a file, not stdout, because the
packaged core is windowed and its standard streams may not exist.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

EXEC_FLAG = "--benchmark-exec"
DEFAULT_TIMEOUT_SEC = 25
CREATE_NO_WINDOW = 0x08000000

# Where the generated harness appends one JSON line per finished check. It is a
# FILE and not stdout on purpose: a candidate that hangs on the sixth constraint
# is killed with its output still buffered, and the five constraints it did
# satisfy must still count. That is the difference between "wrong" and "slow".
CHECKS_ENV = "DELEGATOR_BENCH_CHECKS"


def run_candidate(source: str, timeout_sec: int = DEFAULT_TIMEOUT_SEC) -> dict:
    """Runs `source` and reports how it ended.

    Returns {"status": "ok|error|timeout|crashed", "stdout": str, "stderr": str,
    "checks": [{"id", "ok", "note"}]} — `checks` holds whatever the harness
    managed to record, including after a timeout.
    """
    work_dir = Path(tempfile.gettempdir()) / "delegator-benchmark"
    work_dir.mkdir(parents=True, exist_ok=True)
    stamp = uuid.uuid4().hex[:10]
    script_path = work_dir / f"case-{stamp}.py"
    result_path = work_dir / f"case-{stamp}.json"
    checks_path = work_dir / f"case-{stamp}.checks.jsonl"
    script_path.write_text(source, encoding="utf-8")

    child_env = os.environ.copy()
    child_env[CHECKS_ENV] = str(checks_path)

    command = _child_command(script_path, result_path)
    try:
        completed = subprocess.run(
            command,
            timeout=timeout_sec,
            capture_output=True,
            env=child_env,
            creationflags=CREATE_NO_WINDOW if os.name == "nt" else 0,
        )
    except subprocess.TimeoutExpired:
        checks = read_checks(checks_path)
        _cleanup(script_path, result_path, checks_path)
        return {
            "status": "timeout",
            "stdout": "",
            "stderr": "превышено время выполнения",
            "checks": checks,
        }
    except OSError as error:
        _cleanup(script_path, result_path, checks_path)
        return {"status": "crashed", "stdout": "", "stderr": str(error), "checks": []}

    try:
        checks = read_checks(checks_path)
        if result_path.exists():
            payload = json.loads(result_path.read_text(encoding="utf-8"))
            return {
                "status": str(payload.get("status", "error")),
                "stdout": str(payload.get("stdout", "")),
                "stderr": str(payload.get("stderr", "")),
                "checks": checks,
            }
        # No result file: the child died before it could write one.
        return {
            "status": "crashed",
            "stdout": completed.stdout.decode("utf-8", "replace") if completed.stdout else "",
            "stderr": completed.stderr.decode("utf-8", "replace") if completed.stderr else "",
            "checks": checks,
        }
    finally:
        _cleanup(script_path, result_path, checks_path)


def read_checks(path: Path) -> list[dict]:
    """Whatever the harness wrote before it finished or was killed."""
    try:
        raw = Path(path).read_text(encoding="utf-8")
    except OSError:
        return []
    out: list[dict] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get("id"):
            out.append(entry)
    return out


def _child_command(script_path: Path, result_path: Path) -> list[str]:
    if getattr(sys, "frozen", False):
        return [sys.executable, EXEC_FLAG, str(script_path), str(result_path)]
    return [sys.executable, "-m", "delegator_core.benchmark.sandbox", EXEC_FLAG,
            str(script_path), str(result_path)]


def _cleanup(*paths: Path) -> None:
    for path in paths:
        try:
            path.unlink()
        except OSError:
            pass


def exec_child(script_path: str, result_path: str) -> int:
    """Child-side entry point: run the script, write the outcome, never raise."""
    import contextlib
    import io
    import runpy
    import traceback

    out, err = io.StringIO(), io.StringIO()
    status = "ok"
    try:
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            runpy.run_path(script_path, run_name="__main__")
    except SystemExit as exc:  # a candidate may call sys.exit()
        if exc.code not in (0, None):
            status = "error"
            err.write(f"SystemExit: {exc.code}")
    except BaseException:  # noqa: BLE001 - any failure is a failed answer, not a crash of ours
        status = "error"
        err.write(traceback.format_exc())
    payload = {
        "status": status,
        "stdout": out.getvalue()[-4000:],
        "stderr": err.getvalue()[-4000:],
    }
    Path(result_path).write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    return 0


def maybe_run_as_child(argv: list[str]) -> bool:
    """True when this process was started only to execute one candidate."""
    if len(argv) >= 4 and argv[1] == EXEC_FLAG:
        exec_child(argv[2], argv[3])
        return True
    return False


if __name__ == "__main__":
    if not maybe_run_as_child(sys.argv):
        print("nothing to do", file=sys.stderr)
        sys.exit(2)

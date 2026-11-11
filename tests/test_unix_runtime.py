"""Exercise the real PowerShell/OpenCode transport without a network provider."""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

PWSH = os.environ.get("DELEGATOR_PWSH") or shutil.which("pwsh")
ROOT = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.skipif(os.name == "nt" or not PWSH, reason="Unix PowerShell transport")


@pytest.mark.parametrize("reply_kind", ["text", "empty", "canned"])
def test_opencode_child_preserves_prompt_and_paths(tmp_path, reply_kind):
    install = tmp_path / "Приложение with spaces ' quotes"
    runtime = install / "runtime"
    shutil.copytree(ROOT / "scripts", runtime)
    state = tmp_path / "state with spaces"
    state.mkdir()
    config = tmp_path / "config.json"
    config.write_text(json.dumps({"enabled_opencode_models": ["opencode/big-pickle"]}))
    cli_dir = tmp_path / "bin"
    cli_dir.mkdir()
    cli = cli_dir / "opencode"
    cli.write_text(
        f"#!{sys.executable}\n"
        "import json, os, sys\n"
        "if sys.argv[1] == 'models':\n"
        "    print('opencode/big-pickle')\n"
        "else:\n"
        "    config = json.loads(os.environ['OPENCODE_CONFIG_CONTENT'])\n"
        "    assert sys.argv[sys.argv.index('--agent') + 1] == 'delegate-text'\n"
        "    assert config['default_agent'] == 'delegate-text'\n"
        "    assert config['agent']['delegate-text']['permission']['*'] == 'deny'\n"
        "    with open(os.environ['DELEGATOR_TEST_CALLS'], 'a') as log:\n"
        "        log.write('called\\n')\n"
        "    kind = os.environ['DELEGATOR_TEST_REPLY_KIND']\n"
        "    if kind != 'empty':\n"
        "        answer = 'ECHO:' + sys.argv[-1] if kind == 'text' else \"I don't see a specific request to solve.\"\n"
        "        print(json.dumps({'type':'text','part':{'text':answer}}))\n"
        "    print(json.dumps({'type':'step_finish','part':{'tokens':{'input':11,'output':7},'cost':0}}))\n",
        encoding="utf-8",
    )
    cli.chmod(0o755)
    prompt = 'Первая строка\n%PATH% $(echo unexpanded) "quotes" & shell; third line'
    result = subprocess.run(
        [str(PWSH), "-NoLogo", "-NoProfile", "-File", str(runtime / "opencode-delegate.ps1"),
         "ask", prompt, "-Model", "opencode/big-pickle", "-Json", "-TimeoutSec", "20"],
        env={**os.environ, "PATH": str(cli_dir) + os.pathsep + os.environ.get("PATH", ""),
             "DELEGATOR_RUNTIME_HOME": str(state), "DELEGATOR_CONFIG_FILE": str(config),
             "DELEGATOR_PWSH": str(PWSH), "DELEGATOR_TEST_REPLY_KIND": reply_kind,
             "DELEGATOR_TEST_CALLS": str(tmp_path / "calls.txt")},
        capture_output=True, text=True, timeout=45,
    )
    assert (tmp_path / "calls.txt").read_text().splitlines() == ["called"]
    assert not list(state.glob("opencode-prompt-*.txt"))
    assert not list(state.glob("opencode-run-*.ps1"))
    if reply_kind != "text":
        assert result.returncode != 0
        assert "All opencode models failed" in result.stderr + result.stdout
        usage = [json.loads(line) for line in (state / "usage.jsonl").read_text().splitlines()]
        assert len(usage) == 1
        assert usage[0]["ok"] is False
        events = [json.loads(line) for line in (state / "runs.jsonl").read_text().splitlines()]
        failure = next(event for event in events if event["event"] == "attempt_failed")
        assert failure["exitCode"] == 1
        assert "no useful answer text" in failure["errorPreview"]
        return
    assert result.returncode == 0, result.stderr + result.stdout
    data = json.loads(result.stdout)
    assert prompt in data["output"]
    assert data["executionPath"] == "opencode-cli"
    assert data["promptTokens"] == 11
    assert data["completionTokens"] == 7

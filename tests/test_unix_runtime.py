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


def test_opencode_child_preserves_prompt_and_paths(tmp_path):
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
        "import json, sys\n"
        "if sys.argv[1] == 'models':\n"
        "    print('opencode/big-pickle')\n"
        "else:\n"
        "    print(json.dumps({'type':'text','part':{'text':'ECHO:' + sys.argv[-1]}}))\n"
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
             "DELEGATOR_PWSH": str(PWSH)},
        capture_output=True, text=True, timeout=45,
    )
    assert result.returncode == 0, result.stderr + result.stdout
    data = json.loads(result.stdout)
    assert prompt in data["output"]
    assert data["executionPath"] == "opencode-cli"
    assert data["promptTokens"] == 11
    assert data["completionTokens"] == 7
    assert not list(state.glob("opencode-prompt-*.txt"))
    assert not list(state.glob("opencode-run-*.ps1"))

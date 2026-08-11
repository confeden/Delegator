from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from pathlib import Path


def _default_install_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def _default_data_root() -> Path:
    local_appdata = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA")
    if local_appdata:
        return Path(local_appdata) / "DelegatorWin"
    return Path.home() / ".delegator"


DEFAULT_HOME = _default_data_root() / "core"


@dataclass(frozen=True)
class CoreConfig:
    host: str
    port: int
    home_dir: Path
    db_path: Path
    default_mode: str
    shell_delegate_cmd: str
    shell_timeout_sec: int
    runtime_home: Path


def _default_runtime_home() -> Path:
    """Mirror the PowerShell runtime's state-dir resolution (delegator-common.ps1)."""
    override = os.environ.get("DELEGATOR_RUNTIME_HOME")
    if override:
        return Path(override)
    return _default_data_root() / "runtime"


def load_config() -> CoreConfig:
    home_dir = Path(os.environ.get("DELEGATOR_CORE_HOME", DEFAULT_HOME))
    db_path = Path(os.environ.get("DELEGATOR_CORE_DB", home_dir / "delegator-core.db"))
    runtime_dir = Path(
        os.environ.get("DELEGATOR_RUNTIME_DIR", _default_install_root() / "runtime")
    )
    return CoreConfig(
        host=os.environ.get("DELEGATOR_CORE_HOST", "127.0.0.1"),
        port=int(os.environ.get("DELEGATOR_CORE_PORT", "1380")),
        home_dir=home_dir,
        db_path=db_path,
        default_mode=os.environ.get("DELEGATOR_CORE_DEFAULT_MODE", "delegate"),
        shell_delegate_cmd=os.environ.get(
            "DELEGATOR_CORE_DELEGATE_CMD",
            str(runtime_dir / "ai-delegate.cmd"),
        ),
        shell_timeout_sec=int(os.environ.get("DELEGATOR_CORE_SHELL_TIMEOUT_SEC", "180")),
        runtime_home=_default_runtime_home(),
    )

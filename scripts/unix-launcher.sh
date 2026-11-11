#!/bin/sh
set -eu
runtime_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir=$(dirname -- "$runtime_dir")
binary_dir="$install_dir"
if [ -d "$install_dir/../MacOS" ]; then
    binary_dir=$(CDPATH= cd -- "$install_dir/../MacOS" && pwd)
fi
entry_name=$(basename -- "$0")
export PATH="$HOME/.opencode/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export DELEGATOR_SECRET_HELPER="${DELEGATOR_SECRET_HELPER:-$binary_dir/delegator}"
export DELEGATOR_CORE_EXE="${DELEGATOR_CORE_EXE:-$binary_dir/delegator-core}"
export DELEGATOR_PWSH="${DELEGATOR_PWSH:-$install_dir/powershell/pwsh}"
export DELEGATOR_CLIENT="${DELEGATOR_CLIENT:-ide}"
if [ ! -x "$DELEGATOR_PWSH" ]; then
    if command -v pwsh >/dev/null 2>&1; then
        DELEGATOR_PWSH=$(command -v pwsh)
        export DELEGATOR_PWSH
    else
        echo 'Delegator: bundled PowerShell runtime was not found.' >&2
        exit 2
    fi
fi
exec "$DELEGATOR_PWSH" -NoLogo -NoProfile -NonInteractive -File "$runtime_dir/$entry_name.ps1" "$@"

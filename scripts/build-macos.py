#!/usr/bin/env python3
"""Build the modified macOS edition locally; no system-wide installs.

Usage: python3 scripts/build-macos.py [--skip-tests] [--debug] [--no-dmg]
Build separately on Intel and Apple Silicon; this does not cross-compile.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "target/tools"
PWSH_VERSION = "7.4.22"
PWSH_SHA256 = {
    "x64": "09a7af0ec9ecac489725e9c22343c6ca33ee35d02a448f6ee20f596fdd2e2446",
    "arm64": "afd9b5dc4aa1934f4a2bab906efc443f7e576e4ba501f3d355b121e3f6ec3c1a",
}


def run(*args, **kwargs):
    print("+", " ".join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT, **kwargs)


def powershell(arch: str) -> Path:
    archive = TOOLS / f"powershell-{PWSH_VERSION}-osx-{arch}.tar.gz"
    TOOLS.mkdir(parents=True, exist_ok=True)
    if not archive.is_file():
        url = f"https://github.com/PowerShell/PowerShell/releases/download/v{PWSH_VERSION}/{archive.name}"
        urllib.request.urlretrieve(url, archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != PWSH_SHA256[arch]:
        raise SystemExit(f"PowerShell archive checksum mismatch: {archive}")
    output = TOOLS / f"powershell-{arch}"
    if not (output / "pwsh").is_file():
        output.mkdir(parents=True, exist_ok=True)
        with tarfile.open(archive) as package:
            package.extractall(output, filter="data")
        (output / "pwsh").chmod(0o755)
    run(output / "pwsh", "-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion.ToString()")
    return output


def bundle_python(python: Path, output: Path):
    """Relocate a framework CPython, including its stdlib, for the coding benchmark.

    Only the developer's interpreter is copied. User packages, profiles and
    credentials are excluded. Every Python dependency is made bundle-relative.
    """
    info = run(python, "-c", "import json,sys,sysconfig; print(json.dumps([sys.base_prefix, sysconfig.get_path('stdlib'), sysconfig.get_python_version()]))",
               capture_output=True, text=True)
    import json
    prefix, stdlib, version = json.loads(info.stdout)
    prefix = Path(prefix)
    stdlib = Path(stdlib)
    library = prefix / "Python"
    if not library.is_file():
        raise SystemExit("Build with a framework Python from python.org (Python 3.12+).")
    (output / "bin").mkdir(parents=True)
    (output / "lib").mkdir()
    executable = output / "bin/python3"
    # Framework bin/python is a launcher which re-execs Resources/Python.app.
    # Relocate the actual interpreter so it needs no system framework layout.
    shutil.copy2(prefix / "Resources/Python.app/Contents/MacOS/Python", executable)
    shutil.copy2(library, output / f"lib/libpython{version}.dylib")
    skipped = shutil.ignore_patterns("site-packages", "__pycache__", "test", "tests", "idlelib",
                                     "tkinter", "turtledemo", "ensurepip", "config-*", "_test*", "_tkinter*")
    shutil.copytree(stdlib, output / f"lib/python{version}", ignore=skipped)
    for lib in (prefix / "lib").glob("*.dylib"):
        if not lib.name.startswith("libpython") and not lib.is_symlink():
            shutil.copy2(lib, output / "lib" / lib.name)
    # Match all names used by extensions, including the unversioned aliases.
    for lib in (prefix / "lib").glob("*.dylib"):
        if lib.is_symlink() and not lib.name.startswith("libpython"):
            destination = output / "lib" / lib.name
            if not destination.exists():
                destination.symlink_to(lib.resolve().name)
    binaries = [executable, *output.rglob("*.so"), *output.rglob("*.dylib")]
    for binary in binaries:
        if binary.is_symlink():
            continue
        deps = run("otool", "-L", binary, capture_output=True, text=True).stdout
        for line in deps.splitlines()[1:]:
            old = line.strip().split(" (compatibility", 1)[0]
            if not old.startswith(str(prefix) + "/"):
                continue
            relative = Path(old).relative_to(prefix)
            destination = output / (f"lib/libpython{version}.dylib" if relative == Path("Python") else relative)
            if not destination.exists():
                raise SystemExit(f"Unbundled Python dependency: {old}")
            new = "@loader_path/" + os.path.relpath(destination, binary.parent)
            run("install_name_tool", "-change", old, new, binary)
        run("codesign", "--force", "--sign", "-", binary, capture_output=True)
    # Convenient entry named in BENCHMARK.md.
    (output / "python3").symlink_to("bin/python3")
    run(executable, "-c", "import sys,sqlite3,ctypes,ssl; print('Bundled Python:',sys.prefix)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-tests", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--no-dmg", action="store_true")
    args = parser.parse_args()
    if sys.platform != "darwin" or sys.version_info < (3, 12):
        raise SystemExit("Build on macOS using Python 3.12+.")
    arch = {"x86_64": "x64", "arm64": "arm64"}[platform.machine()]
    os.environ.setdefault("MACOSX_DEPLOYMENT_TARGET", "12.0")
    # All mutable build tools stay in the checkout.
    venv = ROOT / ".venv-macos"
    python = venv / "bin/python"
    if not python.is_file():
        run(sys.executable, "-m", "venv", venv)
    run(python, "-m", "pip", "install", "--disable-pip-version-check", "-r", ROOT / "requirements-build-macos.txt")
    run(python, "-m", "pip", "install", "--no-deps", "-e", ROOT)
    pwsh = powershell(arch)
    os.environ["DELEGATOR_PWSH"] = str(pwsh / "pwsh")
    if not args.skip_tests:
        run("cargo", "fmt", "--all", "--", "--check")
        run("cargo", "test", "--locked")
        run(python, "-m", "pytest", "tests", "-q")
        run(pwsh / "pwsh", "-NoLogo", "-NoProfile", "-File", ROOT / "tests/ps/run-tests.ps1")
    profile = "debug" if args.debug else "release"
    run("cargo", "build", "--locked", *([] if args.debug else ["--release"]))
    run(python, "-m", "PyInstaller", "--noconfirm", "--clean", "--onefile", "--noupx",
        "--name", "delegator-core", "--add-data", f"{ROOT / 'delegator_core/static'}:delegator_core/static",
        "--distpath", ROOT / "target" / profile, "--workpath", ROOT / "target/pyinstaller-macos/work",
        "--specpath", ROOT / "target/pyinstaller-macos", ROOT / "run_server.py")
    version = next(line.split('"')[1] for line in (ROOT / "Cargo.toml").read_text().splitlines() if line.startswith("version ="))
    app = ROOT / "dist/Delegator.app"
    if app.exists():
        shutil.rmtree(app)
    macos = app / "Contents/MacOS"
    resources = app / "Contents/Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    for name in ("delegator", "delegator-core"):
        shutil.copy2(ROOT / "target" / profile / name, macos / name)
    shutil.copytree(pwsh, resources / "powershell")
    runtime = resources / "runtime"
    runtime.mkdir()
    for source in (ROOT / "scripts").iterdir():
        if source.suffix in (".ps1", ".json", ".md") and not source.name.startswith(("prune-", "audit-", "test-")):
            shutil.copy2(source, runtime / source.name)
    for name in ("ai-delegate", "ai-delegate-micro", "ai-delegate-plan", "ai-delegate-parallel",
                 "gemini-delegate", "opencode-delegate", "cursor-hook", "ensure-delegator-core"):
        shutil.copy2(ROOT / "scripts/unix-launcher.sh", runtime / name)
        (runtime / name).chmod(0o755)
    shutil.copytree(ROOT / "coding-bench", runtime / "coding-bench",
                    ignore=shutil.ignore_patterns("__pycache__", "runs_archive", "runs", "results"))
    for name in ("DELEGATOR.md", "BENCHMARK.md"):
        path = runtime / name
        text = path.read_text().replace("ai-delegate.cmd", "ai-delegate").replace("DPAPI", "Keychain")
        text = text.replace("\\", "/").replace("python/python.exe", "python/python3").replace('& "', '"')
        path.write_text(text)
    bundle_python(python, runtime / "python")
    shutil.copy2(ROOT / "assets/theme.json", resources / "theme.json")
    shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
    shutil.copy2(ROOT / "docs/MACOS.md", resources / "MACOS.md")
    iconset = TOOLS / "Delegator.iconset"
    iconset.mkdir(exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            run("sips", "-z", size * scale, size * scale, ROOT / "assets/delegator-logo.png", "--out", iconset / name, capture_output=True)
    run("iconutil", "-c", "icns", iconset, "-o", resources / "Delegator.icns")
    with (app / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({
            "CFBundleExecutable": "delegator", "CFBundleIdentifier": "org.delegator.macos",
            "CFBundleName": "Delegator", "CFBundleDisplayName": "Delegator (macOS edition)",
            "CFBundlePackageType": "APPL", "CFBundleIconFile": "Delegator.icns",
            "CFBundleShortVersionString": version, "CFBundleVersion": version,
            "LSMinimumSystemVersion": "12.0", "LSUIElement": True,
            "NSHighResolutionCapable": True,
        }, file)
    # Runtime data belongs in Resources, away from AppKit's nested code slots.
    # Sign native runtime libraries first, then seal the application resources.
    for binary in [macos / "delegator-core", resources / "powershell/pwsh",
                   *resources.rglob("*.dylib"), *resources.rglob("*.so")]:
        if not binary.is_symlink():
            run("codesign", "--force", "--sign", "-", binary, capture_output=True)
    run("codesign", "--force", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    zip_path = ROOT / f"dist/Delegator-{version}-macos-{arch}.zip"
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, zip_path)
    if not args.no_dmg:
        stage = ROOT / "target/dmg-macos"
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(app, stage / app.name, symlinks=True)
        (stage / "Applications").symlink_to("/Applications")
        shutil.copy2(ROOT / "docs/MACOS.md", stage / "README.md")
        run("hdiutil", "create", "-ov", "-volname", "Delegator macOS", "-srcfolder", stage,
            "-format", "UDZO", ROOT / f"dist/Delegator-{version}-macos-{arch}.dmg")
    print(f"Built modified macOS edition: {app}\nArchive: {zip_path}")


if __name__ == "__main__":
    main()

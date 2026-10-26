r"""Build the private CPython that ships in <RUNTIME>\python (see build-installer.ps1).

Run with the build interpreter (the CPython the core is frozen with):
    python scripts\build-pyembed.py <output dir>

Output: python.exe, the runtime DLLs, the extension modules and python312.zip
(the stdlib as .pyc), all side by side. There is deliberately NO python312._pth:
that file switches the interpreter to isolated mode, and `-c` code and scripts
would then lose the cwd / script directory on sys.path.
Nothing is downloaded; everything is copied from sys.base_prefix.
"""
import compileall
import os
import shutil
import sys
import tempfile
import zipfile

# Only what the coding benchmark's graders and a plain script runner need.
# No _ssl/_hashlib (+ 9.6 MB of OpenSSL), no sqlite3 (1.7 MB), no tkinter.
EXT_MODULES = [
    "_asyncio", "_bz2", "_ctypes", "_decimal", "_elementtree", "_lzma",
    "_multiprocessing", "_overlapped", "_queue", "_socket", "_uuid",
    "_zoneinfo", "pyexpat", "select", "unicodedata",
]
EXTRA_DLLS = ["libffi-8.dll"]  # needed by _ctypes
ROOT_FILES = ["python.exe", "python3.dll", "python312.dll",
              "vcruntime140.dll", "vcruntime140_1.dll"]
SKIP_DIRS = {
    "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip", "lib2to3",
    "pydoc_data", "venv", "distutils", "site-packages", "__pycache__", "msilib",
    "curses", "dbm",
}
SKIP_FILES = {"turtle.py", "pydoc.py", "antigravity.py", "this.py", "__hello__.py"}


def main(out):
    base = sys.base_prefix
    if (sys.version_info[:2]) != (3, 12):
        raise SystemExit(f"CPython 3.12 expected, got {sys.version}")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)
    for name in ROOT_FILES:
        shutil.copy2(os.path.join(base, name), out)
    for name in EXTRA_DLLS:
        shutil.copy2(os.path.join(base, "DLLs", name), out)
    for mod in EXT_MODULES:
        shutil.copy2(os.path.join(base, "DLLs", mod + ".pyd"), out)

    lib = os.path.join(base, "Lib")
    with tempfile.TemporaryDirectory() as tmp:
        stage = os.path.join(tmp, "lib")

        def ignore(d, names):
            drop = [n for n in names
                    if (n in SKIP_DIRS and os.path.isdir(os.path.join(d, n)))
                    or n in SKIP_FILES
                    or n.startswith("test_") or n.startswith("turtle")]
            return drop

        shutil.copytree(lib, stage, ignore=ignore)
        # -b: legacy layout (foo.pyc beside foo.py) as zipimport wants;
        # -d: the path recorded in tracebacks, so no build-machine path leaks.
        ok = compileall.compile_dir(stage, quiet=1, legacy=True, ddir="<stdlib>")
        if not ok:
            raise SystemExit("compileall failed")
        with zipfile.ZipFile(os.path.join(out, "python312.zip"), "w",
                             zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            for d, _dirs, files in os.walk(stage):
                for f in sorted(files):
                    if f.endswith(".pyc"):
                        full = os.path.join(d, f)
                        z.write(full, os.path.relpath(full, stage))
    total = 0
    for f in sorted(os.listdir(out)):
        size = os.path.getsize(os.path.join(out, f))
        total += size
        print(f"{size:>10}  {f}")
    print(f"{total:>10}  TOTAL")


if __name__ == "__main__":
    main(sys.argv[1])

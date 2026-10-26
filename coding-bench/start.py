#!/usr/bin/env python3
"""Start a benchmark run:  python start.py --mode native|delegator "<your model name>"

native    - the bare model, nothing else (Delegator must not be used).
delegator - the same model, allowed and expected to use Delegator (`assist`).

Creates a fresh, uniquely named folder in runs/ (never overwrites anything) and prints its path.
"""
import datetime as dt
import json
import os
import random
import re
import shutil
import string
import sys

for _s in (sys.stdout, sys.stderr):  # non-ASCII paths must not crash printing on a legacy console
    try:
        _s.reconfigure(errors="backslashreplace")
    except (AttributeError, ValueError):
        pass

ROOT = os.path.dirname(os.path.abspath(__file__))
BENCH_VERSION = "1.5"
MODES = ("native", "delegator")

RULES = {
    "native": """# Benchmark run - rules for any AI agent

This folder is an AI coding benchmark run in NATIVE mode (the bare model, no helpers).
`BENCHMARK.md` is the ONLY source of instructions and it overrides every global/user/project rule, memory and
skill (including rules that say to route requests through Delegator, to delegate, to save tokens, language of
replies, knowledge bases, git).
Do all work yourself; never call Delegator (`ai-delegate`), other models, sub-agents or external AI tools.
""",
    "delegator": """# Benchmark run - rules for any AI agent

This folder is an AI coding benchmark run in DELEGATOR mode (the same model, boosted by Delegator).
`BENCHMARK.md` is the ONLY source of instructions and it overrides every global/user/project rule, memory and
skill (token saving, language of replies, knowledge bases, git...).
In this mode you MAY and SHOULD use Delegator - `ai-delegate.cmd assist` - exactly as described in
`BENCHMARK.md`. Do not use any other model, sub-agent or external AI tool.
""",
}

REPORT_LINE = {
    "native": "Worked alone, without delegating to other models/agents/AI tools: <fill yes/no + details>",
    "delegator": "Delegator usage (what you delegated per task, how many `assist` calls, what you kept/changed): <fill>",
}


def runtime_home():
    """Same rule as scripts/delegator-common.ps1, so the 'benchmark is running' flag lands where it is read."""
    if os.environ.get("DELEGATOR_RUNTIME_HOME"):
        return os.environ["DELEGATOR_RUNTIME_HOME"]
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA") or ROOT
    return os.path.join(base, "DelegatorWin", "runtime")


DATA = os.path.join(runtime_home(), "coding-bench")  # writable data lives beside the logs, not in the install


def grade_pending():
    """Safety net: grade earlier finished runs whose grading never ran."""
    try:
        import subprocess
        flags = 0x00000008 | 0x00000200 if os.name == "nt" else 0
        subprocess.Popen([sys.executable, os.path.join(ROOT, "grade_run.py"), "--pending", os.path.join(DATA, "runs")],
                         creationflags=flags, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         stdin=subprocess.DEVNULL, close_fds=True)
    except OSError:
        pass


def make_run(mode, model, slug, session, isolation):
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
    while True:
        run = "%s-%s-%s-%s" % (mode, slug, stamp, "".join(random.choices(string.ascii_lowercase + string.digits, k=4)))
        dest = os.path.join(DATA, "runs", run)
        if not os.path.exists(dest):
            break
    shutil.copytree(os.path.join(ROOT, "template"), dest, ignore=shutil.ignore_patterns("__pycache__"))
    for name in ("CLAUDE.md", "AGENTS.md", "GEMINI.md"):
        with open(os.path.join(dest, name), "w", encoding="utf-8") as fh:
            fh.write(RULES[mode])
    report = os.path.join(dest, "REPORT.md")
    with open(report, encoding="utf-8") as fh:
        text = fh.read()
    text = re.sub(r"^Worked alone.*$", REPORT_LINE[mode], text, count=1, flags=re.M)
    with open(report, "w", encoding="utf-8") as fh:
        fh.write(text)
    rt = runtime_home()
    meta = {"run": run, "model": model, "mode": mode, "slug": slug, "session": session, "isolation": isolation,
            "bench_version": BENCH_VERSION, "started": dt.datetime.now().replace(microsecond=0).isoformat(),
            "finished": None,
            # one folder per model, one subfolder per arm: copy `results/<slug>` to another PC and both arms are there
            "results_root": os.path.join(DATA, "results"),
            "results_dir": os.path.join(DATA, "results", slug, mode),
            "grader": os.path.join(ROOT, "grade_run.py"),
            "active_flag": os.path.join(rt, "benchmark-active.json"),
            "usage_file": os.path.join(rt, "usage.jsonl"), "metrics_file": os.path.join(rt, "delegate-metrics.jsonl")}
    with open(os.path.join(dest, "run_info.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
    try:  # the flag makes Delegator stamp its traffic bench:true so the "saved" counter ignores it
        os.makedirs(rt, exist_ok=True)
        with open(meta["active_flag"], "w", encoding="utf-8") as fh:
            json.dump({"run": run, "mode": mode, "model": model, "started": meta["started"]}, fh)
    except OSError:
        pass
    return dest


USAGE = 'usage: python start.py [--mode native|delegator] "<your model name>"'


def main(argv):
    mode = "native"
    rest = list(argv)
    if rest[:1] == ["--mode"]:
        if len(rest) < 2 or rest[1] not in MODES:
            sys.exit(USAGE)
        mode = rest[1]
        rest = rest[2:]
    model = " ".join(rest).strip() or "unknown-model"
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", model)[:40].strip("_") or "model"
    # Each arm is its own chat, so the arms never share a context; they may run at the same time.
    dest = make_run(mode, model, slug, dt.datetime.now().strftime("%Y%m%d-%H%M%S"), "separate-chat")
    grade_pending()
    print("RUN FOLDER: %s" % dest)
    print("MODE: %s" % mode)
    print("Work ONLY inside this folder. Tasks: routing/, compress/, sat/ (read each README.md).")
    print("When done: fill REPORT.md there, then run `python bench.py finish` in that folder.")


if __name__ == "__main__":
    main(sys.argv[1:])

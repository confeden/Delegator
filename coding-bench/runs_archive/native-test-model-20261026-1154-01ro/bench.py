#!/usr/bin/env python3
"""Benchmark helper for one run folder.

  python bench.py begin routing|compress|sat   start the clock for a task (15 min budget each)
  python bench.py check routing|compress|sat   local self-check of a task
  python bench.py status                       time used per task and in total
  python bench.py finish                       publish REPORT.md and grade (takes 5-10 min, wait)
"""
import datetime as dt
import json
import os
import subprocess
import sys

for _s in (sys.stdout, sys.stderr):  # non-ASCII paths must not crash printing on a legacy console
    try:
        _s.reconfigure(errors="backslashreplace")
    except (AttributeError, ValueError):
        pass

os.environ["PYTHONNOUSERSITE"] = "1"  # child interpreters (the graders) must not import from the user's site-packages
ROOT = os.path.dirname(os.path.abspath(__file__))
TASKS = ("routing", "compress", "sat")
BUDGET_MIN = 15


def now():
    return dt.datetime.now().replace(microsecond=0)


def load():
    with open(os.path.join(ROOT, "run_info.json"), encoding="utf-8") as fh:
        return json.load(fh)


def save(meta):
    with open(os.path.join(ROOT, "run_info.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)


def touch_flag(meta):
    """Keep the 'benchmark running' flag fresh: Delegator ignores one older than 6 hours."""
    flag = meta.get("active_flag")
    if not flag:
        return
    try:
        os.makedirs(os.path.dirname(flag), exist_ok=True)
        with open(flag, "w", encoding="utf-8") as fh:
            json.dump({"run": meta["run"], "mode": meta.get("mode"), "model": meta["model"],
                       "started": meta["started"]}, fh)
    except OSError:
        pass


def drop_flag(meta):
    """Remove the flag unless another run (the other arm, in another chat) is still unfinished."""
    try:
        for name in os.listdir(os.path.dirname(ROOT)):
            other = os.path.join(os.path.dirname(ROOT), name)
            if os.path.abspath(other) == ROOT:
                continue
            try:
                with open(os.path.join(other, "run_info.json"), encoding="utf-8") as fh:
                    info = json.load(fh)
            except (OSError, ValueError):
                continue
            if info.get("run") == meta.get("run") or info.get("finished") or not info.get("started"):
                continue
            try:  # the other arm may be running in another chat at the same time
                if (dt.datetime.now() - dt.datetime.fromisoformat(info["started"])).total_seconds() < 6 * 3600:
                    return
            except ValueError:
                continue
        os.remove(meta["active_flag"])
    except (KeyError, OSError):
        pass


def mins(a, b):
    return round((b - dt.datetime.fromisoformat(a)).total_seconds() / 60, 1)


def status_lines(meta):
    t = now()
    lines = ["total: %.1f min of ~45" % mins(meta["started"], t)]
    for task in TASKS:
        b = meta.get("tasks", {}).get(task)
        lines.append("  %-8s %s" % (task, "%.1f min" % mins(b, t) if b else "not started"))
    return lines


def cmd_begin(task):
    meta = load()
    meta.setdefault("tasks", {}).setdefault(task, now().isoformat())
    save(meta)
    touch_flag(meta)
    print("%s started; budget %d min. Use `python bench.py status` to see the clock." % (task, BUDGET_MIN))


def cmd_check(task):
    meta = load()
    touch_flag(meta)
    began = meta.get("tasks", {}).get(task)
    if began and mins(began, now()) > BUDGET_MIN:
        print("TIME WARNING: %s has used %.0f min (budget %d). Wrap up and move to the next task."
              % (task, mins(began, now()), BUDGET_MIN))
    sys.exit(subprocess.run([sys.executable, "check.py"], cwd=os.path.join(ROOT, task)).returncode)


def cmd_finish():
    report = os.path.join(ROOT, "REPORT.md")
    body = open(report, encoding="utf-8").read() if os.path.exists(report) else ""
    if "<fill" in body:
        print("WARNING: REPORT.md still has <fill> placeholders.")
    meta = load()
    grade = os.path.join(meta["results_dir"], "%s__v%s__grade.json" % (meta["run"], meta["bench_version"]))
    if meta.get("finished") and os.path.exists(grade):
        sys.exit("already finished and graded at %s - stop now." % meta["finished"])
    if not meta.get("finished"):  # a re-run after an interrupted grading only grades again
        meta["finished"] = now().isoformat()
        save(meta)
        os.makedirs(meta["results_dir"], exist_ok=True)
        out = os.path.join(meta["results_dir"], "%s__v%s.md" % (meta["run"], meta["bench_version"]))
        with open(out, "w", encoding="utf-8") as fh:
            fh.write("# %s - benchmark v%s\n\n- Mode: %s\n- Model: %s\n- Started: %s | Finished: %s | %s min\n- %s\n\n---\n\n%s"
                     % (meta["run"], meta["bench_version"], meta.get("mode", "native"), meta["model"], meta["started"], meta["finished"],
                        mins(meta["started"], dt.datetime.fromisoformat(meta["finished"])),
                        " | ".join(status_lines(meta)[1:]).strip(), body))
        print("Report published to %s" % out)
    print("Grading now (5-10 minutes). Wait for it to finish - do not interrupt.", flush=True)
    os.chdir(os.path.dirname(ROOT))
    try:
        subprocess.run([sys.executable, meta["grader"], ROOT])
    finally:
        drop_flag(meta)
    if os.path.exists(grade):
        print("Grading finished. The benchmark is complete - stop now, do not change anything.")
    else:
        print("Grading did not complete. Tell the user to run: python \"%s\" --pending \"%s\""
              % (meta["grader"], os.path.dirname(ROOT)))


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 2 and a[0] in ("begin", "check") and a[1] in TASKS:
        (cmd_begin if a[0] == "begin" else cmd_check)(a[1])
    elif a == ["status"]:
        print("\n".join(status_lines(load())))
    elif a == ["finish"]:
        cmd_finish()
    else:
        sys.exit(__doc__)

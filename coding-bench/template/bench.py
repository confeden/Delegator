#!/usr/bin/env python3
"""Benchmark helper for one run folder.

  python bench.py begin routing|compress|sat   start the clock for a task (15 min budget each)
  python bench.py check routing|compress|sat   local self-check of a task
  python bench.py status                       time used per task and in total
  python bench.py finish                       publish REPORT.md and grade (takes ~25 min, wait)
  python bench.py run <seconds> <command...>   run any command with a HARD time limit (the whole tree is killed)
"""
import datetime as dt
import json
import os
import subprocess
import sys
import time

for _s in (sys.stdout, sys.stderr):  # non-ASCII paths must not crash printing on a legacy console
    try:
        _s.reconfigure(errors="backslashreplace")
    except (AttributeError, ValueError):
        pass

os.environ["PYTHONNOUSERSITE"] = "1"  # child interpreters (the graders) must not import from the user's site-packages
ROOT = os.path.dirname(os.path.abspath(__file__))
TASKS = ("routing", "compress", "sat")
BUDGET_MIN = 15
FLAG_LIVE_SEC = 30 * 60  # a run that has not touched the flag for this long is gone


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
    """Remove the flag unless ANOTHER run is still live.

    A run is live only while it keeps touching the flag (begin/check do; every call refreshes its mtime).
    An unfinished run that was stopped or abandoned stops touching it, so after FLAG_LIVE_SEC the flag is
    stale and goes. The old rule read unfinished run folders instead, and one abandoned run kept the flag
    (and the «Идёт прогон» status) alive for hours.
    """
    try:
        flag = meta["active_flag"]
        with open(flag, encoding="utf-8") as fh:
            live = json.load(fh)
        if live.get("run") != meta.get("run") and time.time() - os.path.getmtime(flag) < FLAG_LIVE_SEC:
            return  # the other arm is still running in another chat
        os.remove(flag)
    except (KeyError, OSError, ValueError):
        pass


def mins(a, b):
    return round((b - dt.datetime.fromisoformat(a)).total_seconds() / 60, 1)


def task_mins(meta, task, t=None):
    """Minutes spent on a task: from `begin` to the `begin` of the next task (or to now / finish)."""
    b = meta.get("tasks", {}).get(task)
    if not b:
        return None
    end = meta.get("task_end", {}).get(task) or meta.get("finished") or (t or now()).isoformat()
    return mins(b, dt.datetime.fromisoformat(end))


def status_lines(meta):
    t = now()
    lines = ["total: %.1f min of %d" % (mins(meta["started"], t), TOTAL_BUDGET_MIN)]
    if over_total_budget(meta):
        lines.append("OVER THE %d-MIN BUDGET: stop now and run `PY bench.py finish`" % TOTAL_BUDGET_MIN)
    for task in TASKS:
        m = task_mins(meta, task, t)
        lines.append("  %-8s %s" % (task, "%.1f min" % m if m is not None else "not started"))
    return lines


TOTAL_BUDGET_MIN = 45  # the spec: the whole run fits in 45 minutes


def over_total_budget(meta):
    return mins(meta["started"], now()) > TOTAL_BUDGET_MIN


def cmd_begin(task):
    meta = load()
    if over_total_budget(meta):
        # A hard stop, not a warning: the spec is 45 minutes for the whole run.
        print("STOP: %.0f min have passed of the %d-minute budget. Do not start %s. Run `PY bench.py finish` now."
              % (mins(meta["started"], now()), TOTAL_BUDGET_MIN, task))
        sys.exit(2)
    t = now().isoformat()
    meta.setdefault("tasks", {}).setdefault(task, t)
    ends = meta.setdefault("task_end", {})
    for other in meta["tasks"]:  # the clock of a task stops when the next one begins
        if other != task:
            ends.setdefault(other, t)
    save(meta)
    touch_flag(meta)
    print("%s started; budget %d min. Use `python bench.py status` to see the clock." % (task, BUDGET_MIN))


CHECK_TIMEOUT_SEC = 120  # a self-check that needs longer is too slow to be a check


def cmd_check(task):
    meta = load()
    touch_flag(meta)
    used = task_mins(meta, task)
    if used is not None and used > BUDGET_MIN:
        print("TIME WARNING: %s has used %.0f min (budget %d). Wrap up and move to the next task."
              % (task, used, BUDGET_MIN))
    try:
        code = subprocess.run([sys.executable, "check.py"], cwd=os.path.join(ROOT, task),
                              timeout=CHECK_TIMEOUT_SEC).returncode
    except subprocess.TimeoutExpired:
        print("CHECK TIMEOUT: %s did not finish in %d s. It counts as a failed check; fix the loop or the "
              "solver, do not re-run it unchanged." % (task, CHECK_TIMEOUT_SEC))
        code = 124
    if used is not None:
        print("[clock] %s: %.1f of %d min used" % (task, used, BUDGET_MIN))
    sys.exit(code)


def cmd_run(seconds, command):
    """Run one command under a hard wall-clock limit. On expiry the whole process tree is killed."""
    proc = subprocess.Popen(command, cwd=os.getcwd())
    try:
        code = proc.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        if os.name == "nt":  # taskkill /T takes the children too; a plain kill leaves them running
            subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            proc.kill()
        proc.wait()
        print("RUN TIMEOUT after %d s: the command was killed. Do not run it again unchanged." % seconds)
        code = 124
    sys.exit(code)


def pack_submission(meta):
    """No grader here (chat sandbox or shared copy): zip the run folder for the benchmark owner."""
    import zipfile
    out = os.path.join(os.path.dirname(ROOT), "%s-submission.zip" % meta["run"])
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(ROOT):
            for name in files:
                path = os.path.join(root, name)
                if os.path.abspath(path) == os.path.abspath(out) or name.endswith("-submission.zip"):
                    continue
                z.write(path, os.path.relpath(path, ROOT).replace(os.sep, "/"))
    print("Submission packed: %s" % out)
    print("Give this file to the benchmark owner. Grading happens on their side; you are done - stop now.")


def cmd_finish():
    report = os.path.join(ROOT, "REPORT.md")
    body = open(report, encoding="utf-8").read() if os.path.exists(report) else ""
    if "<fill" in body:
        print("WARNING: REPORT.md still has <fill> placeholders.")
    meta = load()
    if not os.path.exists(meta["grader"]):  # no grader on this machine (shared copy): hand the folder to the owner
        if not meta.get("finished"):
            meta["finished"] = now().isoformat()
            save(meta)
        pack_submission(meta)
        drop_flag(meta)
        return
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
    print("Grading now (about 20-25 minutes: routing and sat are scored 3 times). Wait for it to finish - do not interrupt.", flush=True)
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
    elif len(a) >= 3 and a[0] == "run" and a[1].isdigit():
        cmd_run(int(a[1]), a[2:])
    else:
        sys.exit(__doc__)

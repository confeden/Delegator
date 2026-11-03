#!/usr/bin/env python3
"""Grade one run (started automatically by `bench.py finish`, or by hand).

    python grade_run.py <run_dir> [--keep]     archive + grade one run, then remove it from the workspace
                                               (`bench.py finish` does this; routing/sat are scored 3x, ~20-25 min)
    python grade_run.py --archive <run_dir>    archive a finished run and remove it from the workspace, grade later
    python grade_run.py --summary <results>    rebuild SUMMARY_v<version>.md from all grade files
    python grade_run.py --pending [runs_dir]   grade finished runs (in runs_dir or archived) that have no grade yet
    python grade_run.py --regrade [--out DIR]  re-grade every archived run (after scorer changes); --out keeps
                                               the existing results untouched and writes the new grades to DIR

Gradings are serialized with a lock file so that time-limited scoring is not disturbed by another grading.
"""
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time

for _s in (sys.stdout, sys.stderr):  # non-ASCII paths must not crash printing on a legacy console
    try:
        _s.reconfigure(errors="backslashreplace")
    except (AttributeError, ValueError):
        pass

HERE = os.path.dirname(os.path.abspath(__file__))
# The archive (finished solutions, out of the agents' reach) and the lock live next to the grader; the env override
# lets a test or a read-only install point them somewhere writable.
ARCHIVE = os.environ.get("DELEGATOR_BENCH_ARCHIVE") or os.path.join(HERE, "runs_archive")
LOCK = os.path.join(os.path.dirname(ARCHIVE), "grading.lock") if os.environ.get("DELEGATOR_BENCH_ARCHIVE") \
    else os.path.join(HERE, "grading.lock")
sys.path.insert(0, HERE)
from code_rules import check_code  # noqa: E402 - the one static check, shared with the scorers and check.py
OVER_BUDGET_MIN = 60  # tasks ~45 min + 15 min grace; a flag only, the score is not changed
SOLUTION_FILE = {"routing": "routing.py", "compress": "codec.py", "sat": "solver.py"}
# task -> (weight, scorer, list key in scorer output)
TASKS = {
    "routing": (35, os.path.join(HERE, "hidden", "routing", "score_routing.py"), "instances"),
    "compress": (35, os.path.join(HERE, "hidden", "compress", "score_compress.py"), "files"),
    "sat": (30, os.path.join(HERE, "hidden", "score_sat.py"), "instances"),
}


# Time-limited tasks depend on machine load and solver randomness: score them several times and take the median.
# compress is deterministic (identical on repeats), so once is enough.
REPEATS = {"routing": 3, "compress": 1, "sat": 3}
IDLE_CPU_PCT = 25      # wait for the machine to be at most this busy before each scoring run
IDLE_MAX_WAIT = 300    # ... but not longer than this many seconds (then score anyway and record the load)


def cpu_busy_pct(window=2.0):
    """System-wide CPU usage over `window` seconds; None if it cannot be measured."""
    try:
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes

            class FT(ctypes.Structure):
                _fields_ = [("lo", wintypes.DWORD), ("hi", wintypes.DWORD)]

            def sample():
                idle, kern, user = FT(), FT(), FT()
                ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(idle), ctypes.byref(kern), ctypes.byref(user))
                val = lambda f: (f.hi << 32) | f.lo
                return val(idle), val(kern) + val(user)  # kernel time includes idle time

            i0, t0 = sample()
            time.sleep(window)
            i1, t1 = sample()
            return round(100.0 * (1 - (i1 - i0) / max(1, t1 - t0)), 1)
        return round(100.0 * os.getloadavg()[0] / (os.cpu_count() or 1), 1)
    except Exception:  # noqa: BLE001 - load is advisory only
        return None


def wait_idle():
    """Block until the machine is quiet (or IDLE_MAX_WAIT passes); return the last measured CPU load."""
    deadline = time.time() + IDLE_MAX_WAIT
    load = cpu_busy_pct()
    while load is not None and load > IDLE_CPU_PCT and time.time() < deadline:
        time.sleep(10)
        load = cpu_busy_pct()
    return load


def pid_alive(pid):
    if os.name == "nt":
        import ctypes
        h = ctypes.windll.kernel32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        code = ctypes.c_ulong()
        ok = ctypes.windll.kernel32.GetExitCodeProcess(h, ctypes.byref(code))
        ctypes.windll.kernel32.CloseHandle(h)
        return bool(ok) and code.value == 259  # STILL_ACTIVE
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def acquire_lock():
    while True:
        try:
            fd = os.open(LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return
        except FileExistsError:
            try:
                holder = int(open(LOCK).read().strip() or 0)
            except (OSError, ValueError):
                holder = 0
            if not holder or not pid_alive(holder) or time.time() - os.path.getmtime(LOCK) > 3 * 3600:
                try:
                    os.remove(LOCK)  # stale: the grading process died
                except OSError:
                    pass
                continue
            time.sleep(10)


def run_scorer_once(task, target):
    weight, script, key = TASKS[task]
    if not os.path.isdir(target):
        return {"score": 0.0, "max": weight, "note": "task folder missing", "detail": {}}
    env = dict(os.environ, BENCH_TARGET=target, PYTHONDONTWRITEBYTECODE="1", PYTHONHASHSEED="0")
    try:
        proc = subprocess.run([sys.executable, script], capture_output=True, text=True, timeout=3600,
                              env=env, cwd=os.path.dirname(script),
                              creationflags=0x00008000 if os.name == "nt" else 0)  # ABOVE_NORMAL: scoring is timed
        data = json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as exc:  # noqa: BLE001 - scorer failure means 0 points, reported in the note
        return {"score": 0.0, "max": weight, "note": "scorer failed: %s" % exc, "detail": {}}
    frac = max(0.0, float(data.get("score_fraction", 0)))
    items = data.get(key, [])
    ok = sum(1 for i in items if str(i.get("status", "")).startswith("ok") or i.get("points", 0) > 0)
    note = "%.1f%% of max; %d/%d items scored" % (100 * frac, ok, len(items))
    if data.get("violation"):
        note += "; VIOLATION: %s" % data["violation"]
    if task == "sat":
        note += "; solved %s, wrong %s" % (data.get("solved"), data.get("wrong"))
    return {"score": round(weight * frac, 2), "max": weight, "note": note, "detail": data}


def median_of(values):
    v = sorted(values)
    return v[(len(v) - 1) // 2]


def merge_runs(task, runs):
    """Per-instance median over repeated scorings: an instance counts the way it came out in most runs.
    Falls back to the median-total run when the runs are not comparable (failure, violation, other item lists)."""
    weight, _, key = TASKS[task]
    by_total = sorted(runs, key=lambda r: r["score"])
    fallback = dict(by_total[(len(by_total) - 1) // 2])
    lists = [r["detail"].get(key) or [] for r in runs]
    n = len(lists[0])
    if n == 0 or any(len(l) != n for l in lists) or any(r["detail"].get("violation") for r in runs):
        return fallback
    items = []
    for j in range(n):
        pts = [l[j].get("points", 0) for l in lists]
        m = median_of(pts)
        items.append(dict(next(l[j] for l in lists if l[j].get("points", 0) == m), points=m))
    total = sum(i["points"] for i in items)
    frac = (max(0.0, total) if task == "sat" else total) / n
    detail = dict(runs[0]["detail"], score_fraction=frac)
    detail[key] = items
    if task == "sat":
        detail["solved"] = sum(1 for i in items if i["points"] == 1)
        detail["wrong"] = sum(1 for i in items if i["points"] == -2)
    ok = sum(1 for i in items if str(i.get("status", "")).startswith("ok") or i.get("points", 0) > 0)
    note = "%.1f%% of max; %d/%d items scored" % (100 * frac, ok, n)
    if task == "sat":
        note += "; solved %s, wrong %s" % (detail["solved"], detail["wrong"])
    return {"score": round(weight * frac, 2), "max": weight, "note": note, "detail": detail}


def run_scorer(task, target):
    """Score `task` REPEATS[task] times (waiting for an idle CPU before each); merge per instance by median."""
    if not os.path.isdir(target):
        return run_scorer_once(task, target)
    bad = check_code(os.path.join(target, SOLUTION_FILE[task]), task)  # the scorer applies the same rules; saves 3 runs
    if bad:
        return {"score": 0.0, "max": TASKS[task][0], "note": "VIOLATION: %s" % bad, "detail": {"violation": bad}}
    runs = []
    for _ in range(REPEATS[task]):
        load = wait_idle()
        r = run_scorer_once(task, target)
        r["cpu_load_before"] = load
        runs.append(r)
    if len(runs) == 1:
        return runs[0]
    out = merge_runs(task, runs)
    totals = sorted(r["score"] for r in runs)
    out["runs"] = totals
    out["cpu_load_before"] = [r["cpu_load_before"] for r in runs]
    out["note"] += "; per-instance median of %d runs (totals %s)" % (len(runs), "/".join("%.1f" % x for x in totals))
    return out


def _ts(text):
    """ISO timestamp (UTC 'Z', an offset, or naive local) -> aware datetime; 7-digit fractions are trimmed."""
    text = re.sub(r"(\.\d{6})\d+", r"\1", str(text).replace("Z", "+00:00"))
    value = dt.datetime.fromisoformat(text)
    return value.astimezone() if value.tzinfo is None else value


def read_jsonl(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue
    except OSError:
        return


def delegation_stats(meta):
    """What Delegator did while this run was in flight, read from its own logs (approximate: the window
    is the run's wall clock, so other Delegator traffic on the machine in that time is included)."""
    if meta.get("mode") != "delegator" or not (meta.get("started") and meta.get("finished")):
        return None
    lo = _ts(meta["started"])
    hi = _ts(meta["finished"]) + dt.timedelta(seconds=60)
    requests, models, failed = {}, {}, 0
    for rec in read_jsonl(meta.get("usage_file", "")):
        try:
            when = _ts(rec["ts"])
        except (KeyError, ValueError):
            continue
        if not (lo <= when <= hi) or not rec.get("bench"):
            continue
        rid = rec.get("requestId") or rec["ts"]
        entry = requests.setdefault(rid, {"ok": 0, "bad": 0})
        if rec.get("ok"):
            entry["ok"] += 1
            name = rec.get("model") or "?"
            models[name] = models.get(name, 0) + 1
        else:
            entry["bad"] += 1
            failed += 1
    web = 0
    for rec in read_jsonl(meta.get("metrics_file", "")):
        try:
            when = _ts(rec["ts"])
        except (KeyError, ValueError):
            continue
        if rec.get("stage") == "web" and rec.get("status") == "ok" and lo <= when <= hi:
            web += 1
    return {"calls": len(requests) + web,
            "ok": sum(1 for e in requests.values() if e["ok"]) + web,
            "web_calls": web,
            "failed_attempts": failed,
            "requests_with_fallback": sum(1 for e in requests.values() if e["ok"] and e["bad"]),
            "models": dict(sorted(models.items(), key=lambda kv: -kv[1]))}


def delegation_flags(deleg):
    """A delegator arm that got no answer measured the bare model, not Delegator. Say so on the grade."""
    if deleg is None or deleg["ok"] > 0:
        return []
    if deleg["calls"] == 0:
        return ["delegation: Delegator was never called in this run"]
    return ["delegation: no request was answered (%d failed attempts)" % deleg["failed_attempts"]]


def confidences(report):
    conf = {}
    for task, val in re.findall(r"^\|\s*(routing|compress|sat)\s*\|\s*(\d{1,3})\s*%?\s*\|", report, re.M):
        conf[task] = min(100, int(val))
    return conf


def trusted_meta(meta):
    """run_info.json lives in a folder the model can edit; start.py keeps a copy outside it. Identity, mode and
    start time are taken from that copy, and the finish time is the grader's own observation."""
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(meta["results_dir"]))), "registry", meta["run"] + ".json")
    try:
        with open(path, encoding="utf-8") as fh:
            reg = json.load(fh)
    except (OSError, ValueError):
        return dict(meta, tampered=None)
    changed = [k for k in ("model", "mode", "started", "bench_version") if reg.get(k) != meta.get(k)]
    out = dict(meta)
    out.update({k: reg[k] for k in ("run", "model", "mode", "started", "bench_version", "usage_file",
                                    "metrics_file", "results_dir") if k in reg})
    out["tampered"] = changed
    return out


def last_work(run_dir):
    """Newest modification time of the work files (not bookkeeping), as a datetime; None if nothing found."""
    newest = 0.0
    for folder, dirs, names in os.walk(run_dir):
        dirs[:] = [d for d in dirs if d not in ("__pycache__", "samples")]
        for name in names:
            if name in ("run_info.json", "REPORT.md", "CLAUDE.md", "AGENTS.md", "GEMINI.md", "bench.py", "code_rules.py") \
                    and folder == run_dir:
                continue
            if name.endswith((".py", ".txt", ".md")) and name not in ("check.py", "README.md", "instances.py"):
                newest = max(newest, os.path.getmtime(os.path.join(folder, name)))
    return dt.datetime.fromtimestamp(newest) if newest else None


def native_usage(meta):
    """A native run must not touch Delegator: any bench-flagged traffic inside its window is a violation."""
    if meta.get("mode") != "native" or not meta.get("started"):
        return None
    lo = _ts(meta["started"])
    hi = _ts(meta["finished"]) + dt.timedelta(seconds=60) if meta.get("finished") else dt.datetime.now().astimezone()
    n = 0
    for rec in read_jsonl(meta.get("usage_file", "")):
        try:
            when = _ts(rec["ts"])
        except (KeyError, ValueError):
            continue
        if lo <= when <= hi and rec.get("bench"):
            n += 1
    return n


def grade_dir(run_dir, meta):
    meta = trusted_meta(meta)
    tasks = {t: run_scorer(t, os.path.join(run_dir, t)) for t in TASKS}
    report_path = os.path.join(run_dir, "REPORT.md")
    report = open(report_path, encoding="utf-8").read() if os.path.exists(report_path) else ""
    conf = confidences(report)
    calib = [abs(conf[t] / 100 - tasks[t]["score"] / tasks[t]["max"]) for t in tasks if t in conf]
    minutes = None
    if meta.get("started") and meta.get("finished"):
        minutes = round((dt.datetime.fromisoformat(meta["finished"]) -
                         dt.datetime.fromisoformat(meta["started"])).total_seconds() / 60, 1)
    # file-based work time: independent of the model's own `bench.py begin/finish` calls
    lw = last_work(run_dir)
    # Files copied from the template keep their old mtime, so an untouched run has a
    # newest file BEFORE its start: that is no work, not negative work.
    work_minutes = max(0.0, round((lw - dt.datetime.fromisoformat(meta["started"])).total_seconds() / 60, 1)) if lw else None
    flags = []
    if meta.get("tampered"):
        flags.append("run_info.json edited: " + ",".join(meta["tampered"]))
    if work_minutes is not None and work_minutes > OVER_BUDGET_MIN:
        flags.append("over time budget: %.0f min of work" % work_minutes)
    deleg = delegation_stats(meta)
    flags.extend(delegation_flags(deleg))
    nat = native_usage(meta)
    if nat:
        flags.append("native run used Delegator (%d bench-flagged requests)" % nat)
    for t, v in tasks.items():
        if v["detail"].get("violation"):
            flags.append("%s: %s" % (t, v["detail"]["violation"]))
    return {"run": meta["run"], "model": meta["model"], "mode": meta.get("mode", "native"),
            "session": meta.get("session"), "isolation": meta.get("isolation"),
            "bench_version": meta["bench_version"], "delegation": deleg,
            "total": round(sum(t["score"] for t in tasks.values()), 2), "tasks": tasks,
            "minutes": minutes, "work_minutes": work_minutes, "flags": flags, "self_confidence": conf, "report_present": "<fill" not in report and bool(report),
            "calibration_error": round(sum(calib) / len(calib), 3) if calib else None,
            "graded_at": dt.datetime.now().replace(microsecond=0).isoformat()}


def render(o):
    lines = ["# Grade - %s (%s), mode %s, isolation %s, benchmark v%s" % (
        o["run"], o["model"], o.get("mode", "native"), o.get("isolation") or "-", o["bench_version"]), "",
             "**Total: %.1f / 100**  |  minutes: %s  |  calibration error: %s" % (o["total"], o["minutes"],
                                                                                 o["calibration_error"]), "",
             "| Task | Score | Max | Self-confidence | Notes |", "|---|---|---|---|---|"]
    for t, v in o["tasks"].items():
        lines.append("| %s | %.1f | %d | %s | %s |" % (t, v["score"], v["max"], o["self_confidence"].get(t, "-"), v["note"]))
    if o.get("flags"):
        lines.insert(3, "**FLAGS (check before trusting this score): %s**" % "; ".join(o["flags"]))
        lines.insert(4, "")
    if o.get("delegation"):
        d = o["delegation"]
        lines.insert(3, "Delegator: %d requests (%d answered), %d via web, %d failed attempts, %d requests recovered by "
                     "switching model; models: %s" % (d["calls"], d["ok"], d["web_calls"], d["failed_attempts"],
                                                      d["requests_with_fallback"],
                                                      ", ".join("%s x%d" % kv for kv in d["models"].items()) or "-"))
        lines.insert(4, "")
    for t, v in o["tasks"].items():
        items = v["detail"].get(TASKS[t][2], [])
        if items:
            lines += ["", "## %s details" % t, ""]
            for i in items:
                lines.append("- " + ", ".join("%s=%s" % (k, round(x, 3) if isinstance(x, float) else x)
                                              for k, x in i.items() if k not in ("ref",)))
    return "\n".join(lines) + "\n"


VERSION = "1.7"


def write_grade(o, results_dir, results_root=None):
    os.makedirs(results_dir, exist_ok=True)
    stem = os.path.join(results_dir, "%s__v%s__grade" % (o["run"], o["bench_version"]))
    with open(stem + ".json", "w", encoding="utf-8") as fh:
        json.dump(o, fh, indent=2, ensure_ascii=False)
    with open(stem + ".md", "w", encoding="utf-8") as fh:
        fh.write(render(o))
    root = results_root or results_dir
    summary(root, o["bench_version"])
    # A copy of the whole model folder (results/<model>/native + /delegator) where the owner can find it and
    # carry it to another PC: one folder, one subfolder per arm.
    desktop = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), "Desktop")
    model_dir = os.path.dirname(results_dir) if results_root else None
    if model_dir and os.path.isdir(desktop):
        try:
            shutil.copytree(model_dir, os.path.join(desktop, "Delegator-benchmark", os.path.basename(model_dir)),
                            dirs_exist_ok=True, ignore=shutil.ignore_patterns("*__grading.txt"))
            shutil.copyfile(os.path.join(root, "SUMMARY_v%s.md" % o["bench_version"]),
                            os.path.join(desktop, "Delegator-benchmark", "SUMMARY.md"))
        except OSError:
            pass


def median(values):
    v = sorted(values)
    return v[(len(v) - 1) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) / 2


def summary(results_dir, version=VERSION):
    rows = []
    for folder, _dirs, names in os.walk(results_dir):  # results/<model>/<mode>/...; other versions are ignored
        for name in names:
            if name.endswith("__v%s__grade.json" % version):
                try:
                    with open(os.path.join(folder, name), encoding="utf-8") as fh:
                        rows.append(json.load(fh))
                except (OSError, ValueError):
                    continue
    rows.sort(key=lambda o: -o["total"])
    md = ["# Summary - benchmark v%s" % version, "",
          "Differences below ~10 points between models with a single run are within run-to-run noise of the models.", ""]
    models = {}  # one row per model AND arm: native and delegator are different measurements
    for o in rows:
        models.setdefault((" ".join(o["model"].lower().split()), o.get("mode", "native")), []).append(o)
    md += ["## One row per model and mode (median of runs)", "",
           "| # | Mode | Model | Runs | Median total | Min-max | routing | compress | sat |",
           "|---|---|---|---|---|---|---|---|---|"]
    ranked = sorted(models.values(), key=lambda g: -median([o["total"] for o in g]))
    for i, g in enumerate(ranked, 1):
        tot = [o["total"] for o in g]
        md.append("| %d | %s | %s | %d | %.1f | %.1f-%.1f | %.1f | %.1f | %.1f |" % (
            i, g[0].get("mode", "native"), g[0]["model"], len(g), median(tot), min(tot), max(tot),
            *[median([o["tasks"][t]["score"] for o in g]) for t in ("routing", "compress", "sat")]))
    md += ["", "## All runs", "",
           "| # | Mode | Model | Run | Total | routing /35 | compress /35 | sat /30 | Minutes | Calib. err | Flags |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for i, o in enumerate(rows, 1):
        t = o["tasks"]
        md.append("| %d | %s | %s | %s | %.1f | %.1f | %.1f | %.1f | %s | %s | %s |" % (
            i, o.get("mode", "native"), o["model"], o["run"], o["total"], t["routing"]["score"], t["compress"]["score"],
            t["sat"]["score"], o["minutes"], o["calibration_error"], "; ".join(o.get("flags") or []) or "-"))
    with open(os.path.join(results_dir, "SUMMARY_v%s.md" % version), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


def read_meta(run_dir):
    with open(os.path.join(run_dir, "run_info.json"), encoding="utf-8") as fh:
        return json.load(fh)


def archive_run(run_dir, meta, remove=True):
    os.makedirs(ARCHIVE, exist_ok=True)
    archived = os.path.join(ARCHIVE, meta["run"])
    if not os.path.exists(archived):
        shutil.copytree(run_dir, archived, ignore=shutil.ignore_patterns("__pycache__"))
    if remove:
        shutil.rmtree(run_dir, ignore_errors=True)  # other models must not see this solution
    return archived


def marker_path(meta):
    return os.path.join(meta["results_dir"], "%s__grading.txt" % meta["run"])


def grade_archived(archived, meta, out_dir=None):
    out_dir = out_dir or meta["results_dir"]
    os.makedirs(meta["results_dir"], exist_ok=True)
    marker = marker_path(meta)
    with open(marker, "w") as fh:
        fh.write("pid %d started %s" % (os.getpid(), dt.datetime.now().isoformat()))
    acquire_lock()
    try:
        write_grade(grade_dir(archived, meta), out_dir, None if out_dir != meta["results_dir"] else meta.get("results_root"))
    finally:
        os.remove(LOCK)
        try:
            os.remove(marker)
        except OSError:
            pass


def being_graded(meta):
    """A marker counts only while the process that wrote it is alive."""
    try:
        pid = int(open(marker_path(meta)).read().split()[1])
    except (OSError, ValueError, IndexError):
        return False
    return pid != os.getpid() and pid_alive(pid)


def main(argv):
    if argv[:1] == ["--summary"] and len(argv) in (2, 3):
        summary(argv[1], argv[2] if len(argv) == 3 else VERSION)
        return
    if argv[:1] == ["--archive"] and len(argv) == 2:
        run_dir = os.path.abspath(argv[1])
        archive_run(run_dir, read_meta(run_dir))
        return
    if argv[:1] == ["--pending"]:
        runs_dir = argv[1] if len(argv) == 2 else None
        if runs_dir and os.path.isdir(runs_dir):  # finished runs still lying in the workspace: archive them first
            for run in sorted(os.listdir(runs_dir)):
                d = os.path.join(runs_dir, run)
                if os.path.exists(os.path.join(d, "run_info.json")) and read_meta(d).get("finished") \
                        and read_meta(d).get("bench_version") == VERSION:
                    archive_run(d, read_meta(d))
        for run in sorted(os.listdir(ARCHIVE)) if os.path.isdir(ARCHIVE) else []:
            d = os.path.join(ARCHIVE, run)
            try:
                meta = read_meta(d)
            except (OSError, ValueError):
                continue
            grade = os.path.join(meta["results_dir"], "%s__v%s__grade.json" % (meta["run"], meta["bench_version"]))
            if meta.get("bench_version") == VERSION and meta.get("finished") and not os.path.exists(grade) \
                    and not being_graded(meta):
                print("grading", run, flush=True)
                grade_archived(d, meta)
        return
    if argv[:1] == ["--regrade"]:
        out = argv[argv.index("--out") + 1] if "--out" in argv else None
        for run in sorted(os.listdir(ARCHIVE)):
            d = os.path.join(ARCHIVE, run)
            try:
                meta = read_meta(d)
            except (OSError, ValueError):
                continue
            if meta.get("bench_version") != VERSION:  # an older run keeps the grade of the version it was run under
                continue
            grade_archived(d, meta, out)
            print("regraded", run, flush=True)
        return
    if not argv:
        sys.exit(__doc__)
    run_dir = os.path.abspath(argv[0])
    meta = read_meta(run_dir)
    if being_graded(meta):  # a second `finish` after a tool timeout must not start a second 25-minute grading
        print("This run is already being graded by another process; wait for it (or run --pending later).")
        return
    archived = archive_run(run_dir, meta, remove=False)
    grade_archived(archived, meta)
    if "--keep" not in argv:
        shutil.rmtree(run_dir, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv[1:])

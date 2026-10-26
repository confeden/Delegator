#!/usr/bin/env python3
"""Grade one run (started automatically by `bench.py finish`, or by hand).

    python grade_run.py <run_dir> [--keep]     archive + grade one run, then remove it from the workspace
    python grade_run.py --summary <results>    rebuild SUMMARY_v<version>.md from all grade files
    python grade_run.py --pending <runs_dir>   grade finished runs whose background grading did not happen
    python grade_run.py --regrade              re-grade every archived run (after scorer/reference changes)

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
ARCHIVE = os.path.join(HERE, "runs_archive")
LOCK = os.path.join(HERE, "grading.lock")
# task -> (weight, scorer, list key in scorer output)
TASKS = {
    "routing": (35, os.path.join(HERE, "hidden", "routing", "score_routing.py"), "instances"),
    "compress": (35, os.path.join(HERE, "hidden", "compress", "score_compress.py"), "files"),
    "sat": (30, os.path.join(HERE, "hidden", "score_sat.py"), "instances"),
}


def pid_alive(pid):
    if os.name == "nt":
        out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH"], capture_output=True, text=True).stdout
        return str(pid) in out
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


def run_scorer(task, target):
    weight, script, key = TASKS[task]
    if not os.path.isdir(target):
        return {"score": 0.0, "max": weight, "note": "task folder missing", "detail": {}}
    env = dict(os.environ, BENCH_TARGET=target, PYTHONDONTWRITEBYTECODE="1")
    try:
        proc = subprocess.run([sys.executable, script], capture_output=True, text=True, timeout=3600,
                              env=env, cwd=os.path.dirname(script))
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


def confidences(report):
    conf = {}
    for task, val in re.findall(r"^\|\s*(routing|compress|sat)\s*\|\s*(\d{1,3})\s*%?\s*\|", report, re.M):
        conf[task] = min(100, int(val))
    return conf


def grade_dir(run_dir, meta):
    tasks = {t: run_scorer(t, os.path.join(run_dir, t)) for t in TASKS}
    report_path = os.path.join(run_dir, "REPORT.md")
    report = open(report_path, encoding="utf-8").read() if os.path.exists(report_path) else ""
    conf = confidences(report)
    calib = [abs(conf[t] / 100 - tasks[t]["score"] / tasks[t]["max"]) for t in tasks if t in conf]
    minutes = None
    if meta.get("started") and meta.get("finished"):
        minutes = round((dt.datetime.fromisoformat(meta["finished"]) -
                         dt.datetime.fromisoformat(meta["started"])).total_seconds() / 60, 1)
    return {"run": meta["run"], "model": meta["model"], "mode": meta.get("mode", "native"),
            "session": meta.get("session"), "isolation": meta.get("isolation"),
            "bench_version": meta["bench_version"], "delegation": delegation_stats(meta),
            "total": round(sum(t["score"] for t in tasks.values()), 2), "tasks": tasks,
            "minutes": minutes, "self_confidence": conf, "report_present": "<fill" not in report and bool(report),
            "calibration_error": round(sum(calib) / len(calib), 3) if calib else None,
            "graded_at": dt.datetime.now().replace(microsecond=0).isoformat()}


def render(o):
    lines = ["# Grade - %s (%s), mode %s, isolation %s, benchmark v%s" % (
        o["run"], o["model"], o.get("mode", "native"), o.get("isolation") or "-", o["bench_version"]), "",
             "**Total: %.1f / 100**  |  minutes: %s  |  calibration error: %s" % (o["total"], o["minutes"],
                                                                                 o["calibration_error"]), "",
             "| Task | Score | Max | Self-confidence | Notes |", "|---|---|---|---|---|"]
    if o.get("delegation"):
        d = o["delegation"]
        lines.insert(3, "Delegator: %d requests (%d answered), %d via web, %d failed attempts, %d requests recovered by "
                     "switching model; models: %s" % (d["calls"], d["ok"], d["web_calls"], d["failed_attempts"],
                                                      d["requests_with_fallback"],
                                                      ", ".join("%s x%d" % kv for kv in d["models"].items()) or "-"))
        lines.insert(4, "")
    for t, v in o["tasks"].items():
        lines.append("| %s | %.1f | %d | %s | %s |" % (t, v["score"], v["max"], o["self_confidence"].get(t, "-"), v["note"]))
    for t, v in o["tasks"].items():
        items = v["detail"].get(TASKS[t][2], [])
        if items:
            lines += ["", "## %s details" % t, ""]
            for i in items:
                lines.append("- " + ", ".join("%s=%s" % (k, round(x, 3) if isinstance(x, float) else x)
                                              for k, x in i.items() if k not in ("ref",)))
    return "\n".join(lines) + "\n"


def write_grade(o, results_dir, results_root=None):
    os.makedirs(results_dir, exist_ok=True)
    stem = os.path.join(results_dir, "%s__v%s__grade" % (o["run"], o["bench_version"]))
    with open(stem + ".json", "w", encoding="utf-8") as fh:
        json.dump(o, fh, indent=2, ensure_ascii=False)
    with open(stem + ".md", "w", encoding="utf-8") as fh:
        fh.write(render(o))
    root = results_root or results_dir
    summary(root)
    # A copy of the whole model folder (results/<model>/native + /delegator) where the owner can find it and
    # carry it to another PC: one folder, one subfolder per arm.
    desktop = os.path.join(os.environ.get("USERPROFILE") or os.path.expanduser("~"), "Desktop")
    model_dir = os.path.dirname(results_dir) if results_root else None
    if model_dir and os.path.isdir(desktop):
        try:
            shutil.copytree(model_dir, os.path.join(desktop, "Delegator-benchmark", os.path.basename(model_dir)),
                            dirs_exist_ok=True)
            shutil.copyfile(os.path.join(root, "SUMMARY_v%s.md" % o["bench_version"]),
                            os.path.join(desktop, "Delegator-benchmark", "SUMMARY.md"))
        except OSError:
            pass


VERSION = "1.5"


def summary(results_dir):
    rows = []
    for folder, _dirs, names in os.walk(results_dir):
        for name in names:
            if name.endswith("__v%s__grade.json" % VERSION):
                with open(os.path.join(folder, name), encoding="utf-8") as fh:
                    rows.append(json.load(fh))
    rows.sort(key=lambda o: -o["total"])
    md = ["# Summary - benchmark v%s" % VERSION, "",
          "| # | Mode | Model | Run | Total | routing /35 | compress /35 | sat /30 | Minutes | Calib. err |",
          "|---|---|---|---|---|---|---|---|---|---|"]
    for i, o in enumerate(rows, 1):
        t = o["tasks"]
        md.append("| %d | %s | %s | %s | %.1f | %.1f | %.1f | %.1f | %s | %s |" % (
            i, o.get("mode", "native"), o["model"], o["run"], o["total"], t["routing"]["score"], t["compress"]["score"], t["sat"]["score"],
            o["minutes"], o["calibration_error"]))
    with open(os.path.join(results_dir, "SUMMARY_v%s.md" % VERSION), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")


def main(argv):
    if argv[:1] == ["--summary"] and len(argv) == 2:
        summary(argv[1])
        return
    if argv[:1] == ["--pending"] and len(argv) == 2:
        for run in sorted(os.listdir(argv[1])):
            d = os.path.join(argv[1], run)
            info_path = os.path.join(d, "run_info.json")
            if not os.path.exists(info_path):
                continue
            meta = json.load(open(info_path, encoding="utf-8"))
            grade = os.path.join(meta["results_dir"], "%s__v%s__grade.json" % (meta["run"], meta["bench_version"]))
            marker = os.path.join(meta["results_dir"], "%s__grading.txt" % meta["run"])
            pending = meta.get("finished") and meta.get("bench_version") == VERSION
            fresh_marker = os.path.exists(marker) and time.time() - os.path.getmtime(marker) < 1800
            if pending and not os.path.exists(grade) and not fresh_marker:
                print("grading", run, flush=True)
                main([d])
        return
    if argv == ["--regrade"]:
        for run in sorted(os.listdir(ARCHIVE)):
            d = os.path.join(ARCHIVE, run)
            meta = json.load(open(os.path.join(d, "run_info.json"), encoding="utf-8"))
            acquire_lock()
            try:
                write_grade(grade_dir(d, meta), meta["results_dir"], meta.get("results_root"))
            finally:
                os.remove(LOCK)
            print("regraded", run)
        return
    if not argv:
        sys.exit(__doc__)
    run_dir = os.path.abspath(argv[0])
    meta = json.load(open(os.path.join(run_dir, "run_info.json"), encoding="utf-8"))
    os.makedirs(ARCHIVE, exist_ok=True)
    marker = os.path.join(meta["results_dir"], "%s__grading.txt" % meta["run"])
    os.makedirs(meta["results_dir"], exist_ok=True)
    with open(marker, "w") as fh:
        fh.write("grading started %s pid %d" % (dt.datetime.now().isoformat(), os.getpid()))
    archived = os.path.join(ARCHIVE, meta["run"])
    if not os.path.exists(archived):
        shutil.copytree(run_dir, archived, ignore=shutil.ignore_patterns("__pycache__"))
    acquire_lock()
    try:
        write_grade(grade_dir(archived, meta), meta["results_dir"], meta.get("results_root"))
    finally:
        os.remove(LOCK)
        try:
            os.remove(marker)
        except OSError:
            pass
    if "--keep" not in argv:
        shutil.rmtree(run_dir, ignore_errors=True)  # other models must not see this solution


if __name__ == "__main__":
    main(sys.argv[1:])

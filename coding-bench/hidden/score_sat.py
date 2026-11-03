"""SAT scorer (v1.7).

The runner parses the CNF with the grader's own parser (the solver's parse_dimacs is not used and not timed), binds
the clock before importing the solver, reads a per-run token from stdin and reports the result on a line that starts
with it. The solver sees the instance as `input.cnf`, never the hidden path or the family name.
"""
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..")))  # code_rules.py
ABOVE_NORMAL = 0x00008000 if os.name == "nt" else 0
EXTERNAL_SLACK = 1.5   # process start + solver import + exit may take this long beyond the time limit
LATE_FRACTION = 0.8    # correct UNSAT answers later than this share of the limit are reported (diagnostic only)

RUNNER = r'''
import sys, json
from time import perf_counter as _clock   # bound before the solver is imported
token = sys.stdin.readline().strip()
limit = float(sys.stdin.readline())

def parse(text):
    num_vars, clauses, cur = 0, [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line[0] == "c":
            continue
        if line.startswith("p "):
            parts = line.split()
            if len(parts) >= 3:
                num_vars = int(parts[2])
            continue
        for p in line.split():
            lit = int(p)
            if lit == 0:
                clauses.append(cur)
                cur = []
            else:
                cur.append(lit)
    return num_vars, clauses

with open("input.cnf", "r") as f:
    num_vars, clauses = parse(f.read())

def report(obj):
    sys.stdout.flush()
    sys.stdout.write("\n%s %s\n" % (token, json.dumps(obj)))
    sys.stdout.flush()

try:
    from solver import solve
    t0 = _clock()
    status, model = solve(num_vars, clauses, limit)
    seconds = _clock() - t0
except BaseException as e:
    report({"status": "ERROR", "model": None, "seconds": 0.0, "error": type(e).__name__})
    sys.exit(0)
try:
    json.dumps(model)
except Exception:
    status, model = "INVALID", None
report({"status": status, "model": model, "seconds": seconds})
'''


def parse_cnf(text):
    num_vars, clauses, cur = 0, [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('c'):
            continue
        if line.startswith('p '):
            parts = line.split()
            if len(parts) >= 3:
                num_vars = int(parts[2])
            continue
        for p in line.split():
            lit = int(p)
            if lit == 0:
                clauses.append(cur)
                cur = []
            else:
                cur.append(lit)
    return num_vars, clauses


def verify_model(num_vars, clauses, model):
    if not isinstance(model, list) or len(model) != num_vars:
        return False
    if any(type(lit) is not int or abs(lit) != i for i, lit in enumerate(model, 1)):
        return False
    assignment = {abs(lit): (lit > 0) for lit in model}
    for clause in clauses:
        if not any(assignment.get(abs(lit)) == (lit > 0) for lit in clause):
            return False
    return True


def run_instance(target_dir, cnf_file, expected, time_limit=10.0):
    with open(cnf_file, "r") as f:
        num_vars, clauses = parse_cnf(f.read())
    token = secrets.token_hex(16)
    got, seconds, points = "ERROR", 0.0, 0
    with tempfile.TemporaryDirectory() as tmpdir:
        shutil.copy(os.path.join(target_dir, "solver.py"), os.path.join(tmpdir, "solver.py"))
        shutil.copy(cnf_file, os.path.join(tmpdir, "input.cnf"))
        with open(os.path.join(tmpdir, "runner.py"), "w") as f:
            f.write(RUNNER)
        start = time.perf_counter()
        try:
            proc = subprocess.run([sys.executable, "runner.py"], cwd=tmpdir, capture_output=True, text=True,
                                  input="%s\n%r\n" % (token, time_limit), timeout=time_limit + 5.0,
                                  env=dict(os.environ, PYTHONHASHSEED="0"), creationflags=ABOVE_NORMAL)
            elapsed = time.perf_counter() - start
            lines = [ln[len(token) + 1:] for ln in proc.stdout.splitlines() if ln.startswith(token + " ")]
            if proc.returncode != 0 or len(lines) != 1:
                got, seconds = "ERROR", elapsed
            else:
                res = json.loads(lines[0])
                status, model, seconds = res.get("status"), res.get("model"), res.get("seconds", elapsed)
                if seconds > time_limit + 1.0 or elapsed > time_limit + EXTERNAL_SLACK:
                    got = "TIMEOUT"
                elif status == "SAT":
                    if verify_model(num_vars, clauses, model):
                        got, points = "SAT", (1 if expected == "SAT" else -2)
                    else:
                        got, points = "WRONG_MODEL", -2
                elif status == "UNSAT":
                    got, points = "UNSAT", (1 if expected == "UNSAT" else -2)
                elif status in ("UNKNOWN", "ERROR"):  # give-up or exception in solve(): 0, as the README says
                    got = status
                else:
                    got, points = "INVALID", -2
        except subprocess.TimeoutExpired:
            got, seconds = "TIMEOUT", time_limit + 5.0
        except (ValueError, KeyError):
            got = "ERROR"
    return {"file": os.path.basename(cnf_file), "expected": expected, "got": got, "seconds": seconds,
            "points": points, "status": got}


def main():
    target_dir = os.path.abspath(os.environ.get("BENCH_TARGET", "../template/sat"))
    index_file = os.path.join(HERE, "sat", "index.json")
    instances_dir = os.path.join(HERE, "sat", "instances")
    if not os.path.exists(index_file):
        print(json.dumps({"error": "Index not found"}))
        return

    from code_rules import check_code
    violation = check_code(os.path.join(target_dir, "solver.py"), "sat")
    if violation:
        print(json.dumps({"instances": [], "score_fraction": 0.0, "solved": 0, "wrong": 0, "violation": violation}))
        return

    with open(index_file, "r") as f:
        index = json.load(f)
    results, total_points, solved, wrong, late_unsat = [], 0, 0, 0, 0
    for item in index:
        res = run_instance(target_dir, os.path.join(instances_dir, item["file"]), item["expected"], 10.0)
        results.append(res)
        total_points += res["points"]
        if res["points"] == 1:
            solved += 1
            if res["got"] == "UNSAT" and res["seconds"] > LATE_FRACTION * 10.0:
                late_unsat += 1
        elif res["points"] == -2:
            wrong += 1
    print(json.dumps({"instances": results, "score_fraction": max(0, total_points) / len(index) if index else 0.0,
                      "solved": solved, "wrong": wrong, "late_unsat": late_unsat}))


if __name__ == "__main__":
    main()

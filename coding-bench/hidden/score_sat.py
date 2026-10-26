import os
import sys
import glob
import time
import tempfile
import subprocess
import shutil
import json

def verify_model(num_vars, clauses, model):
    if not isinstance(model, list) or len(model) != num_vars:
        return False
    if any(not isinstance(lit, int) or abs(lit) != i for i, lit in enumerate(model, 1)):
        return False
    assignment = {abs(lit): (lit > 0) for lit in model}
    
    for clause in clauses:
        sat = False
        for lit in clause:
            var = abs(lit)
            if assignment.get(var) == (lit > 0):
                sat = True
                break
        if not sat:
            return False
    return True

def run_instance(target_dir, cnf_file, expected, time_limit=10.0):
    with open(cnf_file, "r") as f:
        text = f.read()
    
    clauses = []
    num_vars = 0
    clause = []
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
                clauses.append(clause)
                clause = []
            else:
                clause.append(lit)

    script = f"""
import sys
import time
import json
from solver import solve, parse_dimacs

with open({repr(cnf_file)}, "r") as f:
    text = f.read()

num_vars, clauses = parse_dimacs(text)

start = time.perf_counter()
try:
    status, model = solve(num_vars, clauses, {time_limit})
except Exception as e:
    status, model = "ERROR", None
end = time.perf_counter()

print(json.dumps({{"status": status, "model": model, "seconds": end - start}}))
"""
    
    with tempfile.TemporaryDirectory() as tmpdir:
        shutil.copy(os.path.join(target_dir, "solver.py"), os.path.join(tmpdir, "solver.py"))
        runner_path = os.path.join(tmpdir, "runner.py")
        with open(runner_path, "w") as f:
            f.write(script)
            
        start_time = time.perf_counter()
        try:
            proc = subprocess.run(
                [sys.executable, "runner.py"],
                cwd=tmpdir,
                capture_output=True,
                text=True,
                timeout=time_limit + 5.0
            )
            elapsed = time.perf_counter() - start_time
            if proc.returncode != 0:
                got = "ERROR"
                seconds = elapsed
                points = 0
            else:
                try:
                    res = json.loads(proc.stdout.strip().splitlines()[-1])
                    status = res.get("status", "UNKNOWN")
                    model = res.get("model", None)
                    seconds = res.get("seconds", elapsed)
                    
                    if seconds > time_limit + 1.0 or elapsed > time_limit + 3.0:
                        got = "TIMEOUT"
                        points = 0
                    elif status == "SAT":
                        if verify_model(num_vars, clauses, model):
                            got = "SAT"
                            points = 1 if expected == "SAT" else -2
                        else:
                            got = "WRONG_MODEL"
                            points = -2
                    elif status == "UNSAT":
                        got = "UNSAT"
                        points = 1 if expected == "UNSAT" else -2
                    elif status == "UNKNOWN":
                        got = "UNKNOWN"
                        points = 0
                    else:
                        got = "INVALID"
                        points = -2
                except Exception:
                    got = "ERROR"
                    seconds = elapsed
                    points = 0
                
        except subprocess.TimeoutExpired:
            got = "TIMEOUT"
            seconds = time_limit + 5.0
            points = 0

    return {
        "file": os.path.basename(cnf_file),
        "expected": expected,
        "got": got,
        "seconds": seconds,
        "points": points,
        "status": got
    }

def main():
    target_dir = os.environ.get("BENCH_TARGET", "../template/sat")
    index_file = os.path.join(os.path.dirname(__file__), "sat/index.json")
    instances_dir = os.path.join(os.path.dirname(__file__), "sat/instances")
    
    if not os.path.exists(index_file):
        print(json.dumps({"error": "Index not found"}))
        return

    with open(index_file, "r") as f:
        index = json.load(f)
        
    results = []
    total_points = 0
    solved = 0
    wrong = 0
    
    for item in index:
        cnf_file = os.path.join(instances_dir, item["file"])
        expected = item["expected"]
        res = run_instance(target_dir, cnf_file, expected, time_limit=10.0)
        results.append(res)
        total_points += res["points"]
        if res["points"] == 1:
            solved += 1
        elif res["points"] == -2:
            wrong += 1
            
    score_fraction = max(0, total_points) / len(index) if index else 0.0
    
    output = {
        "instances": results,
        "score_fraction": score_fraction,
        "solved": solved,
        "wrong": wrong
    }
    print(json.dumps(output))

if __name__ == "__main__":
    main()

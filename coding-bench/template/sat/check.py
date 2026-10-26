import os
import sys
import glob
import time
import tempfile
import subprocess
import shutil

def verify_model(num_vars, clauses, model):
    if not model or len(model) != num_vars:
        return False
    # model contains literals like 1, -2, 3...
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

def run_instance(cnf_file, time_limit=10.0):
    expected = "UNSAT" if "unsat" in os.path.basename(cnf_file).lower() else "SAT"
    
    # Read the instance to get num_vars, clauses
    with open(cnf_file, "r") as f:
        text = f.read()
    
    # Simple DIMACS parser for check.py
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

    # We need to run solver.py in a fresh subprocess
    script = f"""
import sys
import time
import json
from solver import solve, parse_dimacs

with open({repr(cnf_file)}, "r") as f:
    text = f.read()

num_vars, clauses = parse_dimacs(text)

start = time.perf_counter()
status, model = solve(num_vars, clauses, {time_limit})
end = time.perf_counter()

print(json.dumps({{"status": status, "model": model, "seconds": end - start}}))
"""
    
    with tempfile.TemporaryDirectory() as tmpdir:
        shutil.copy("solver.py", os.path.join(tmpdir, "solver.py"))
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
                return expected, "ERROR", elapsed, 0
                
            try:
                import json
                res = json.loads(proc.stdout.strip().splitlines()[-1])
                status = res.get("status", "UNKNOWN")
                model = res.get("model", None)
                seconds = res.get("seconds", elapsed)
            except Exception:
                return expected, "ERROR", elapsed, 0
                
        except subprocess.TimeoutExpired:
            return expected, "TIMEOUT", time_limit + 5.0, 0
            
    if seconds > time_limit + 1.0:
        return expected, "TIMEOUT", seconds, 0
        
    if status == "SAT":
        if verify_model(num_vars, clauses, model):
            return expected, "SAT", seconds, 1 if expected == "SAT" else -2
        else:
            return expected, "WRONG_MODEL", seconds, -2
    elif status == "UNSAT":
        return expected, "UNSAT", seconds, 1 if expected == "UNSAT" else -2
    elif status == "UNKNOWN":
        return expected, "UNKNOWN", seconds, 0
    else:
        return expected, "INVALID", seconds, -2

def main():
    samples = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples", "*.cnf")))
    if not samples:
        print("No samples found.")
        return
        
    total_points = 0
    print(f"{'Instance':<30} | {'Expected':<8} | {'Got':<11} | {'Time (s)':<8} | {'Points'}")
    print("-" * 73)
    
    for cnf_file in samples:
        name = os.path.basename(cnf_file)
        expected, got, secs, points = run_instance(cnf_file)
        total_points += points
        print(f"{name:<30} | {expected:<8} | {got:<11} | {secs:<8.2f} | {points:>6}")
        
    score_frac = max(0, total_points) / len(samples)
    print("-" * 73)
    print(f"Total points: {total_points} / {len(samples)} (Score: {score_frac:.2f})")

if __name__ == "__main__":
    main()

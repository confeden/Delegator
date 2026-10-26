import os
import sys
import json
import time
import math
import copy
import subprocess
import importlib.util
from time import perf_counter as _clock  # bound before the solver is imported: it cannot patch it

def run_worker():
    # Read from stdin
    input_data = sys.stdin.read()
    data = json.loads(input_data)
    
    target_dir = data["target_dir"]
    template_dir = data["template_dir"]
    instance = data["instance"]
    
    # Import template modules
    spec = importlib.util.spec_from_file_location("instances", os.path.join(template_dir, "instances.py"))
    instances = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instances)
    
    spec = importlib.util.spec_from_file_location("template_routing", os.path.join(template_dir, "routing.py"))
    template_routing = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(template_routing)
    
    # Import target routing
    sys.path.insert(0, target_dir)
    try:
        import routing as target_routing
    except Exception as e:
        print(json.dumps({"status": f"error: {type(e).__name__}: {str(e)}"}))
        return
        
    depot, customers, capacity = instances.make_instance(
        instance["seed"], instance["n"], instance["kind"], instance["capacity_mode"]
    )
    
    # Deep copy inputs
    depot_copy = copy.deepcopy(depot)
    customers_copy = copy.deepcopy(customers)
    
    t0 = _clock()
    try:
        routes = target_routing.solve(depot_copy, customers_copy, capacity, instance["time_limit"])
    except Exception as e:
        print(json.dumps({"status": f"error: {type(e).__name__}: {str(e)}"}))
        return
    t1 = _clock()
    seconds = t1 - t0
    
    try:
        template_routing.validate(customers, capacity, routes)
        cost = template_routing.route_cost(depot, customers, routes)
        print(json.dumps({"status": "ok", "cost": cost, "seconds": seconds}))
    except ValueError as e:
        print(json.dumps({"status": f"invalid: {str(e)}"}))
    except Exception as e:
        print(json.dumps({"status": f"error: {type(e).__name__}: {str(e)}"}))

def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        run_worker()
        return

    target_dir = os.environ.get("BENCH_TARGET")
    if not target_dir:
        print("BENCH_TARGET environment variable not set", file=sys.stderr)
        sys.exit(1)
        
    target_dir = os.path.abspath(target_dir)
    this_dir = os.path.dirname(os.path.abspath(__file__))
    template_dir = os.path.abspath(os.path.join(this_dir, "../../template/routing"))
    
    with open(os.path.join(this_dir, "instances.json"), "r") as f:
        instances = json.load(f)
        
    results = []
    total_points = 0.0
    
    for inst in instances:
        worker_input = {
            "target_dir": target_dir,
            "template_dir": template_dir,
            "instance": inst
        }
        
        hard_timeout = inst["time_limit"] * 1.15 + 10
        
        try:
            proc = subprocess.run(
                [sys.executable, __file__, "--worker"],
                input=json.dumps(worker_input),
                text=True,
                capture_output=True,
                timeout=hard_timeout
            )
            
            if proc.returncode != 0:
                res = {"status": f"error: worker failed with code {proc.returncode}"}
                if proc.stderr:
                    res["status"] += f" ({proc.stderr.strip()})"
            else:
                try:
                    # the solver may print to stdout itself: the worker's result is the last line
                    res = json.loads(proc.stdout.strip().splitlines()[-1])
                except (json.JSONDecodeError, IndexError):
                    res = {"status": f"error: invalid JSON from worker: {proc.stdout.strip()}"}
        except subprocess.TimeoutExpired:
            res = {"status": "timeout"}
            
        cost = res.get("cost")
        seconds = res.get("seconds")
        status = res.get("status", "error: unknown")
        
        points = 0.0
        r = 0.0
        if status == "ok" and cost is not None and seconds is not None:
            if seconds > inst["time_limit"] * 1.15:
                status = "timeout"
            else:
                r = inst["reference_cost"] / cost
                # v1.5: quadratic - near-optimal solutions are where strong solvers differ
                points = max(0.0, min(1.0, (r - 0.85) / 0.15)) ** 2
                
        result_entry = {
            "seed": inst["seed"],
            "n": inst["n"],
            "cost": cost,
            "ref": inst["reference_cost"],
            "r": r,
            "points": points,
            "seconds": seconds,
            "status": status
        }
        results.append(result_entry)
        total_points += points
        
    score_fraction = total_points / len(instances) if instances else 0.0
    
    final_output = {
        "instances": results,
        "score_fraction": score_fraction
    }
    print(json.dumps(final_output))

if __name__ == '__main__':
    main()

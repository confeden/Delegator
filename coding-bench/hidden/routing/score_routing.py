"""Routing scorer (v1.7).

The worker process runs the agent's solver and only reports the routes it returned, on a line that starts with a
random per-run token. The parent accepts only that line, then regenerates the instance itself and validates the
routes and computes the cost - a solver cannot forge a result by printing its own JSON (atexit / __del__).
"""
import copy
import importlib.util
import json
import os
import secrets
import shutil
import subprocess
import sys
import tempfile
from time import perf_counter as _clock  # bound before the solver is imported: it cannot patch it

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..")))  # code_rules.py
TEMPLATE_DIR = os.path.abspath(os.path.join(HERE, "../../template/routing"))
ABOVE_NORMAL = 0x00008000 if os.name == "nt" else 0


def load_template(name):
    spec = importlib.util.spec_from_file_location("tpl_" + name, os.path.join(TEMPLATE_DIR, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run_worker():
    data = json.loads(sys.stdin.read())
    token, target_dir, instance = data["token"], data["target_dir"], data["instance"]
    instances = load_template("instances")
    depot, customers, capacity = instances.make_instance(
        instance["seed"], instance["n"], instance["kind"], instance["capacity_mode"])
    depot_copy, customers_copy = copy.deepcopy(depot), copy.deepcopy(customers)

    def report(obj):
        sys.stdout.flush()
        sys.stdout.write("\n%s %s\n" % (token, json.dumps(obj)))
        sys.stdout.flush()

    sys.path.insert(0, target_dir)
    try:
        import routing as target_routing
    except BaseException as e:  # noqa: BLE001
        report({"status": "error: import %s: %s" % (type(e).__name__, str(e)[:200])})
        return
    t0 = _clock()
    try:
        routes = target_routing.solve(depot_copy, customers_copy, capacity, instance["time_limit"])
    except BaseException as e:  # noqa: BLE001
        report({"status": "error: %s: %s" % (type(e).__name__, str(e)[:200])})
        return
    seconds = _clock() - t0
    try:
        routes = [[int(c) for c in r] for r in routes]
    except Exception as e:  # noqa: BLE001
        report({"status": "invalid: routes are not lists of ints (%s)" % type(e).__name__})
        return
    report({"status": "ok", "routes": routes, "seconds": seconds})


def worker_result(stdout, token):
    """The single line that starts with our token; anything else (prints, forged lines) is ignored."""
    found = [ln[len(token) + 1:] for ln in stdout.splitlines() if ln.startswith(token + " ")]
    if len(found) != 1:
        return {"status": "error: no/duplicate worker result (%d lines)" % len(found)}
    try:
        return json.loads(found[0])
    except json.JSONDecodeError:
        return {"status": "error: bad worker JSON"}


def main():
    target_dir = os.environ.get("BENCH_TARGET")
    if not target_dir:
        print("BENCH_TARGET environment variable not set", file=sys.stderr)
        sys.exit(1)
    target_dir = os.path.abspath(target_dir)

    from code_rules import check_code
    violation = check_code(os.path.join(target_dir, "routing.py"), "routing")
    if violation:
        print(json.dumps({"instances": [], "score_fraction": 0.0, "violation": violation}))
        return

    with open(os.path.join(HERE, "instances.json"), "r") as f:
        instances = json.load(f)
    tpl_instances, tpl_routing = load_template("instances"), load_template("routing")
    env = dict(os.environ, PYTHONHASHSEED="0")

    results, total_points = [], 0.0
    for inst in instances:
        token = secrets.token_hex(16)
        work = tempfile.mkdtemp(prefix="route_")
        run_dir = os.path.join(work, "routing")  # fresh copy per instance: no state kept between instances/repeats
        shutil.copytree(target_dir, run_dir, ignore=shutil.ignore_patterns("__pycache__"))
        worker_input = {"token": token, "target_dir": run_dir, "instance": inst}
        try:
            proc = subprocess.run([sys.executable, os.path.abspath(__file__), "--worker"],
                                  input=json.dumps(worker_input), text=True, capture_output=True,
                                  timeout=inst["time_limit"] * 1.15 + 10, env=env, cwd=work,
                                  creationflags=ABOVE_NORMAL)
            if proc.returncode != 0:
                res = {"status": "error: worker failed with code %d" % proc.returncode}
            else:
                res = worker_result(proc.stdout, token)
        except subprocess.TimeoutExpired:
            res = {"status": "timeout"}
        finally:
            shutil.rmtree(work, ignore_errors=True)

        status, seconds, cost = res.get("status", "error: unknown"), res.get("seconds"), None
        points, r = 0.0, 0.0
        if status == "ok":
            depot, customers, capacity = tpl_instances.make_instance(
                inst["seed"], inst["n"], inst["kind"], inst["capacity_mode"])
            try:
                tpl_routing.validate(customers, capacity, res["routes"])
                cost = tpl_routing.route_cost(depot, customers, res["routes"])
            except ValueError as e:
                status = "invalid: %s" % e
            except Exception as e:  # noqa: BLE001
                status = "error: %s: %s" % (type(e).__name__, e)
        if status == "ok" and cost and seconds is not None:
            if seconds > inst["time_limit"] * 1.15:
                status = "timeout"
            else:
                r = inst["reference_cost"] / cost
                points = max(0.0, min(1.0, (r - 0.85) / 0.15)) ** 2  # v1.5: quadratic scale
        results.append({"seed": inst["seed"], "n": inst["n"], "cost": cost, "ref": inst["reference_cost"],
                        "r": r, "points": points, "seconds": seconds, "status": status})
        total_points += points
    print(json.dumps({"instances": results, "score_fraction": total_points / len(instances) if instances else 0.0}))


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        run_worker()
    else:
        main()

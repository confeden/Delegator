# SAT — Boolean satisfiability solver (scored by how many instances you solve)

Implement `solve` in `solver.py`. Standard library only.

## API

`solve(num_vars: int, clauses: list[list[int]], time_limit: float) -> tuple[str, list[int] | None]`

- Variables are `1..num_vars`; a clause is a list of non-zero ints (`-3` = NOT x3), DIMACS style.
- Return `("SAT", model)` where `model` is a list of `num_vars` literals (`[1, -2, 3, ...]`, one per variable,
  in order) that satisfies every clause; or `("UNSAT", None)`; or `("UNKNOWN", None)` if you give up.
- Return within `time_limit` seconds (wall clock; keep a ~10% safety margin).

## Scoring (hidden)

41 hidden instances on a difficulty ladder, `time_limit` = 10 s each: a few easy reliability checks, then
random 3-SAT near the threshold (100-500 variables, SAT and UNSAT), large satisfiable instances (thousands of
variables, up to ~20,000 variables / ~125,000 clauses), and structured problems: graph colouring, pigeonhole, integer factoring circuits, XOR/parity
systems, sudoku. The top of the ladder is open-ended: about a quarter of the instances are not solved in 10 s
by any pure-Python solver we have, and the next quarter only by the best one - every extra instance counts.

Per instance: correct answer **+1**; `UNKNOWN` / timeout / exception **0**; **wrong answer −2**
(an invalid model, or `UNSAT` for a satisfiable instance). Score = max(0, total) / number of instances.
Never guess: return `UNKNOWN` when you are not sure.

## Local tools

`python check.py` runs your solver on the sample instances in `samples/` (DIMACS `.cnf` files whose
names say `sat` or `unsat`) and prints result, time and the score.

## Code rules

Allowed imports ONLY: `math random time heapq collections itertools functools bisect array typing dataclasses operator`, plus `sys` for `sys.setrecursionlimit` / `sys.maxsize` only. No file access, subprocesses, threads or `atexit`; no `open eval exec compile __import__ getattr setattr delattr globals locals vars breakpoint input help attrgetter methodcaller` (not even as variable names), no dunder attributes (`__class__`, `__dict__`, ...), no frame attributes (`gi_frame`, `f_back`, ...). A violation scores 0 for the whole task; `python check.py` runs this check first. Also rejected here (Delegator build): `memoryview`, a file over 400 KB, and any mention of grader data in the file (paths such as `hidden/`, scorer or `run_info` names).

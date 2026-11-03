# ROUTING — capacitated vehicle routing (scored by solution quality)

Implement `solve` in `routing.py`. Standard library only.

## Problem

- Depot `depot = (x, y)`; customers `customers[i] = (x, y, demand)`, `demand >= 1`.
- Unlimited identical vehicles of capacity `capacity`. A route starts at the depot, visits customers,
  returns to the depot; its total demand must be `<= capacity`. Every customer visited exactly once.
- Cost = total Euclidean length of all routes. Minimize it.

`solve(depot, customers, capacity, time_limit) -> list[list[int]]` — routes as lists of customer indices
(depot not included). Return within `time_limit` seconds (keep a ~10% margin). `routing.py` provides
`route_cost(...)` and `validate(...)`.

## Scoring (hidden)

8 hidden instances, 100-1000 customers (uniform/clustered, mostly long routes, one with tight capacity),
`time_limit` = 3 s. Per instance `r = best_known_cost / your_cost`, `points = clamp((r - 0.85) / 0.15, 0, 1) ** 2`
(quadratic: r = 0.90 -> 0.11, 0.95 -> 0.44, 0.98 -> 0.75, 1.0 -> 1). The best-known costs are the best of several
5-minute runs of the strongest solvers we have; in 3 s even those solvers reach r = 0.96-0.99 - there is headroom.
Invalid solution, exception or time limit exceeded → 0 for that instance.

`python check.py` runs your solver on sample instances and prints cost, time and validity next to a
nearest-neighbour baseline. A valid simple solution first; then improve (use the whole time budget).

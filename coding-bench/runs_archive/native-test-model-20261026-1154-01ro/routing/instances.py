import random

def make_instance(seed: int, n: int, kind: str, capacity_mode: str) -> tuple[tuple[float, float], list[tuple[float, float, int]], int]:
    rng = random.Random(seed)
    
    if kind == "corner":
        depot = (0.0, 0.0)
    else:
        depot = (500.0, 500.0)
        
    customers = []
    
    if kind in ("uniform", "corner"):
        for _ in range(n):
            x = rng.uniform(0, 1000)
            y = rng.uniform(0, 1000)
            demand = rng.randint(1, 20)
            customers.append((x, y, demand))
    elif kind == "clustered":
        num_clusters = max(1, n // 20)
        clusters = []
        for _ in range(num_clusters):
            cx = rng.uniform(100, 900)
            cy = rng.uniform(100, 900)
            clusters.append((cx, cy))
            
        for _ in range(n):
            cx, cy = rng.choice(clusters)
            x = rng.gauss(cx, 50)
            y = rng.gauss(cy, 50)
            x = max(0.0, min(1000.0, x))
            y = max(0.0, min(1000.0, y))
            demand = rng.randint(1, 20)
            customers.append((x, y, demand))
    else:
        raise ValueError(f"Unknown kind {kind}")
        
    avg_demand = sum(c[2] for c in customers) / n if n > 0 else 10
    
    if capacity_mode == "tight":
        capacity = int(math.ceil(avg_demand * 6))
    elif capacity_mode == "loose":
        capacity = int(math.ceil(avg_demand * 25))
    else:
        raise ValueError(f"Unknown capacity_mode {capacity_mode}")
        
    return depot, customers, capacity

SAMPLES = [
    (1, 50, "uniform", "tight"),
    (2, 100, "clustered", "loose"),
    (3, 200, "corner", "tight"),
    (4, 300, "uniform", "loose"),
]

import math

import math

def route_cost(depot: tuple[float, float], customers: list[tuple[float, float, int]], routes: list[list[int]]) -> float:
    """
    Computes the total Euclidean cost of the given routes.
    See README.md for the problem description.
    """
    total = 0.0
    dx, dy = depot
    for route in routes:
        if not route:
            continue
        cx, cy, _ = customers[route[0]]
        total += math.dist((dx, dy), (cx, cy))
        for i in range(len(route) - 1):
            px, py, _ = customers[route[i]]
            nx, ny, _ = customers[route[i+1]]
            total += math.dist((px, py), (nx, ny))
        lx, ly, _ = customers[route[-1]]
        total += math.dist((lx, ly), (dx, dy))
    return total

def validate(customers: list[tuple[float, float, int]], capacity: int, routes: list[list[int]]) -> None:
    """
    Validates that the routes form a valid Capacitated Vehicle Routing Problem solution.
    Raises ValueError with a clear message if invalid.
    """
    n = len(customers)
    visited = set()
    for route_idx, route in enumerate(routes):
        route_demand = 0
        for cust_idx in route:
            if not isinstance(cust_idx, int) or cust_idx < 0 or cust_idx >= n:
                raise ValueError(f"Invalid customer index {cust_idx} in route {route_idx}.")
            if cust_idx in visited:
                raise ValueError(f"Customer {cust_idx} visited more than once.")
            visited.add(cust_idx)
            route_demand += customers[cust_idx][2]
        if route_demand > capacity:
            raise ValueError(f"Route {route_idx} exceeds capacity: {route_demand} > {capacity}.")
    
    if len(visited) != n:
        missing = set(range(n)) - visited
        raise ValueError(f"Not all customers visited. Missing: {missing}")

def solve(depot: tuple[float, float], customers: list[tuple[float, float, int]], capacity: int, time_limit: float) -> list[list[int]]:
    """
    Solves the CVRP. See README.md for details.
    """
    raise NotImplementedError("Implement this function.")

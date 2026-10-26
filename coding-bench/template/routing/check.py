import time
import math
from instances import make_instance, SAMPLES
from routing import solve, route_cost, validate

def nn_baseline(depot, customers, capacity):
    n = len(customers)
    unvisited = set(range(n))
    routes = []
    
    while unvisited:
        route = []
        route_demand = 0
        curr_pos = depot
        
        while unvisited:
            best_cust = None
            best_dist = float('inf')
            
            for i in unvisited:
                cx, cy, demand = customers[i]
                if route_demand + demand <= capacity:
                    dist = math.dist(curr_pos, (cx, cy))
                    if dist < best_dist:
                        best_dist = dist
                        best_cust = i
            
            if best_cust is None:
                break
                
            route.append(best_cust)
            route_demand += customers[best_cust][2]
            curr_pos = (customers[best_cust][0], customers[best_cust][1])
            unvisited.remove(best_cust)
            
        routes.append(route)
        
    return routes

def main():
    print("Running local benchmark on SAMPLES...")
    print(f"{'Seed':>5} {'N':>4} {'Kind':>10} {'CapMode':>8} {'Status':>10} {'Cost':>10} {'NNCost':>10} {'Time(s)':>8} {'Details'}")
    
    for seed, n, kind, cap_mode in SAMPLES:
        depot, customers, capacity = make_instance(seed, n, kind, cap_mode)
        
        nn_routes = nn_baseline(depot, customers, capacity)
        nn_c = route_cost(depot, customers, nn_routes)
        
        t0 = time.time()
        try:
            routes = solve(depot, customers, capacity, 3.0)
            t1 = time.time()
            elapsed = t1 - t0
            
            try:
                validate(customers, capacity, routes)
                c = route_cost(depot, customers, routes)
                status = "VALID"
                details = ""
            except ValueError as e:
                c = 0.0
                status = "INVALID"
                details = str(e)
                
            print(f"{seed:5} {n:4} {kind:10} {cap_mode:8} {status:10} {c:10.2f} {nn_c:10.2f} {elapsed:8.3f} {details}")
            
        except NotImplementedError as e:
            print(f"{seed:5} {n:4} {kind:10} {cap_mode:8} {'ERROR':10} {'-':>10} {nn_c:10.2f} {'-':>8} {e}")
        except Exception as e:
            print(f"{seed:5} {n:4} {kind:10} {cap_mode:8} {'ERROR':10} {'-':>10} {nn_c:10.2f} {'-':>8} {type(e).__name__}: {e}")

if __name__ == '__main__':
    main()

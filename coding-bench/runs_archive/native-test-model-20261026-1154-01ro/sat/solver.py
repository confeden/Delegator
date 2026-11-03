def parse_dimacs(text: str) -> tuple[int, list[list[int]]]:
    """
    Parses a DIMACS CNF string.
    Returns (num_vars, clauses).
    """
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
        
        parts = line.split()
        for p in parts:
            lit = int(p)
            if lit == 0:
                clauses.append(clause)
                clause = []
            else:
                clause.append(lit)
            
    return num_vars, clauses

def solve(num_vars: int, clauses: list[list[int]], time_limit: float) -> tuple[str, list[int] | None]:
    """
    Solve a SAT instance.
    See README.md for details.
    """
    return "UNKNOWN", None

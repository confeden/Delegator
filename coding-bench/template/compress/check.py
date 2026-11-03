import os
import sys
import time
import zlib
import tempfile
import subprocess
import glob
import random

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from code_rules import check_code  # the very same static rules as the hidden scorer

# Per-file R_full of the hidden scorer (full points at 1.3x the best known codec); other files: ~1.8.
SAMPLE_R_FULL = {"code.py.txt": 1.79, "data.csv": 1.83, "logs.json": 2.53, "prose.txt": 1.94}
TIMEOUT = 25.0


def run_in_subprocess(func_name, input_data, cwd):
    # Write input to temp file
    fd_in, path_in = tempfile.mkstemp()
    with os.fdopen(fd_in, 'wb') as f:
        f.write(input_data)
        
    fd_out, path_out = tempfile.mkstemp()
    os.close(fd_out) # just need the path
    
    script = f"""
import sys
import codec
with open(r'{path_in}', 'rb') as f:
    data = f.read()
try:
    res = codec.{func_name}(data)
    with open(r'{path_out}', 'wb') as f:
        f.write(res)
except Exception as e:
    print(e.__class__.__name__ + ": " + str(e), file=sys.stderr)
    sys.exit(1)
"""
    t0 = time.time()
    try:
        proc = subprocess.run([sys.executable, "-c", script], cwd=cwd, capture_output=True, timeout=TIMEOUT + 5)
    except subprocess.TimeoutExpired:
        os.remove(path_in)
        os.remove(path_out)
        raise RuntimeError("timeout (> %d s)" % TIMEOUT)
    t1 = time.time()
    
    if proc.returncode != 0:
        os.remove(path_in)
        os.remove(path_out)
        raise RuntimeError(f"Subprocess failed: {proc.stderr.decode('utf-8', 'replace').strip()}")
        
    with open(path_out, 'rb') as f:
        res = f.read()
        
    os.remove(path_in)
    os.remove(path_out)
    return res, t1 - t0

def bench_file(name, data, cwd):
    print(f"--- {name} ({len(data)} bytes) ---")
    try:
        compressed, c_time = run_in_subprocess("compress", data, cwd)
        decompressed, d_time = run_in_subprocess("decompress", compressed, cwd)
    except Exception as e:
        print(f"Error: {e}")
        return
        
    if decompressed != data:
        print("Error: Decompressed data does not match original!")
        return
        
    zlib_comp = zlib.compress(data, 9)
    zlib_size = len(zlib_comp)
    my_size = len(compressed)
    
    r = zlib_size / my_size if my_size > 0 else 0
    r_full = SAMPLE_R_FULL.get(name, 1.8)  # hidden R_full: ~1.8 text, ~2.5 csv/logs, ~2.7 syslog
    points = max(0, min(1, (r - 0.6) / (r_full - 0.6)))
    
    print(f"Size: {my_size} (zlib: {zlib_size})")
    print(f"Ratio r = zlib/yours: {r:.4f}")
    print(f"Points: {points:.2f}/1.00")
    print(f"Time: compress {c_time:.3f}s, decompress {d_time:.3f}s" + ("  <-- over the %d s limit!" % TIMEOUT if max(c_time, d_time) > TIMEOUT else ""))

def check_edge_cases(cwd):
    print("--- Edge Cases ---")
    cases = {
        "empty": b"",
        "single byte": b"a",
        "zeros 100k": b"\x00" * 100000,
        "all bytes": bytes(range(256)) * 50,
        "random 100k": random.Random(12345).randbytes(100000),
    }
    for name, data in cases.items():
        try:
            compressed, _ = run_in_subprocess("compress", data, cwd)
            decompressed, _ = run_in_subprocess("decompress", compressed, cwd)
            if decompressed != data:
                print(f"Fail {name}: mismatched output")
            elif name == "random 100k" and len(compressed) > len(data) * 1.01 + 16:
                print(f"Fail {name}: grew to {len(compressed)} bytes (limit {int(len(data) * 1.01 + 16)}); "
                      "the hidden scorer multiplies the whole task score by 0.8 for this")
            else:
                print(f"Pass {name}")
        except Exception as e:
            print(f"Fail {name}: {e}")

def main():
    cwd = os.path.dirname(os.path.abspath(__file__))
    samples_dir = os.path.join(cwd, "samples")
    
    violation = check_code(os.path.join(cwd, "codec.py"), "compress")
    if violation:
        print("STATIC VIOLATION (the hidden scorer gives 0 for the whole task): " + violation)
        return
    print("Static rules: ok")
    check_edge_cases(cwd)
    
    if os.path.exists(samples_dir):
        for path in sorted(glob.glob(os.path.join(samples_dir, "*"))):
            if os.path.isfile(path):
                name = os.path.basename(path)
                with open(path, "rb") as f:
                    data = f.read()
                bench_file(name, data, cwd)

if __name__ == "__main__":
    main()

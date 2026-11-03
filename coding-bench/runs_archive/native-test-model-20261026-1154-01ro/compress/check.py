import os
import sys
import time
import zlib
import tempfile
import subprocess
import glob

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
    proc = subprocess.run([sys.executable, "-c", script], cwd=cwd, capture_output=True)
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
    points = max(0, min(1, (r - 0.6) / (1.8 - 0.6)))  # approximate: hidden R_full is ~1.8 for text, ~2.5 for logs
    
    print(f"Size: {my_size} (zlib: {zlib_size})")
    print(f"Ratio r = zlib/yours: {r:.4f}")
    print(f"Points: {points:.2f}/1.00")
    print(f"Time: compress {c_time:.3f}s, decompress {d_time:.3f}s")

def check_edge_cases(cwd):
    print("--- Edge Cases ---")
    cases = {
        "empty": b"",
        "single byte": b"a",
        "zeros 100k": b"\x00" * 100000,
        "all bytes": bytes(range(256)) * 50
    }
    for name, data in cases.items():
        try:
            compressed, _ = run_in_subprocess("compress", data, cwd)
            decompressed, _ = run_in_subprocess("decompress", compressed, cwd)
            if decompressed != data:
                print(f"Fail {name}: mismatched output")
            else:
                print(f"Pass {name}")
        except Exception as e:
            print(f"Fail {name}: {e}")

def main():
    cwd = os.path.dirname(os.path.abspath(__file__))
    samples_dir = os.path.join(cwd, "samples")
    
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

import os
import sys
import json
import ast
import zlib
import time
import tempfile
import subprocess
import shutil

ALLOWED_IMPORTS = {'math', 'collections', 'heapq', 'struct', 'array', 'itertools', 'functools', 'bisect', 'typing', 'dataclasses', 'operator'}
FORBIDDEN_BUILTINS = {'open', 'eval', 'exec', 'compile', '__import__', 'getattr', 'setattr', 'delattr', 'globals',
                      'locals', 'vars', 'breakpoint', 'input', 'help'}
FORBIDDEN_DUNDERS = {'__builtins__', '__globals__', '__subclasses__', '__class__', '__bases__', '__base__', '__mro__',
                     '__loader__', '__spec__', '__dict__', '__code__', '__closure__', '__getattribute__', '__self__'}
# v1.6.1: operator.attrgetter/methodcaller take the attribute name as a string and bypass the AST checks above;
# allowed stdlib modules re-export sys/os (dataclasses.sys.modules[...]) - closed by banning these attribute names.
FORBIDDEN_ATTRS = FORBIDDEN_DUNDERS | {'attrgetter', 'methodcaller', 'sys', 'os', 'modules', 'builtins'}

# v1.6: full points only at 1.3x the best r we know for each file (reference/compress_strong: a tuned
# context-mixing codec, ~12 s per file here): code 1.373, csv 1.409, logs 1.945, mixed 1.360, prose 1.494,
# and v1.6 additions: code2 1.391, data2 1.95, syslog2 2.095.
FULL_POINTS_R = {"code.py.txt": 1.79, "data.csv": 1.83, "logs.json": 2.53, "mixed.txt": 1.77, "prose.txt": 1.94,
                 "code2.py.txt": 1.81, "data2.csv": 2.53, "syslog2.txt": 2.72}


def check_static(codec_path):
    sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    from code_rules import check_code
    return check_code(codec_path, "compress")


def run_subprocess(func_name, input_file, output_file, codec_dir):
    script = f"""
import sys
import codec
with open(r'{input_file}', 'rb') as f:
    data = f.read()
res = codec.{func_name}(data)
with open(r'{output_file}', 'wb') as f:
    f.write(res)
"""
    t0 = time.time()
    try:
        proc = subprocess.run([sys.executable, "-c", script], cwd=codec_dir, capture_output=True, timeout=30.0,
                              env=dict(os.environ, PYTHONHASHSEED="0"),
                              creationflags=0x00008000 if os.name == "nt" else 0)
        t1 = time.time()
        if proc.returncode != 0:
            return False, proc.stderr.decode('utf-8', 'replace').strip(), t1 - t0
        return True, "", t1 - t0
    except subprocess.TimeoutExpired:
        return False, "Timeout", 30.0
    except Exception as e:
        return False, str(e), 0.0

def score_file(name, data, codec_path):
    # Temp dirs for compress and decompress
    dir_c = tempfile.mkdtemp()
    dir_d = tempfile.mkdtemp()
    
    in_file = os.path.join(dir_c, "in.bin")
    out_file = os.path.join(dir_c, "out.bin")
    
    with open(in_file, "wb") as f:
        f.write(data)
        
    shutil.copy2(codec_path, os.path.join(dir_c, "codec.py"))
    
    ok_c, err_c, t_c = run_subprocess("compress", in_file, out_file, dir_c)
    
    if not ok_c:
        shutil.rmtree(dir_c)
        shutil.rmtree(dir_d)
        return {"name": name, "size": len(data), "zlib": zlib.compress(data, 9), "yours": 0, "r": 0, "points": 0, "c_sec": t_c, "d_sec": 0, "status": f"compress error: {err_c}"}
        
    with open(out_file, "rb") as f:
        compressed = f.read()
        
    shutil.rmtree(dir_c) # delete compress dir completely
    
    blob_file = os.path.join(dir_d, "blob.bin")
    dec_file = os.path.join(dir_d, "dec.bin")
    with open(blob_file, "wb") as f:
        f.write(compressed)
        
    shutil.copy2(codec_path, os.path.join(dir_d, "codec.py"))
    
    ok_d, err_d, t_d = run_subprocess("decompress", blob_file, dec_file, dir_d)
    
    if not ok_d:
        shutil.rmtree(dir_d)
        return {"name": name, "size": len(data), "zlib": zlib.compress(data, 9), "yours": len(compressed), "r": 0, "points": 0, "c_sec": t_c, "d_sec": t_d, "status": f"decompress error: {err_d}"}
        
    with open(dec_file, "rb") as f:
        decompressed = f.read()
        
    shutil.rmtree(dir_d)
    
    if decompressed != data:
        return {"name": name, "size": len(data), "zlib": len(zlib.compress(data, 9)), "yours": len(compressed), "r": 0, "points": 0, "c_sec": t_c, "d_sec": t_d, "status": "mismatch"}
        
    zlib_comp = len(zlib.compress(data, 9))
    my_comp = len(compressed)
    
    r = zlib_comp / my_comp if my_comp > 0 else 0
    
    if name == "random.bin":
        if my_comp <= len(data) * 1.01 + 16:
            points = 1.0
        else:
            points = 0.0
    else:
        target = FULL_POINTS_R.get(name, 2.0)
        points = max(0, min(1, (r - 0.6) / (target - 0.6)))
        
    return {"name": name, "size": len(data), "zlib": zlib_comp, "yours": my_comp, "r": r, "points": points, "c_sec": t_c, "d_sec": t_d, "status": "ok"}

def main():
    target_dir = os.environ.get("BENCH_TARGET")
    if not target_dir:
        print(json.dumps({"files": [], "score_fraction": 0, "violation": "BENCH_TARGET not set"}))
        return
        
    codec_path = os.path.join(target_dir, "codec.py")
    violation = check_static(codec_path)
    if violation:
        print(json.dumps({"files": [], "score_fraction": 0, "violation": violation}))
        return
        
    cwd = os.path.dirname(os.path.abspath(__file__))
    corpus_dir = os.path.join(cwd, "corpus")
    
    if not os.path.exists(corpus_dir):
        print(json.dumps({"files": [], "score_fraction": 0, "violation": "Corpus not found"}))
        return
        
    results = []
    random_ok = False
    points_sum = 0
    count = 0
    
    for filename in sorted(os.listdir(corpus_dir)):
        path = os.path.join(corpus_dir, filename)
        if not os.path.isfile(path):
            continue
            
        with open(path, "rb") as f:
            data = f.read()
            
        res = score_file(filename, data, codec_path)
        # zlib field needs to be int if it was returned as bytes on error
        if isinstance(res["zlib"], bytes):
            res["zlib"] = len(res["zlib"])
        results.append(res)
        if filename == "random.bin":
            random_ok = res["status"] == "ok" and res["points"] == 1.0
            continue  # correctness gate only, not part of the mean
        points_sum += res["points"]
        count += 1

    score_fraction = points_sum / count if count > 0 else 0
    if not random_ok:
        score_fraction *= 0.8
    print(json.dumps({"files": results, "score_fraction": score_fraction, "violation": None}))

if __name__ == "__main__":
    main()

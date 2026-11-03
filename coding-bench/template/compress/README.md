# COMPRESS — lossless compressor (scored by compression ratio vs zlib)

Implement `compress(data: bytes) -> bytes` and `decompress(blob: bytes) -> bytes` in `codec.py`.

## Rules

- `decompress(compress(x)) == x` exactly, for any bytes (empty, 1 byte, long runs, random data).
  A round-trip failure, exception or timeout → 0 for that file.
- `compress` and `decompress` run in separate fresh processes; everything needed must be in the blob.
- Allowed imports ONLY: `math collections heapq struct array itertools functools bisect typing dataclasses operator`.
  Any other import (`zlib`, `lzma`, `bz2`, `os`, `io`, ...) or use of `open`/`eval`/`exec`/`compile`/`__import__`
  → 0 for the whole task. The same applies to the names `getattr setattr delattr globals locals vars breakpoint
  input help attrgetter methodcaller` (even as variable names), to dunder attributes such as `__class__`/`__dict__`
  (also inside strings), and to the attributes `.sys .os .modules .builtins`. `python check.py` runs this static check. All code in `codec.py`, at most 60 KB.
- Time limit: 25 s for compress and 25 s for decompress per file (files ~100-120 KB; pure Python — measure speed).

## Scoring (hidden)

8 hidden files (~120 KB each): English prose, Python code (2 files), CSV (2 files), JSON logs, mixed text,
syslog-style text. Per file
`r = zlib9_size / your_size`, `points = clamp((r - 0.6) / (R_full - 0.6), 0, 1)`, where `R_full` is set per file
at **1.3x the ratio of the strongest codec we know** (a tuned context-mixing codec, ~12 s per file):
R_full is about 1.8 for prose/code/mixed text, about 2.5 for CSV and JSON logs, about 2.7 for syslog text. Nobody is expected to reach it -
there is no ceiling, every bit of extra compression counts. (For orientation: zlib-equivalent ≈ 0.25-0.35 points,
an order-2 arithmetic coder ≈ 0.4, strong context mixing ≈ 0.65.) An extra random file is a correctness gate:
if it does not round-trip (or grows by more than 1% + 16 bytes), the task score is multiplied by 0.8 (`check.py` tests this too).

`python check.py` compresses `samples/`, checks round-trips in fresh processes, and prints your size vs
zlib-9, `r`, points and timings.

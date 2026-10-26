"""T10 - lossless compressor. See README.md for the rules and scoring.

Allowed imports only: math, collections, heapq, struct, array, itertools, functools,
bisect, typing, dataclasses, operator.
"""


def compress(data: bytes) -> bytes:
    """Return a compressed representation of `data` (must contain everything needed to decompress)."""
    raise NotImplementedError


def decompress(blob: bytes) -> bytes:
    """Invert `compress` exactly: decompress(compress(x)) == x for every bytes value x."""
    raise NotImplementedError

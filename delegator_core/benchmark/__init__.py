"""Randomised, self-grading benchmark: the user's own IDE model against the
same model with Delegator in the loop.

The engine lives inside the core on purpose. The core is a frozen Python
runtime that every install already has, so a user needs neither Python nor any
package to run the benchmark — and the candidate code is executed by
re-invoking that same executable in a sandboxed child process.

`BENCHMARK_VERSION` is the version of the TASK SET and the scoring rules, and
it is printed in every report: two reports may only be compared when this
number matches. It moves independently of the Delegator version.
"""

from .engine import (
    BENCHMARK_VERSION,
    BenchmarkStore,
    export_report,
    finish_run,
    generate_run,
    missing_answers,
    record_answer,
    run_status,
)
from .stats import load_items, summarise
from .templates import known_template_ids

__all__ = [
    "BENCHMARK_VERSION",
    "BenchmarkStore",
    "export_report",
    "finish_run",
    "generate_run",
    "known_template_ids",
    "load_items",
    "missing_answers",
    "record_answer",
    "run_status",
    "summarise",
]

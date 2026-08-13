"""Mechanical defects in a draft answer: does the code even compile?

Run #4 of the public benchmark caught `improve` red-handed. Both arms submitted
a SQL query that SQLite refuses to prepare — `misuse of window function
ROW_NUMBER()` — the reviewer read it, judged it correct, and Delegator returned
the broken draft unchanged after eleven seconds. **A reviewer that only READS
cannot see that.** No amount of a better prompt fixes it.

This module is the part that does not read. It compiles every Python block and
prepares every SQL block against a schema recovered from the task text. It never
executes anything: `compile()` stops before the first statement runs, and
`EXPLAIN` stops before the query does.

The rule everywhere here is **no false positives**. A defect that is not real
turns a correct draft into a rewrite, and a rewrite of a correct answer is how
`improve` damages things. Every check that cannot be certain stays silent.
"""

from __future__ import annotations

import json
import re
import sqlite3
import textwrap
from typing import Any

FENCE = re.compile(r"```([A-Za-z0-9_+-]*)[ \t]*\r?\n(.*?)```", re.S)

PYTHON_LANGS = {"python", "py", "python3"}
SQL_LANGS = {"sql", "sqlite", "sqlite3", "postgres", "postgresql", "mysql"}

# A snippet, not a program: reporting a SyntaxError here would be a false
# positive, and a false defect is worse than a missed one.
FRAGMENT_MARKERS = (
    "\n...",
    "# ...",
    "# …",
    "<...>",
    "…\n",
)
FRAGMENT_ERRORS = (
    "'return' outside function",
    "'yield' outside function",
    "'await' outside function",
    "unexpected indent",
    "expected an indented block",
    "'break' outside loop",
    "'continue' not properly in loop",
)

# Types that make «name(col TYPE, …)» in prose unmistakably a table definition
# rather than a function signature.
SQL_TYPES = (
    "INTEGER", "INT", "TEXT", "REAL", "BLOB", "NUMERIC", "VARCHAR", "CHAR",
    "DATE", "DATETIME", "TIMESTAMP", "BOOLEAN", "DOUBLE", "FLOAT", "DECIMAL",
)
_TABLE_IN_PROSE = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(([^()]{3,400})\)")
_CREATE_TABLE = re.compile(
    r"CREATE\s+(?:TEMP\s+|TEMPORARY\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?"
    r"[A-Za-z_][A-Za-z0-9_]*\s*\([^;]*\)",
    re.I | re.S,
)

# Errors that only mean "this schema is not the one you meant" — never a defect
# of the draft, because we reconstructed the schema by guessing.
_SCHEMA_NOISE = ("no such table", "no such column", "no such function", "ambiguous column name")


def extract_blocks(text: str) -> list[tuple[str, str]]:
    """[(language, code)] for every fenced block, language lowercased."""
    return [
        (match.group(1).strip().lower(), match.group(2))
        for match in FENCE.finditer(text or "")
    ]


def _looks_like_a_fragment(code: str) -> bool:
    return any(marker in code for marker in FRAGMENT_MARKERS)


def python_defect(code: str) -> str | None:
    """The compile error, or None when the block compiles or is a fragment."""
    source = textwrap.dedent(code)
    if not source.strip() or _looks_like_a_fragment(source):
        return None
    try:
        compile(source, "<draft>", "exec")
    except SyntaxError as error:
        message = (error.msg or "синтаксическая ошибка").strip()
        if any(marker in message for marker in FRAGMENT_ERRORS):
            return None
        where = " (строка %d)" % error.lineno if error.lineno else ""
        return "код на Python не компилируется%s: %s" % (where, message)
    except (ValueError, MemoryError, RecursionError):
        # Null bytes, absurd nesting: not something to blame the draft for.
        return None
    return None


def schema_from_text(text: str) -> list[str]:
    """CREATE TABLE statements recoverable from the task text.

    Two sources: a real `CREATE TABLE` pasted into the prompt, and the way
    people describe a table in prose — `logins(user_id INTEGER, day INTEGER)`.
    The prose form only counts when the parentheses hold a recognisable SQL
    type, so a function signature is never mistaken for a table.
    """
    statements = [match.group(0) for match in _CREATE_TABLE.finditer(text or "")]
    if statements:
        return statements
    seen: set[str] = set()
    for match in _TABLE_IN_PROSE.finditer(text or ""):
        name, body = match.group(1), match.group(2)
        upper = body.upper()
        if not any(re.search(r"\b%s\b" % kind, upper) for kind in SQL_TYPES):
            continue
        if name.upper() in {"SELECT", "VALUES", "TABLE"} or name.lower() in seen:
            continue
        seen.add(name.lower())
        statements.append("CREATE TABLE %s (%s)" % (name, body))
    return statements


def sql_defect(query: str, schema: list[str]) -> str | None:
    """The prepare error, or None when the query prepares (or cannot be judged).

    Without a schema SQLite stops at «no such table» long before it looks at
    the rest of the query, so a bare syntax check would have missed exactly the
    error that started all this. With the schema in place it reports the real
    one.
    """
    statement = (query or "").strip().rstrip(";").strip()
    if not statement or not schema:
        return None
    connection = sqlite3.connect(":memory:")
    try:
        for create in schema:
            try:
                connection.execute(create)
            except sqlite3.Error:
                return None  # our reconstruction is wrong; stay silent
        try:
            connection.execute("EXPLAIN " + statement)
        except sqlite3.Error as error:
            message = str(error).strip()
            if any(noise in message.lower() for noise in _SCHEMA_NOISE):
                return None
            return "SQL-запрос не выполняется: %s" % message
    finally:
        connection.close()
    return None


def check_draft(task: str, draft: str) -> dict[str, Any]:
    """{defects, checkedPython, checkedSql, schemaTables} for a draft answer."""
    schema = schema_from_text(task)
    defects: list[str] = []
    python_blocks = sql_blocks = 0
    for language, code in extract_blocks(draft):
        if language in PYTHON_LANGS or (not language and re.search(r"(?m)^\s*(def|class)\s+\w+", code)):
            python_blocks += 1
            defect = python_defect(code)
        elif language in SQL_LANGS:
            sql_blocks += 1
            defect = sql_defect(code, schema)
        else:
            continue
        if defect and defect not in defects:
            defects.append(defect)
    return {
        "defects": defects[:5],
        "checkedPython": python_blocks,
        "checkedSql": sql_blocks,
        "schemaTables": len(schema),
    }


def run_cli(task_path: str, draft_path: str, result_path: str) -> int:
    """`delegator-core.exe --lint-draft <task> <draft> <result>`.

    A CLI and not an HTTP endpoint on purpose: `improve` is called by IDE agents
    whether or not the Delegator window is open, and a check that only works
    while the core happens to be listening is a check that is usually skipped.
    """
    def read(path: str) -> str:
        try:
            with open(path, encoding="utf-8-sig") as handle:
                return handle.read()
        except OSError:
            return ""

    payload: dict[str, Any]
    try:
        payload = check_draft(read(task_path), read(draft_path))
    except Exception as error:  # noqa: BLE001 - a linter must never fail a delegation
        payload = {"defects": [], "error": str(error)}
    try:
        with open(result_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
    except OSError:
        return 1
    return 0


LINT_FLAG = "--lint-draft"


def maybe_run_as_linter(argv: list[str]) -> bool:
    """True when this process was started only to lint one draft."""
    if len(argv) >= 5 and argv[1] == LINT_FLAG:
        run_cli(argv[2], argv[3], argv[4])
        return True
    return False

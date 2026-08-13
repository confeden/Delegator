"""`improve` must not be able to call a non-compiling answer correct.

Benchmark run #4 (2026-08-13) is the reason this module exists: both arms
submitted a query SQLite refuses to prepare, the reviewer read it and said it
was fine, and Delegator returned the broken draft unchanged after eleven
seconds. Every test here is either that failure or the false positives that
would make the cure worse than the disease.
"""

from __future__ import annotations

import json

from delegator_core import draft_check


TASK_WITH_SCHEMA = (
    "Таблица SQLite: logins(user_id INTEGER, day INTEGER) — день это порядковый номер дня. "
    "Напиши ОДИН SQL-запрос, который для каждого пользователя возвращает длину самой длинной "
    "серии подряд идущих дней. Ответ — только запрос в блоке ```sql."
)

RUN_4_QUERY = """```sql
SELECT user_id, MAX(cnt) AS streak
FROM (
    SELECT user_id,
           day - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day) AS grp,
           COUNT(*) AS cnt
    FROM logins
    GROUP BY user_id, day - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day)
) t
GROUP BY user_id
ORDER BY user_id;
```"""

WORKING_QUERY = """```sql
SELECT user_id, MAX(cnt) AS streak FROM (
  SELECT user_id, COUNT(*) AS cnt FROM (
    SELECT user_id, day - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day) AS grp
    FROM logins
  ) GROUP BY user_id, grp
) GROUP BY user_id ORDER BY user_id
```"""


def test_the_query_that_fooled_the_reviewer_is_caught():
    result = draft_check.check_draft(TASK_WITH_SCHEMA, RUN_4_QUERY)
    assert result["schemaTables"] == 1, "схема должна извлекаться из текста задачи"
    assert result["defects"], "запрос не выполняется — это должно быть найдено"
    assert "misuse of window function" in result["defects"][0]


def test_a_working_query_produces_no_defect():
    assert draft_check.check_draft(TASK_WITH_SCHEMA, WORKING_QUERY)["defects"] == []


def test_sql_is_not_judged_without_a_schema():
    """Without the schema SQLite stops at «no such table» long before it looks
    at the query, so any verdict here would be noise."""
    result = draft_check.check_draft("Напиши запрос к таблице заказов.", RUN_4_QUERY)
    assert result["schemaTables"] == 0
    assert result["defects"] == []


def test_a_schema_we_reconstructed_wrongly_stays_silent():
    """`no such column` means our guess at the schema was wrong, not that the
    draft is wrong. A false defect turns a correct answer into a rewrite."""
    task = "Таблица SQLite: logins(user_id INTEGER)"
    draft = "```sql\nSELECT user_id, day FROM logins\n```"
    assert draft_check.check_draft(task, draft)["defects"] == []


def test_create_table_in_the_prompt_wins_over_prose():
    task = "CREATE TABLE t (a INTEGER, b TEXT);"
    assert draft_check.schema_from_text(task) == ["CREATE TABLE t (a INTEGER, b TEXT)"]


def test_a_function_signature_is_not_mistaken_for_a_table():
    assert draft_check.schema_from_text("Напиши функцию foo(a, b), которая складывает.") == []
    assert draft_check.schema_from_text("chunk(items, size) делит список") == []


def test_broken_python_is_caught_with_its_line():
    result = draft_check.check_draft("задача", "```python\ndef f(x)\n    return x\n```")
    assert result["checkedPython"] == 1
    assert "не компилируется" in result["defects"][0]
    assert "строка 1" in result["defects"][0]


def test_valid_python_produces_no_defect():
    assert draft_check.check_draft("задача", "```python\ndef f(x):\n    return x * 2\n```")["defects"] == []


def test_an_indented_or_elided_snippet_is_never_blamed():
    """Models answer with fragments all the time («в вашем обработчике: …»).
    Reporting a SyntaxError there would make `improve` rewrite correct answers."""
    for fragment in (
        "```python\n    result = do_thing()\n    ...\n```",
        "```python\nreturn value + 1\n```",
        "```python\nfor row in rows:\n    # ...\n```",
    ):
        assert draft_check.check_draft("задача", fragment)["defects"] == [], fragment


def test_a_fence_without_a_language_is_judged_only_when_it_looks_like_python():
    assert draft_check.check_draft("задача", "```\ndef f(x)\n    return x\n```")["defects"]
    assert draft_check.check_draft("задача", "```\nsome plain output\n```")["defects"] == []


def test_answers_without_code_are_left_alone():
    result = draft_check.check_draft("задача", "Просто текстовый ответ без кода.")
    assert result == {"defects": [], "checkedPython": 0, "checkedSql": 0, "schemaTables": 0}


def test_the_cli_writes_json_and_never_raises(tmp_path):
    task = tmp_path / "task.txt"
    draft = tmp_path / "draft.txt"
    result = tmp_path / "out.json"
    task.write_text(TASK_WITH_SCHEMA, encoding="utf-8")
    draft.write_text(RUN_4_QUERY, encoding="utf-8")

    assert draft_check.run_cli(str(task), str(draft), str(result)) == 0
    payload = json.loads(result.read_text(encoding="utf-8"))
    assert payload["defects"]

    # Missing inputs are not an error: a linter must never fail a delegation.
    missing = tmp_path / "missing.json"
    assert draft_check.run_cli(str(tmp_path / "nope.txt"), str(tmp_path / "nope2.txt"), str(missing)) == 0
    assert json.loads(missing.read_text(encoding="utf-8"))["defects"] == []


def test_the_cli_guard_only_fires_on_its_own_flag(tmp_path):
    assert not draft_check.maybe_run_as_linter(["run_server.py"])
    assert not draft_check.maybe_run_as_linter(["run_server.py", "--benchmark-exec", "a", "b"])
    out = tmp_path / "r.json"
    assert draft_check.maybe_run_as_linter(
        ["run_server.py", "--lint-draft", str(tmp_path / "a"), str(tmp_path / "b"), str(out)]
    )
    assert out.exists()


def test_at_most_five_defects_are_reported():
    draft = "\n".join("```python\ndef f%d(x)\n    return x\n```" % index for index in range(9))
    assert len(draft_check.check_draft("задача", draft)["defects"]) <= 5


# ── run #8: a perfect answer rewritten into eleven NameErrors ───────────────

SPLIT_REWRITE = """```python
def validate_order(order):
    return sorted(['x']) if re.fullmatch(r'[A-Z]{2}', order['country']) else []
```

```python
import re
```

Put the `import re` at the top of the module."""


def test_an_unbound_name_is_a_defect_even_though_it_compiles():
    """`compile()` cannot see it: an unbound name is a runtime error. Run #8
    turned a 13/13 answer into 2/13 exactly this way."""
    broken = "```python\ndef f(x):\n    return re.fullmatch('a', x)\n```"
    defects = draft_check.check_draft("задача", broken)["defects"]
    assert defects and "`re`" in defects[0]


def test_imports_may_live_in_another_block():
    """All the Python of an answer is judged together — the import being in a
    second block does not make the code wrong, only badly presented."""
    assert draft_check.check_draft("задача", SPLIT_REWRITE)["defects"] == []


def test_ordinary_python_never_trips_the_name_check():
    for source in (
        "import os\nclass A:\n    def m(self, n):\n        return [i for i in range(n) if os.sep]\n",
        "def f(v):\n    try:\n        if (w := v):\n            return w\n    except ValueError as err:\n        return err\n",
        "import functools\n@functools.cache\ndef g(a):\n    return (lambda b: b + a)(1)\n",
        "from math import *\ndef f(x):\n    return sqrt(x)\n",
    ):
        assert draft_check.undefined_names(source) == [], source


def test_a_rewrite_split_across_blocks_is_rejected():
    """`improve` feeds its output back as THE answer. One that needs the reader
    to move an import by hand is not an answer — and nothing checked the
    rewrite at all before run #8."""
    draft = "```python\nimport re\ndef validate_order(order):\n    return []\n```"
    reasons = draft_check.rewrite_defects("задача", draft, SPLIT_REWRITE)
    assert reasons and "самодостаточен" in reasons[0]


def test_a_healthy_rewrite_is_not_rejected():
    draft = "```python\ndef f(x):\n    return x\n```"
    better = "```python\ndef f(x):\n    return x * 2\n```"
    assert draft_check.rewrite_defects("задача", draft, better) == []


def test_a_rewrite_is_only_blamed_for_defects_it_introduced():
    """A draft that was already broken must not make every rewrite look guilty."""
    broken = "```python\ndef f(x)\n    return x\n```"
    assert draft_check.rewrite_defects("задача", broken, broken) == []

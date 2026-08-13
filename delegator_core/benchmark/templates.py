"""Task templates for the public benchmark.

Every template is a function `build(rng) -> Task`. It returns the text the model
sees plus a mechanical checker for it — no model ever judges an answer.

Two kinds of checker:

* ``python`` — the candidate's code is executed and compared against a REFERENCE
  implementation on generated inputs. Randomising the inputs is therefore free:
  the expected values are computed, never hard-coded, so a task can be new on
  every run without anyone maintaining answer keys.
* ``sqlite`` — the candidate's SELECT runs against a generated fixture and its
  rows are compared with the rows of a reference query.

Levels weigh the score: fast = 1, normal = 2, deep = 3.
"""

from __future__ import annotations

import random
import sqlite3
from dataclasses import dataclass, field
from typing import Callable

LEVEL_POINTS = {"fast": 1, "normal": 2, "deep": 3}


@dataclass
class Task:
    template_id: str
    level: str
    category: str
    title: str
    text: str
    checker: dict
    points: int = 0

    def __post_init__(self) -> None:
        self.points = LEVEL_POINTS[self.level]


def check(
    id: str, title: str, code: str = "", cases: list | None = None, weight: int = 1
) -> dict:
    """One NAMED constraint of a task, graded on its own.

    Partial credit is the point. A task with ten checkable constraints that
    scores 3 or 0 throws away almost all of its signal — that is why three live
    runs in a row read as a tie while the answers plainly differed. Each check
    is run in isolation (its own function, its own try/except), so one failure
    never hides the constraints that came after it.

    `code` is executed as the body of a function; `cases` are argument tuples
    compared against the reference implementation. A check may carry both.
    """
    return {
        "id": id,
        "title": title,
        "code": code,
        "cases": list(cases or []),
        "weight": weight,
    }


def default_checks(entry: str, cases: list, extra: str = "") -> list[dict]:
    """The constraint list a plain property-check task gets for free.

    One check for the entry point itself (a model that names the function wrong
    is a different failure from one that gets the logic wrong, and the report
    should say which), one per generated case, one for the extra assertions.
    """
    checks: list[dict] = []
    if entry:
        # Weight 0 on purpose: this is a GATE, not a constraint. It exists so the
        # report can say "функция не определена" instead of listing every case as
        # failed, but a model must not collect points for naming a function.
        checks.append(
            check(
                "contract",
                "функция %s определена" % entry,
                code="assert callable(%s), 'нет функции %s'" % (entry, entry),
                weight=0,
            )
        )
    for number, args in enumerate(cases or [], start=1):
        label = repr(args)
        if len(label) > 60:
            label = label[:57] + "…"
        checks.append(check("case-%d" % number, "вход %s" % label, cases=[args]))
    if (extra or "").strip():
        checks.append(check("extra", "дополнительные требования", code=extra))
    return checks


def _py(
    reference: str,
    entry: str,
    cases: list,
    extra: str = "",
    solution: str = "",
    checks: list[dict] | None = None,
) -> dict:
    """Property check: candidate(entry) must agree with the reference on `cases`.

    `solution` is a KNOWN-GOOD answer, used by the test suite to prove that the
    checker itself accepts a correct solution — a grader nobody can satisfy
    would quietly measure the benchmark instead of the models. It defaults to
    the reference with its private name renamed to the entry point.

    `checks` overrides the derived constraint list when a template can name its
    constraints better than "case 3" — see `_t_lru_cache`.
    """
    return {
        "kind": "python",
        "reference": reference,
        "entry": entry,
        "cases": cases,
        "extra": extra,
        "checks": checks if checks is not None else default_checks(entry, cases, extra),
        "solution": solution or reference.replace("_dg_ref", entry),
    }


# The sqlite harness (engine._sqlite_script) publishes `_dg_rows` (None when the
# query itself blew up), `_dg_expect` and `_dg_error` before running these.
def _sql(setup: str, expect: list, solution: str) -> dict:
    """A SQL answer is graded on a ladder, not all-or-nothing.

    "Runs at all", "right shape", "right rows", "right order" are four different
    failures with four different fixes, and a query that returns the correct set
    in the wrong order is plainly closer than one that does not parse.
    """
    return {
        "kind": "sqlite",
        "setup": setup,
        "expect": expect,
        "solution": solution,
        "checks": [
            # Weight 0: "it parses" is a gate, exactly like `contract` above.
            # `SELECT 1` runs, and must not be worth a quarter of the task.
            check(
                "runs",
                "запрос выполняется",
                code="assert _dg_rows is not None, _dg_error or 'запрос не выполнился'",
                weight=0,
            ),
            check(
                "shape",
                "верное число строк и столбцов",
                code=(
                    "assert _dg_rows is not None, _dg_error or 'запрос не выполнился'\n"
                    "assert len(_dg_rows) == len(_dg_expect), "
                    "'строк %d, ожидалось %d' % (len(_dg_rows), len(_dg_expect))\n"
                    "assert all(len(got) == len(exp) for got, exp in zip(_dg_rows, _dg_expect)), "
                    "'иное число столбцов'\n"
                ),
            ),
            check(
                "rows",
                "верный набор строк",
                code=(
                    "assert _dg_rows is not None, _dg_error or 'запрос не выполнился'\n"
                    "assert sorted(map(repr, _dg_rows)) == sorted(map(repr, _dg_expect)), "
                    "'набор строк не совпал: получено %r' % (_dg_rows,)\n"
                ),
            ),
            check(
                "order",
                "верный порядок строк",
                code=(
                    "assert _dg_rows is not None, _dg_error or 'запрос не выполнился'\n"
                    "assert _dg_rows == _dg_expect, 'получено %r' % (_dg_rows,)\n"
                ),
            ),
        ],
    }


# ── fast ────────────────────────────────────────────────────────────────────


def _t_unique_ordered(rng: random.Random) -> Task:
    pool = rng.sample(range(1, 30), 6)
    data = [rng.choice(pool) for _ in range(rng.randint(8, 14))]
    words = rng.sample(["alfa", "bravo", "charlie", "delta", "echo"], 4)
    return Task(
        "unique-ordered", "fast", "code",
        "Список без повторов",
        "Напиши функцию на Python `unique_ordered(items)`, которая возвращает список уникальных "
        "элементов, сохраняя порядок их первого появления. Исходный список изменять нельзя, "
        "элементы любые хешируемые.",
        _py(
            "def _dg_ref(items):\n"
            "    seen = set()\n"
            "    out = []\n"
            "    for item in items:\n"
            "        if item not in seen:\n"
            "            seen.add(item)\n"
            "            out.append(item)\n"
            "    return out\n",
            "unique_ordered",
            [[data], [[]], [words + words[:2]], [[7]]],
            "src = %r\nunique_ordered(src)\nassert src == %r, 'исходный список изменён'\n" % (data, data),
        ),
    )


def _t_chunk(rng: random.Random) -> Task:
    size = rng.randint(2, 4)
    data = list(range(1, rng.randint(6, 12)))
    return Task(
        "chunk", "fast", "code",
        "Нарезка списка",
        "Напиши функцию на Python `chunk(items, size)`, которая делит список на подсписки длиной "
        "size; последний кусок может быть короче. При size <= 0 возбуди ValueError.",
        _py(
            "def _dg_ref(items, size):\n"
            "    if size <= 0:\n"
            "        raise ValueError('size')\n"
            "    return [list(items[i:i + size]) for i in range(0, len(items), size)]\n",
            "chunk",
            [[data, size], [[], 3], [[1, 2, 3], 5], [list(range(10)), 1]],
            "try:\n    chunk([1], 0)\n    raise AssertionError('нет ValueError при size <= 0')\nexcept ValueError:\n    pass\n",
        ),
    )


def _t_safe_div(rng: random.Random) -> Task:
    a, b = rng.randint(1, 99), rng.randint(1, 9)
    return Task(
        "safe-div", "fast", "code",
        "Деление без исключения",
        "Напиши функцию на Python `safe_div(a, b)`: возвращает частное a/b, а при делении на ноль "
        "возвращает None. Целочисленное деление не используем.",
        _py(
            "def _dg_ref(a, b):\n"
            "    if b == 0:\n"
            "        return None\n"
            "    return a / b\n",
            "safe_div",
            [[a, b], [a, 0], [0, b], [-a, b], [7, 2]],
        ),
    )


def _t_flatten_once(rng: random.Random) -> Task:
    data = [rng.randint(1, 9), [rng.randint(1, 9), rng.randint(1, 9)], (rng.randint(1, 9),), "ab"]
    return Task(
        "flatten-once", "fast", "code",
        "Разворот на один уровень",
        "Напиши функцию на Python `flatten_once(items)`, которая разворачивает вложенность ровно "
        "на один уровень: списки и кортежи раскрываются, строки и числа остаются как есть.",
        _py(
            "def _dg_ref(items):\n"
            "    out = []\n"
            "    for item in items:\n"
            "        if isinstance(item, (list, tuple)):\n"
            "            out.extend(item)\n"
            "        else:\n"
            "            out.append(item)\n"
            "    return out\n",
            "flatten_once",
            [[data], [[]], [[[1, [2]]]], [["ab", "cd"]]],
        ),
    )


def _t_roman(rng: random.Random) -> Task:
    numbers = rng.sample(range(1, 3999), 6) + [4, 9, 40, 1994]
    return Task(
        "roman", "fast", "code",
        "Римские числа",
        "Напиши функцию на Python `roman_to_int(s)`, которая переводит римское число в целое. "
        "Поддержи вычитательную форму (IV, IX, XL, XC, CD, CM).",
        _py(
            "_DG_MAP = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000}\n"
            "def _dg_ref(s):\n"
            "    total = 0\n"
            "    prev = 0\n"
            "    for ch in reversed(s):\n"
            "        value = _DG_MAP[ch]\n"
            "        if value < prev:\n"
            "            total -= value\n"
            "        else:\n"
            "            total += value\n"
            "            prev = value\n"
            "    return total\n",
            "roman_to_int",
            [[_int_to_roman(n)] for n in numbers],
        ),
    )


def _int_to_roman(value: int) -> str:
    table = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
        (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]
    out = []
    for number, letters in table:
        while value >= number:
            out.append(letters)
            value -= number
    return "".join(out)


# ── normal ──────────────────────────────────────────────────────────────────


def _t_top_words(rng: random.Random) -> Task:
    words = ["kappa", "lambda", "sigma", "omega", "delta"]
    text = " ".join(rng.choice(words) for _ in range(rng.randint(10, 20)))
    k = rng.randint(2, 3)
    return Task(
        "top-words", "normal", "code",
        "Частые слова",
        "Напиши функцию на Python `top_words(text, k)`, которая возвращает k самых частых слов "
        "списком кортежей (слово, количество). Регистр не учитывается, слова разделяются "
        "пробелами и знаками препинания. При равной частоте слова идут по алфавиту.",
        _py(
            "import re\n"
            "from collections import Counter\n"
            "def _dg_ref(text, k):\n"
            "    words = re.findall(r'[0-9a-zA-Zа-яА-ЯёЁ]+', text.lower())\n"
            "    counts = Counter(words)\n"
            "    ordered = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))\n"
            "    return ordered[:k]\n",
            "top_words",
            [[text, k], ["a b a, B c! c a", 2], ["x y", 2], ["", 3]],
        ),
    )


def _t_natural_sort(rng: random.Random) -> Task:
    stem = rng.choice(["file", "img", "part", "log"])
    items = ["%s%d.txt" % (stem, n) for n in rng.sample(range(1, 40), 6)]
    return Task(
        "natural-sort", "normal", "code",
        "Человеческая сортировка",
        "Напиши функцию на Python `natural_sorted(items)`, которая сортирует строки "
        "«по-человечески»: числа внутри строк сравниваются как числа, а не посимвольно. "
        "Регистр букв на порядок не влияет, но строки возвращаются без изменений.",
        _py(
            "import re\n"
            "def _dg_key(text):\n"
            "    parts = re.split(r'(\\d+)', text.lower())\n"
            "    return [int(p) if p.isdigit() else p for p in parts]\n"
            "def _dg_ref(items):\n"
            "    return sorted(items, key=_dg_key)\n",
            "natural_sorted",
            [[items], [["a10", "a2", "a1"]], [["File1.txt", "file3.txt", "file20.txt"]], [[]]],
        ),
    )


def _t_split_amount(rng: random.Random) -> Task:
    total = rng.randint(50, 5000)
    parts = rng.randint(3, 7)
    return Task(
        "split-amount", "normal", "code",
        "Деление суммы без потерь",
        "Напиши функцию на Python `split_amount(total, parts)`, которая делит сумму в копейках на "
        "parts частей: сумма частей равна total ровно, части отличаются не более чем на копейку, "
        "лишние копейки достаются первым частям. При parts <= 0 или отрицательном total — ValueError.",
        _py(
            "def _dg_ref(total, parts):\n"
            "    if parts <= 0 or total < 0:\n"
            "        raise ValueError('bad input')\n"
            "    base, extra = divmod(total, parts)\n"
            "    return [base + (1 if i < extra else 0) for i in range(parts)]\n",
            "split_amount",
            [[total, parts], [100, 3], [0, 3], [101, 4], [10, 2]],
            "for bad in [(10, 0), (-1, 2)]:\n"
            "    try:\n"
            "        split_amount(*bad)\n"
            "        raise AssertionError('нет ValueError для %r' % (bad,))\n"
            "    except ValueError:\n"
            "        pass\n",
        ),
    )


def _t_retry_delays(rng: random.Random) -> Task:
    attempts = rng.randint(5, 8)
    base = rng.choice([0.5, 1.0, 2.0])
    cap = rng.choice([10.0, 30.0, 60.0])
    return Task(
        "retry-backoff", "normal", "code",
        "Экспоненциальная выдержка",
        "Напиши функцию на Python `retry_delays(attempts, base=1.0, cap=30.0)`, которая возвращает "
        "список задержек: первая равна base, каждая следующая вдвое больше, но ни одна не "
        "превышает cap. Длина списка равна attempts, при отрицательном attempts — ValueError.",
        _py(
            "def _dg_ref(attempts, base=1.0, cap=30.0):\n"
            "    if attempts < 0:\n"
            "        raise ValueError('attempts')\n"
            "    return [min(cap, base * (2 ** i)) for i in range(attempts)]\n",
            "retry_delays",
            [[attempts, base, cap], [5], [0], [3, 0.5, 1.0]],
            "try:\n    retry_delays(-1)\n    raise AssertionError('нет ValueError')\nexcept ValueError:\n    pass\n",
        ),
    )


def _t_window_max(rng: random.Random) -> Task:
    data = [rng.randint(-20, 20) for _ in range(rng.randint(8, 14))]
    k = rng.randint(2, 4)
    return Task(
        "window-max", "normal", "code",
        "Максимум в окне",
        "Напиши функцию на Python `window_max(nums, k)`, которая возвращает максимумы в каждом "
        "окне длины k, скользящем слева направо. При k <= 0 возбуди ValueError; если список пуст "
        "или k больше длины списка — верни пустой список.",
        _py(
            "def _dg_ref(nums, k):\n"
            "    if k <= 0:\n"
            "        raise ValueError('k')\n"
            "    if not nums or k > len(nums):\n"
            "        return []\n"
            "    return [max(nums[i:i + k]) for i in range(len(nums) - k + 1)]\n",
            "window_max",
            [[data, k], [[1, 3, -1, -3, 5, 3, 6, 7], 3], [[], 3], [[1, 2], 5], [[4], 1]],
            "try:\n    window_max([1, 2], 0)\n    raise AssertionError('нет ValueError')\nexcept ValueError:\n    pass\n",
        ),
    )


def _t_first_repeating(rng: random.Random) -> Task:
    pool = rng.sample(range(1, 20), 5)
    data = [rng.choice(pool) for _ in range(rng.randint(6, 12))]
    return Task(
        "first-repeating", "normal", "code",
        "Первый повтор",
        "Напиши функцию на Python `first_repeating(items)`, которая возвращает первый элемент, "
        "встречающийся более одного раза, в порядке ПЕРВОГО появления, а не второго. Если "
        "повторов нет — None. Исходный список не меняется.",
        _py(
            "def _dg_ref(items):\n"
            "    from collections import Counter\n"
            "    counts = Counter(items)\n"
            "    for item in items:\n"
            "        if counts[item] > 1:\n"
            "            return item\n"
            "    return None\n",
            "first_repeating",
            # Only ONE case may legitimately answer None: two of them let an
            # answer that always returns None collect a third of the points.
            [[data], [[2, 5, 1, 2, 3, 5, 1, 2, 4]], [["b", "a", "a", "b"]],
             [[9, 9]], [[4, 1, 2, 3, 1]], [[1, 2, 3]], [[]]],
        ),
    )


# ── deep ────────────────────────────────────────────────────────────────────


def _t_find_semver(rng: random.Random) -> Task:
    major, minor, patch = rng.randint(0, 12), rng.randint(0, 20), rng.randint(0, 30)
    good = "%d.%d.%d" % (major, minor, patch)
    text = "release %s ready, build %d.%d, hash %d.%d.%d.%d" % (
        good, rng.randint(1, 9), rng.randint(1, 9),
        rng.randint(1, 9), rng.randint(1, 9), rng.randint(1, 9), rng.randint(1, 9),
    )
    return Task(
        "find-semver", "deep", "code",
        "Границы версий",
        "Напиши функцию на Python `find_semver(text)`, которая возвращает список версий вида "
        "МАЖОР.МИНОР.ПАТЧ, найденных в тексте, с необязательным суффиксом предрелиза через дефис "
        "(1.2.3-beta.1). Числа с другим количеством частей версией НЕ считаются: ни 1.2, ни "
        "1.2.3.4 попадать в результат не должны — в том числе как часть более длинного числа.",
        _py(
            "import re\n"
            "_DG_RE = re.compile(r'(?<![.\\d])(\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?)(?![.\\d])')\n"
            "def _dg_ref(text):\n"
            "    return _DG_RE.findall(text)\n",
            "find_semver",
            [[text], ["v1.2.3 and 10.0.1-beta.1 end"], ["1.2 or 1.2.3.4"], [""], ["0.0.1"]],
        ),
    )


def _t_topo_sort(rng: random.Random) -> Task:
    names = rng.sample(["app", "lib", "util", "core", "cli", "api"], 4)
    graph = {names[0]: [names[1], names[2]], names[1]: [names[2]], names[2]: [], names[3]: [names[2]]}
    return Task(
        "topo-sort", "normal", "code",
        "Порядок сборки",
        "Напиши функцию на Python `topo_sort(graph)`: graph — словарь «узел → список его "
        "зависимостей». Верни список узлов, где зависимости идут раньше зависящих. Если "
        "вариантов несколько — выбирай узел, который меньше по алфавиту. При цикле возбуди ValueError.",
        _py(
            "def _dg_ref(graph):\n"
            "    result = []\n"
            "    state = {}\n"
            "    def visit(node):\n"
            "        if state.get(node) == 2:\n"
            "            return\n"
            "        if state.get(node) == 1:\n"
            "            raise ValueError('cycle')\n"
            "        state[node] = 1\n"
            "        for dep in sorted(graph.get(node, [])):\n"
            "            visit(dep)\n"
            "        state[node] = 2\n"
            "        result.append(node)\n"
            "    for node in sorted(graph):\n"
            "        visit(node)\n"
            "    return result\n",
            "topo_sort",
            [[graph], [{"app": ["lib", "util"], "lib": ["util"], "util": []}], [{"b": [], "a": []}], [{}]],
            "try:\n    topo_sort({'a': ['b'], 'b': ['a']})\n    raise AssertionError('нет ValueError на цикле')\nexcept ValueError:\n    pass\n",
        ),
    )


def _t_insert_index(rng: random.Random) -> Task:
    values = sorted(rng.choice(range(1, 12)) for _ in range(rng.randint(6, 12)))
    probe = rng.choice(values)
    return Task(
        "insert-index", "normal", "code",
        "Правая граница вставки",
        "Напиши функцию на Python `insert_index(values, value)`: values отсортирован по "
        "возрастанию, верни индекс, куда вставить value, чтобы порядок сохранился, причём ПОСЛЕ "
        "всех равных элементов. Сложность логарифмическая, модуль bisect использовать нельзя.",
        _py(
            "def _dg_ref(values, value):\n"
            "    lo, hi = 0, len(values)\n"
            "    while lo < hi:\n"
            "        mid = (lo + hi) // 2\n"
            "        if values[mid] <= value:\n"
            "            lo = mid + 1\n"
            "        else:\n"
            "            hi = mid\n"
            "    return lo\n",
            "insert_index",
            [[values, probe], [[1, 2, 2, 2, 3], 2], [[], 5], [[1, 3], 0], [[1, 3], 4]],
            "_dg_banned = 'bi' + 'sect'\n"
            "_dg_src = open(__file__, encoding='utf-8').read()\n"
            "assert _dg_banned not in _dg_src, 'использован запрещённый модуль'\n",
        ),
    )


def _t_lru_cache(rng: random.Random) -> Task:
    capacity = rng.randint(2, 3)
    return Task(
        "lru-cache", "normal", "code",
        "Кэш с вытеснением",
        "Напиши на Python класс `LRUCache` с конструктором `LRUCache(capacity)` и методами "
        "`get(key)` и `put(key, value)`. get возвращает значение или -1. И get, и put считаются "
        "обращением к ключу. При переполнении вытесняется тот, к кому обращались дольше всего. "
        "Обе операции — O(1).",
        {
            "kind": "python",
            "reference": "",
            "entry": "",
            "cases": [],
            # Explicit: this template has no reference implementation to rename,
            # and the test suite proves the checker accepts a correct answer.
            "solution": (
                "from collections import OrderedDict\n"
                "class LRUCache:\n"
                "    def __init__(self, capacity):\n"
                "        self.capacity = capacity\n"
                "        self.data = OrderedDict()\n"
                "    def get(self, key):\n"
                "        if key not in self.data:\n"
                "            return -1\n"
                "        self.data.move_to_end(key)\n"
                "        return self.data[key]\n"
                "    def put(self, key, value):\n"
                "        if key in self.data:\n"
                "            self.data.move_to_end(key)\n"
                "        self.data[key] = value\n"
                "        if len(self.data) > self.capacity:\n"
                "            self.data.popitem(last=False)\n"
            ),
            # Named by hand: this template has no generated cases, so the
            # derived "case-N" list would collapse into a single all-or-nothing
            # check and the task would keep scoring 2 or 0.
            "checks": [
                check(
                    "contract",
                    "класс LRUCache с get/put",
                    code=(
                        "c = LRUCache(2)\n"
                        "assert c.get(1) == -1, 'пустой кэш должен возвращать -1'\n"
                        "c.put(1, 1)\n"
                        "assert c.get(1) == 1\n"
                    ),
                ),
                check(
                    "evicts-lru",
                    "вытесняется давний ключ, а не первый",
                    code=(
                        "c = LRUCache(2)\n"
                        "c.put(1, 1)\n"
                        "c.put(2, 2)\n"
                        "assert c.get(1) == 1\n"
                        "c.put(3, 3)\n"
                        "assert c.get(2) == -1, 'вытеснен не тот ключ'\n"
                        "assert c.get(1) == 1, 'вытеснен недавно использованный ключ'\n"
                    ),
                ),
                check(
                    "get-is-a-use",
                    "get тоже считается обращением",
                    code=(
                        "c = LRUCache(2)\n"
                        "c.put(1, 1)\n"
                        "c.put(2, 2)\n"
                        "c.get(1)\n"
                        "c.put(3, 3)\n"
                        "assert c.get(2) == -1, 'get не обновил порядок'\n"
                        "assert c.get(3) == 3\n"
                    ),
                ),
                check(
                    "update-existing",
                    "повторный put обновляет значение, а не добавляет ключ",
                    code=(
                        "c = LRUCache(1)\n"
                        "c.put(1, 1)\n"
                        "c.put(1, 2)\n"
                        "assert c.get(1) == 2\n"
                    ),
                ),
                check(
                    "capacity-limit",
                    "соблюдается заданная вместимость",
                    code=(
                        "c = LRUCache(%d)\n"
                        "for i in range(%d):\n"
                        "    c.put(i, i * 10)\n"
                        "assert c.get(0) == -1, 'вместимость превышена'\n"
                        "assert c.get(%d) == %d\n" % (capacity, capacity + 1, capacity, capacity * 10)
                    ),
                ),
            ],
        },
    )


def _t_normalize_key(rng: random.Random) -> Task:
    sample = rng.choice(["  Straße  ", "  GROSSE straße ", " Straße  Weg "])
    return Task(
        "normalize-key", "normal", "code",
        "Канонический ключ",
        "Напиши функцию на Python `normalize_key(text)`, которая приводит строку к каноническому "
        "ключу: регистр не важен для сравнения строк любых языков (немецкое ß должно совпадать с "
        "ss), последовательности пробельных символов схлопываются в один пробел, края обрезаются.",
        _py(
            "def _dg_ref(text):\n"
            "    return ' '.join(text.casefold().split())\n",
            "normalize_key",
            [[sample], ["  Straße  "], ["Hello   World"], ["ÄPFEL"], [""], ["a\tb\nc"]],
        ),
    )


def _t_dedup_by(rng: random.Random) -> Task:
    rows = [{"a": rng.randint(1, 3), "b": rng.randint(1, 3)} for _ in range(rng.randint(5, 9))]
    return Task(
        "dedup-by-keys", "normal", "code",
        "Дедупликация словарей",
        "Напиши функцию на Python `dedup_by(items, keys)`: items — список словарей, keys — список "
        "имён полей. Верни список без повторов по значениям этих полей, сохраняя порядок первого "
        "появления. Исходные данные изменять нельзя, порядок ключей внутри словаря значения не имеет.",
        _py(
            "def _dg_ref(items, keys):\n"
            "    seen = set()\n"
            "    out = []\n"
            "    for item in items:\n"
            "        marker = tuple(item.get(k) for k in keys)\n"
            "        if marker in seen:\n"
            "            continue\n"
            "        seen.add(marker)\n"
            "        out.append(dict(item))\n"
            "    return out\n",
            "dedup_by",
            [[rows, ["a"]], [rows, ["a", "b"]], [[], ["a"]],
             [[{"a": 1, "b": 1}, {"b": 1, "a": 1}], ["a", "b"]]],
            "src = %r\ndedup_by(src, ['a'])\nassert src == %r, 'исходные данные изменены'\n" % (rows, rows),
        ),
    )


def _t_sql_top_n(rng: random.Random) -> Task:
    rows = []
    order_id = 1
    for customer in rng.sample(range(10, 60), 3):
        for _ in range(rng.randint(2, 4)):
            rows.append((order_id, customer, rng.choice([100, 300, 300, 500, 900, 900])))
            order_id += 1
    values = ",".join("(%d,%d,%d)" % row for row in rows)
    setup = (
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER);"
        "INSERT INTO orders VALUES %s;" % values
    )
    reference = (
        "SELECT customer_id, id, amount FROM ("
        "  SELECT customer_id, id, amount,"
        "         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY amount DESC, id ASC) AS rn"
        "  FROM orders) WHERE rn <= 2 ORDER BY customer_id, amount DESC, id"
    )
    return Task(
        "sql-top-n", "deep", "sql",
        "Топ-2 заказа на клиента",
        "Таблица SQLite: orders(id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER). "
        "Напиши ОДИН SQL-запрос, который для каждого клиента возвращает два самых крупных заказа: "
        "столбцы customer_id, id, amount. При равных суммах раньше идёт заказ с меньшим id. "
        "Сортировка: по customer_id, затем по amount по убыванию, затем по id. "
        "Ответ — только запрос в блоке ```sql.",
        _sql(setup, _sqlite_rows(setup, reference), reference),
    )


def _t_sql_dup_emails(rng: random.Random) -> Task:
    names = rng.sample(["ann", "bob", "carl", "dina", "egor", "fred"], 4)
    rows = []
    user_id = 1
    for name in names:
        for _ in range(rng.randint(1, 3)):
            spelling = rng.choice([name, name.upper(), name.capitalize()])
            rows.append((user_id, "%s@example.com" % spelling))
            user_id += 1
    values = ",".join("(%d,'%s')" % row for row in rows)
    setup = (
        "CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT);"
        "INSERT INTO users VALUES %s;" % values
    )
    reference = (
        "SELECT lower(email) AS email, COUNT(*) AS cnt FROM users "
        "GROUP BY lower(email) HAVING COUNT(*) > 1 ORDER BY email"
    )
    return Task(
        "sql-dup-emails", "normal", "sql",
        "Дубли адресов",
        "Таблица SQLite: users(id INTEGER PRIMARY KEY, email TEXT). Напиши ОДИН SQL-запрос, "
        "который находит адреса, встречающиеся более одного раза без учёта регистра. Верни два "
        "столбца: адрес в нижнем регистре и количество. Сортировка по адресу. "
        "Ответ — только запрос в блоке ```sql.",
        _sql(setup, _sqlite_rows(setup, reference), reference),
    )


def _sqlite_rows(setup: str, query: str) -> list[list]:
    connection = sqlite3.connect(":memory:")
    try:
        connection.executescript(setup)
        return [list(row) for row in connection.execute(query)]
    finally:
        connection.close()


# ── normal ──────────────────────────────────────────────────────────────────


def _t_fold_ranges(rng: random.Random) -> Task:
    numbers = sorted(rng.sample(range(1, 40), rng.randint(6, 12)))
    return Task(
        "fold-ranges", "normal", "code",
        "Свёртка диапазонов",
        "Напиши функцию на Python `fold_ranges(numbers)`, которая сворачивает отсортированный "
        "список целых в строку диапазонов: подряд идущие числа записываются как «начало-конец», "
        "одиночные — как есть, части разделяются запятой. Для пустого списка верни пустую строку.",
        _py(
            "def _dg_ref(numbers):\n"
            "    parts = []\n"
            "    start = None\n"
            "    prev = None\n"
            "    for value in numbers:\n"
            "        if start is None:\n"
            "            start = prev = value\n"
            "            continue\n"
            "        if value == prev + 1:\n"
            "            prev = value\n"
            "            continue\n"
            "        parts.append(str(start) if start == prev else '%d-%d' % (start, prev))\n"
            "        start = prev = value\n"
            "    if start is not None:\n"
            "        parts.append(str(start) if start == prev else '%d-%d' % (start, prev))\n"
            "    return ','.join(parts)\n",
            "fold_ranges",
            [[numbers], [[]], [[1, 2, 3, 5, 7, 8]], [[4]], [[1, 3, 5]], [[1, 2]]],
        ),
    )


def _t_base_convert(rng: random.Random) -> Task:
    value = rng.randint(1000, 100000)
    base = rng.choice([2, 8, 16, 36])
    return Task(
        "base-convert", "normal", "code",
        "Перевод в систему счисления",
        "Напиши функцию на Python `to_base(value, base)`, которая переводит целое число в строку "
        "в системе счисления от 2 до 36; цифры больше 9 обозначаются строчными латинскими буквами. "
        "Ноль — это \"0\", отрицательные числа начинаются со знака минус. При base вне 2..36 "
        "возбуди ValueError.",
        _py(
            "_DG_DIGITS = '0123456789abcdefghijklmnopqrstuvwxyz'\n"
            "def _dg_ref(value, base):\n"
            "    if base < 2 or base > 36:\n"
            "        raise ValueError('base')\n"
            "    if value == 0:\n"
            "        return '0'\n"
            "    sign = '-' if value < 0 else ''\n"
            "    rest = abs(value)\n"
            "    out = []\n"
            "    while rest:\n"
            "        rest, digit = divmod(rest, base)\n"
            "        out.append(_DG_DIGITS[digit])\n"
            "    return sign + ''.join(reversed(out))\n",
            "to_base",
            [[value, base], [0, 2], [255, 16], [-42, 2], [35, 36], [1, 10]],
            "for bad in [(5, 1), (5, 37)]:\n"
            "    try:\n"
            "        to_base(*bad)\n"
            "        raise AssertionError('нет ValueError для %r' % (bad,))\n"
            "    except ValueError:\n"
            "        pass\n",
        ),
    )


def _t_parse_ini(rng: random.Random) -> Task:
    section = rng.choice(["core", "proxy", "models"])
    text = (
        "; комментарий\n[%s]\nname = value\n\n# ещё комментарий\nurl=http://host:8080/a=b\n"
        "name = second\n[empty]\n" % section
    )
    return Task(
        "parse-ini", "normal", "code",
        "Разбор INI",
        "Напиши функцию на Python `parse_ini(text)`, которая разбирает INI-текст в словарь "
        "«секция → словарь ключ-значение». Строки, начинающиеся с ; или #, и пустые строки "
        "игнорируются; пробелы вокруг ключа и значения обрезаются; знак = внутри значения "
        "сохраняется; при повторе ключа побеждает последний; пустая секция даёт пустой словарь. "
        "Ключи до первой секции игнорируются.",
        _py(
            "def _dg_ref(text):\n"
            "    out = {}\n"
            "    current = None\n"
            "    for raw in text.splitlines():\n"
            "        line = raw.strip()\n"
            "        if not line or line[0] in ';#':\n"
            "            continue\n"
            "        if line.startswith('[') and line.endswith(']'):\n"
            "            current = line[1:-1].strip()\n"
            "            out.setdefault(current, {})\n"
            "            continue\n"
            "        if current is None or '=' not in line:\n"
            "            continue\n"
            "        key, _, value = line.partition('=')\n"
            "        out[current][key.strip()] = value.strip()\n"
            "    return out\n",
            "parse_ini",
            [[text], [""], ["[a]\nk=1\n"], ["k=1\n[a]\n"], ["[a]\nk = x = y\n"]],
        ),
    )


# ── deep ────────────────────────────────────────────────────────────────────


def _t_json_pointer(rng: random.Random) -> Task:
    doc = {
        "a": {"b": [10, {"c": rng.randint(1, 99)}]},
        "x/y": rng.randint(1, 99),
        "m~n": "tilde",
        "list": [1, 2, 3],
    }
    return Task(
        "json-pointer", "deep", "code",
        "JSON Pointer (RFC 6901)",
        "Напиши функцию на Python `json_pointer_get(doc, pointer)`, которая достаёт значение по "
        "указателю JSON Pointer. Пустая строка возвращает документ целиком. Указатель начинается "
        "с «/», иначе ValueError. В сегментах ~1 означает «/», а ~0 означает «~» (порядок замен "
        "важен). Для списков сегмент — это индекс из цифр. Если пути нет — возбуди KeyError.",
        _py(
            "def _dg_ref(doc, pointer):\n"
            "    if pointer == '':\n"
            "        return doc\n"
            "    if not pointer.startswith('/'):\n"
            "        raise ValueError('pointer')\n"
            "    node = doc\n"
            "    for raw in pointer.split('/')[1:]:\n"
            "        token = raw.replace('~1', '/').replace('~0', '~')\n"
            "        if isinstance(node, list):\n"
            "            if not token.isdigit() or int(token) >= len(node):\n"
            "                raise KeyError(token)\n"
            "            node = node[int(token)]\n"
            "        elif isinstance(node, dict):\n"
            "            if token not in node:\n"
            "                raise KeyError(token)\n"
            "            node = node[token]\n"
            "        else:\n"
            "            raise KeyError(token)\n"
            "    return node\n",
            "json_pointer_get",
            [[doc, ""], [doc, "/a/b/0"], [doc, "/a/b/1/c"], [doc, "/x~1y"], [doc, "/m~0n"], [doc, "/list/2"]],
            # %% escapes the format inside the GENERATED script; only %r below
            # belongs to this outer format.
            "_dg_doc = %r\n"
            "try:\n"
            "    json_pointer_get(_dg_doc, 'a')\n"
            "    raise AssertionError('нет ValueError для указателя без /')\n"
            "except ValueError:\n"
            "    pass\n"
            "for _dg_bad in ['/nope', '/list/9', '/a/b/x']:\n"
            "    try:\n"
            "        json_pointer_get(_dg_doc, _dg_bad)\n"
            "        raise AssertionError('нет KeyError для %%s' %% _dg_bad)\n"
            "    except KeyError:\n"
            "        pass\n" % (doc,),
        ),
    )


def _t_semver_compare(rng: random.Random) -> Task:
    major = rng.randint(1, 9)
    return Task(
        "semver-compare", "normal", "code",
        "Сравнение версий semver",
        "Напиши функцию на Python `semver_compare(a, b)`, которая сравнивает версии semver и "
        "возвращает -1, 0 или 1. Сначала сравниваются мажор, минор и патч как числа. Версия с "
        "предрелизом МЛАДШЕ такой же версии без него. Внутри предрелиза части разделяются точкой: "
        "чисто числовые части сравниваются как числа и всегда младше нечисловых, нечисловые "
        "сравниваются лексически, а при равном начале короче — значит младше.",
        _py(
            "def _dg_split(version):\n"
            "    core, _, pre = version.partition('-')\n"
            "    return [int(part) for part in core.split('.')], pre\n"
            "def _dg_ref(a, b):\n"
            "    a_core, a_pre = _dg_split(a)\n"
            "    b_core, b_pre = _dg_split(b)\n"
            "    if a_core != b_core:\n"
            "        return -1 if a_core < b_core else 1\n"
            "    if a_pre == b_pre:\n"
            "        return 0\n"
            "    if not a_pre:\n"
            "        return 1\n"
            "    if not b_pre:\n"
            "        return -1\n"
            "    a_parts = a_pre.split('.')\n"
            "    b_parts = b_pre.split('.')\n"
            "    for left, right in zip(a_parts, b_parts):\n"
            "        left_num, right_num = left.isdigit(), right.isdigit()\n"
            "        if left_num and right_num:\n"
            "            if int(left) != int(right):\n"
            "                return -1 if int(left) < int(right) else 1\n"
            "        elif left_num != right_num:\n"
            "            return -1 if left_num else 1\n"
            "        elif left != right:\n"
            "            return -1 if left < right else 1\n"
            "    if len(a_parts) == len(b_parts):\n"
            "        return 0\n"
            "    return -1 if len(a_parts) < len(b_parts) else 1\n",
            "semver_compare",
            [
                ["1.0.0-alpha", "1.0.0-alpha.1"],
                ["1.0.0-alpha.1", "1.0.0-alpha.beta"],
                ["1.0.0-alpha.beta", "1.0.0-beta"],
                ["1.0.0-beta.2", "1.0.0-beta.11"],
                ["1.0.0-rc.1", "1.0.0"],
                ["1.0.0", "1.0.0"],
                ["2.1.0", "2.0.9"],
                ["%d.0.0" % major, "%d.0.1" % major],
                ["1.0.0", "1.0.0-rc.1"],
            ],
        ),
    )


def _t_parse_csv_line(rng: random.Random) -> Task:
    value = rng.choice(["Москва, Россия", "a,b", "тест, ещё"])
    return Task(
        "parse-csv-line", "normal", "code",
        "Разбор строки CSV",
        "Напиши функцию на Python `parse_csv_line(line)`, которая разбивает ОДНУ строку CSV на "
        "список полей. Поле в двойных кавычках может содержать запятые, а удвоенная кавычка "
        "внутри такого поля означает одну кавычку. Кавычки вокруг поля в результат не попадают. "
        "Пустая строка даёт список из одной пустой строки.",
        _py(
            "import csv\n"
            "def _dg_ref(line):\n"
            "    if line == '':\n"
            "        return ['']\n"
            "    return next(csv.reader([line]))\n",
            "parse_csv_line",
            [
                ["a,b,c"],
                ['a,"%s",d' % value],
                ['"он сказал ""да""",x'],
                [""],
                ["a,,b"],
                ['"",x'],
            ],
        ),
    )


def _t_deep_merge(rng: random.Random) -> Task:
    base = {"a": {"x": rng.randint(1, 9), "y": [1, 2]}, "b": rng.randint(1, 9)}
    patch = {"a": {"y": [3], "z": rng.randint(1, 9)}, "c": {"deep": True}}
    return Task(
        "deep-merge", "deep", "code",
        "Слияние конфигураций",
        "Напиши функцию на Python `deep_merge(base, patch)`, которая рекурсивно сливает два "
        "словаря: значения из patch побеждают, вложенные словари сливаются на всех уровнях, а "
        "списки и прочие значения заменяются целиком. Ни base, ни patch изменять нельзя, "
        "результат не должен делить вложенные объекты с исходными.",
        _py(
            "import copy\n"
            "def _dg_ref(base, patch):\n"
            "    out = copy.deepcopy(base)\n"
            "    for key, value in patch.items():\n"
            "        if isinstance(value, dict) and isinstance(out.get(key), dict):\n"
            "            out[key] = _dg_ref(out[key], value)\n"
            "        else:\n"
            "            out[key] = copy.deepcopy(value)\n"
            "    return out\n",
            "deep_merge",
            [[base, patch], [{}, {"a": 1}], [{"a": 1}, {}], [{"a": {"b": 1}}, {"a": {"b": 2}}]],
            "_dg_base = %r\n"
            "_dg_patch = %r\n"
            "_dg_out = deep_merge(_dg_base, _dg_patch)\n"
            "assert _dg_base == %r and _dg_patch == %r, 'исходные словари изменены'\n"
            "_dg_out['a']['y'].append(99)\n"
            "assert _dg_base['a']['y'] == %r, 'результат делит вложенный список с base'\n"
            % (base, patch, base, patch, base["a"]["y"]),
        ),
    )


def _t_normalize_path(rng: random.Random) -> Task:
    head = rng.choice(["srv", "opt", "data"])
    return Task(
        "normalize-path", "deep", "code",
        "Нормализация пути",
        "Напиши функцию на Python `normalize_path(path)`, которая нормализует путь в стиле POSIX "
        "БЕЗ обращения к файловой системе: «.» отбрасывается, «..» убирает предыдущий сегмент, "
        "повторные слэши схлопываются. Абсолютный путь остаётся абсолютным; если «..» выводит "
        "выше корня — возбуди ValueError. В относительном пути ведущие «..» сохраняются. Пустой "
        "путь превращается в «.».",
        _py(
            "def _dg_ref(path):\n"
            "    absolute = path.startswith('/')\n"
            "    parts = []\n"
            "    for token in path.split('/'):\n"
            "        if token in ('', '.'):\n"
            "            continue\n"
            "        if token == '..':\n"
            "            if parts and parts[-1] != '..':\n"
            "                parts.pop()\n"
            "            elif absolute:\n"
            "                raise ValueError('escapes root')\n"
            "            else:\n"
            "                parts.append('..')\n"
            "        else:\n"
            "            parts.append(token)\n"
            "    if absolute:\n"
            "        return '/' + '/'.join(parts)\n"
            "    return '/'.join(parts) or '.'\n",
            "normalize_path",
            [
                ["/%s/a/../b" % head],
                ["a//b/./c"],
                ["/"],
                [""],
                ["../x"],
                ["/a/b/../../c"],
                ["./a/./b"],
            ],
            "for _dg_bad in ['/..', '/a/../..']:\n"
            "    try:\n"
            "        normalize_path(_dg_bad)\n"
            "        raise AssertionError('нет ValueError для %s' % _dg_bad)\n"
            "    except ValueError:\n"
            "        pass\n",
        ),
    )


def _t_round_half_up(rng: random.Random) -> Task:
    value = rng.choice([2.675, 1.005, 3.145, 0.125])
    return Task(
        "round-half-up", "normal", "code",
        "Округление половины вверх",
        "Напиши функцию на Python `round_half_up(x, digits)`, которая округляет число по правилу "
        "«половина всегда от нуля», а не по банковскому правилу встроенного round(). Результат — "
        "float. Учти, что двоичное представление дробей неточно: 2.675 должно давать 2.68, "
        "а 1.005 — 1.01.",
        _py(
            "from decimal import Decimal, ROUND_HALF_UP\n"
            "def _dg_ref(x, digits):\n"
            "    quant = Decimal(1).scaleb(-digits)\n"
            "    return float(Decimal(repr(x)).quantize(quant, rounding=ROUND_HALF_UP))\n",
            "round_half_up",
            [[value, 2], [2.675, 2], [1.005, 2], [0.5, 0], [1.5, 0], [2.5, 0], [-0.5, 0], [-2.5, 0], [1.2345, 3]],
        ),
    )


def _t_interval_intersection(rng: random.Random) -> Task:
    first = [[1, 4], [6, 9], [12, 20]]
    second = [[2, 3], [5, 7], [8, 15], [18, 25]]
    return Task(
        "interval-intersection", "normal", "code",
        "Пересечение отрезков",
        "Напиши функцию на Python `interval_intersection(first, second)`, которая возвращает "
        "пересечения двух списков отрезков. Каждый список отсортирован, отрезки внутри списка не "
        "пересекаются, границы включаются в отрезок. Касание в одной точке — тоже пересечение "
        "(даёт отрезок нулевой длины). Результат отсортирован по началу, элементы — списки из двух чисел.",
        _py(
            "def _dg_ref(first, second):\n"
            "    out = []\n"
            "    i = j = 0\n"
            "    while i < len(first) and j < len(second):\n"
            "        low = max(first[i][0], second[j][0])\n"
            "        high = min(first[i][1], second[j][1])\n"
            "        if low <= high:\n"
            "            out.append([low, high])\n"
            "        if first[i][1] < second[j][1]:\n"
            "            i += 1\n"
            "        else:\n"
            "            j += 1\n"
            "    return out\n",
            "interval_intersection",
            [
                [first, second],
                [[], [[1, 2]]],
                [[[1, 5]], [[5, 9]]],
                [[[1, 2], [3, 4]], [[2, 3]]],
                [[[1, 10]], [[2, 3], [4, 5]]],
            ],
        ),
    )


def _t_merge_intervals(rng: random.Random) -> Task:
    raw = []
    cursor = rng.randint(1, 5)
    for _ in range(rng.randint(4, 7)):
        start = cursor + rng.randint(-2, 3)
        raw.append([start, start + rng.randint(0, 4)])
        cursor = start + rng.randint(1, 5)
    rng.shuffle(raw)
    return Task(
        "merge-intervals", "normal", "code",
        "Объединение отрезков",
        "Напиши функцию на Python `merge_intervals(intervals)`, которая объединяет пересекающиеся "
        "и соприкасающиеся отрезки. Вход не отсортирован, отрезок задан списком [начало, конец]. "
        "Отрезки [1,2] и [2,3] считаются одним. Результат отсортирован по началу.",
        _py(
            "def _dg_ref(intervals):\n"
            "    out = []\n"
            "    for start, end in sorted(intervals):\n"
            "        if out and start <= out[-1][1]:\n"
            "            out[-1][1] = max(out[-1][1], end)\n"
            "        else:\n"
            "            out.append([start, end])\n"
            "    return out\n",
            "merge_intervals",
            [
                [raw],
                [[[1, 3], [2, 6], [8, 10], [15, 18]]],
                [[[2, 3], [1, 2]]],
                [[]],
                [[[5, 5]]],
                [[[1, 10], [2, 3]]],
            ],
        ),
    )


def _t_sql_streaks(rng: random.Random) -> Task:
    rows = []
    for user in rng.sample(range(1, 30), 3):
        day = rng.randint(1, 5)
        for _ in range(rng.randint(3, 6)):
            rows.append((user, day))
            day += rng.choice([1, 1, 1, 2, 3])
    values = ",".join("(%d,%d)" % row for row in rows)
    setup = (
        "CREATE TABLE logins (user_id INTEGER, day INTEGER);"
        "INSERT INTO logins VALUES %s;" % values
    )
    reference = (
        "SELECT user_id, MAX(streak) AS streak FROM ("
        "  SELECT user_id, COUNT(*) AS streak FROM ("
        "    SELECT user_id, day, day - ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY day) AS grp"
        "    FROM logins) GROUP BY user_id, grp) GROUP BY user_id ORDER BY user_id"
    )
    return Task(
        "sql-streaks", "deep", "sql",
        "Самая длинная серия дней",
        "Таблица SQLite: logins(user_id INTEGER, day INTEGER) — день это порядковый номер дня, "
        "повторов пары (user_id, day) нет. Напиши ОДИН SQL-запрос, который для каждого "
        "пользователя возвращает длину САМОЙ ДЛИННОЙ серии подряд идущих дней: столбцы user_id и "
        "streak, сортировка по user_id. Ответ — только запрос в блоке ```sql.",
        _sql(setup, _sqlite_rows(setup, reference), reference),
    )


def _t_sql_running_total(rng: random.Random) -> Task:
    rows = []
    order_id = 1
    for customer in rng.sample(range(10, 40), 2):
        for _ in range(rng.randint(3, 5)):
            rows.append((order_id, customer, rng.randint(50, 900)))
            order_id += 1
    values = ",".join("(%d,%d,%d)" % row for row in rows)
    setup = (
        "CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER);"
        "INSERT INTO orders VALUES %s;" % values
    )
    reference = (
        "SELECT customer_id, id, amount,"
        " SUM(amount) OVER (PARTITION BY customer_id ORDER BY id"
        " ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running"
        " FROM orders ORDER BY customer_id, id"
    )
    return Task(
        "sql-running-total", "deep", "sql",
        "Нарастающий итог",
        "Таблица SQLite: orders(id INTEGER PRIMARY KEY, customer_id INTEGER, amount INTEGER). "
        "Напиши ОДИН SQL-запрос, который возвращает столбцы customer_id, id, amount и "
        "нарастающий итог суммы по каждому клиенту в порядке возрастания id (четвёртый столбец "
        "running). Сортировка результата: по customer_id, затем по id. "
        "Ответ — только запрос в блоке ```sql.",
        _sql(setup, _sqlite_rows(setup, reference), reference),
    )


# ── deep, hard enough for a Pro-class model ─────────────────────────────────
# A first live run scored 24/24 with Gemini 3.1 Pro: "known algorithm + one
# trap" is not enough. These five hinge on rules that are precisely specified
# and widely misremembered, so a wrong answer looks completely plausible.


def _t_cron_match(rng: random.Random) -> Task:
    minute = rng.choice([0, 5, 15, 30])
    hour = rng.randint(0, 23)
    return Task(
        "cron-match", "deep", "code",
        "Совпадение с cron-строкой",
        "Напиши функцию на Python `cron_match(expr, minute, hour, day, month, weekday)`, которая "
        "проверяет, подходит ли момент времени под cron-выражение из пяти полей: минута (0-59), "
        "час (0-23), день месяца (1-31), месяц (1-12), день недели (0-6, воскресенье — 0). "
        "Каждое поле: `*`, число, диапазон `a-b`, шаг `*/n` или `a-b/n`, либо список через запятую. "
        "ВАЖНОЕ ПРАВИЛО: если ограничены ОБА поля — и день месяца, и день недели — момент подходит "
        "при совпадении ЛЮБОГО из них; если ограничено только одно, оно должно совпасть. "
        "Возвращай True или False.",
        _py(
            "def _dg_field(spec, value, low, high):\n"
            "    for part in spec.split(','):\n"
            "        step = 1\n"
            "        body = part\n"
            "        if '/' in part:\n"
            "            body, _, raw = part.partition('/')\n"
            "            step = int(raw)\n"
            "        if body == '*':\n"
            "            start, end = low, high\n"
            "        elif '-' in body:\n"
            "            left, _, right = body.partition('-')\n"
            "            start, end = int(left), int(right)\n"
            "        else:\n"
            "            start = end = int(body)\n"
            "        if value < start or value > end:\n"
            "            continue\n"
            "        if (value - start) % step == 0:\n"
            "            return True\n"
            "    return False\n"
            "def _dg_ref(expr, minute, hour, day, month, weekday):\n"
            "    minute_s, hour_s, dom_s, month_s, dow_s = expr.split()\n"
            "    if not _dg_field(minute_s, minute, 0, 59):\n"
            "        return False\n"
            "    if not _dg_field(hour_s, hour, 0, 23):\n"
            "        return False\n"
            "    if not _dg_field(month_s, month, 1, 12):\n"
            "        return False\n"
            "    dom_limited = dom_s != '*'\n"
            "    dow_limited = dow_s != '*'\n"
            "    dom_ok = _dg_field(dom_s, day, 1, 31)\n"
            "    dow_ok = _dg_field(dow_s, weekday, 0, 6)\n"
            "    if dom_limited and dow_limited:\n"
            "        return dom_ok or dow_ok\n"
            "    if dom_limited:\n"
            "        return dom_ok\n"
            "    if dow_limited:\n"
            "        return dow_ok\n"
            "    return True\n",
            "cron_match",
            [
                ["*/15 * * * *", minute, hour, 7, 3, 2],
                ["0 9-17 * * 1-5", 0, 13, 14, 6, 3],
                ["0 0 13 * 5", 0, 0, 13, 4, 1],
                ["0 0 13 * 5", 0, 0, 20, 4, 5],
                ["0 0 13 * 5", 0, 0, 20, 4, 1],
                ["0 0 * * 0", 0, 0, 20, 4, 0],
                ["30 2 1,15 * *", 30, 2, 15, 8, 6],
                ["30 2 1,15 * *", 30, 2, 16, 8, 6],
                ["0 0-23/6 * * *", 0, 18, 1, 1, 1],
                ["%d %d * * *" % (minute, hour), minute, hour, 1, 1, 1],
            ],
        ),
    )


def _t_semver_range(rng: random.Random) -> Task:
    patch = rng.randint(1, 9)
    return Task(
        "semver-range", "deep", "code",
        "Диапазоны ^ и ~",
        "Напиши функцию на Python `satisfies(spec, version)`, которая проверяет, попадает ли "
        "версия вида МАЖОР.МИНОР.ПАТЧ в диапазон. Форматы spec: точная версия «1.2.3»; "
        "тильда «~1.2.3» — от 1.2.3 включительно до 1.3.0 (не включая), а «~1.2» — от 1.2.0 до "
        "1.3.0; каретка «^1.2.3» — до следующего мажора (2.0.0). ОСОБЫЕ СЛУЧАИ каретки при нуле: "
        "«^0.2.3» ограничена сверху 0.3.0, а «^0.0.3» — 0.0.4. Предрелизы не рассматриваем. "
        "Возвращай True или False.",
        _py(
            "def _dg_parse(text):\n"
            "    parts = [int(x) for x in text.split('.')]\n"
            "    while len(parts) < 3:\n"
            "        parts.append(0)\n"
            "    return tuple(parts)\n"
            "def _dg_ref(spec, version):\n"
            "    current = _dg_parse(version)\n"
            "    if spec[0] not in '^~':\n"
            "        return current == _dg_parse(spec)\n"
            "    body = spec[1:]\n"
            "    given = len(body.split('.'))\n"
            "    low = _dg_parse(body)\n"
            "    if spec[0] == '~':\n"
            "        high = (low[0], low[1] + 1, 0)\n"
            "    elif low[0] != 0:\n"
            "        high = (low[0] + 1, 0, 0)\n"
            "    elif low[1] != 0 or given >= 2:\n"
            "        high = (0, low[1] + 1, 0)\n"
            "    else:\n"
            "        high = (0, 0, low[2] + 1)\n"
            "    if low[0] == 0 and low[1] == 0 and given >= 3:\n"
            "        high = (0, 0, low[2] + 1)\n"
            "    return low <= current < high\n",
            "satisfies",
            [
                ["^1.2.3", "1.9.0"], ["^1.2.3", "2.0.0"], ["^1.2.3", "1.2.2"],
                ["^0.2.3", "0.2.9"], ["^0.2.3", "0.3.0"],
                ["^0.0.3", "0.0.3"], ["^0.0.3", "0.0.4"],
                ["~1.2.3", "1.2.9"], ["~1.2.3", "1.3.0"], ["~1.2", "1.2.7"],
                ["1.2.3", "1.2.3"], ["1.2.3", "1.2.4"],
                ["^1.0.%d" % patch, "1.5.0"],
            ],
        ),
    )


def _t_min_rooms(rng: random.Random) -> Task:
    meetings = []
    for _ in range(rng.randint(5, 8)):
        start = rng.randint(0, 12)
        meetings.append([start, start + rng.randint(1, 5)])
    return Task(
        "min-rooms", "deep", "code",
        "Минимум переговорных",
        "Напиши функцию на Python `assign_rooms(meetings)`: встреча задана полуинтервалом "
        "[начало, конец) — встреча, которая кончается в 10, не мешает начинающейся в 10. Верни "
        "кортеж (количество комнат, список номеров комнат). Правило распределения: встречи "
        "рассматриваются по возрастанию начала, при равенстве — по возрастанию конца, затем по "
        "исходному номеру; каждая занимает СВОБОДНУЮ комнату с наименьшим номером (нумерация с 0). "
        "Список номеров возвращается в ИСХОДНОМ порядке встреч.",
        _py(
            "def _dg_ref(meetings):\n"
            "    order = sorted(range(len(meetings)), key=lambda i: (meetings[i][0], meetings[i][1], i))\n"
            "    busy = []\n"
            "    rooms = [0] * len(meetings)\n"
            "    for index in order:\n"
            "        start, end = meetings[index]\n"
            "        room = None\n"
            "        for number in range(len(busy)):\n"
            "            if busy[number] <= start:\n"
            "                room = number\n"
            "                break\n"
            "        if room is None:\n"
            "            busy.append(end)\n"
            "            room = len(busy) - 1\n"
            "        else:\n"
            "            busy[room] = end\n"
            "        rooms[index] = room\n"
            "    return (len(busy), rooms)\n",
            "assign_rooms",
            [
                [meetings],
                [[[0, 30], [5, 10], [15, 20]]],
                [[[0, 10], [10, 20]]],
                [[[1, 5], [1, 3], [1, 4]]],
                [[]],
                [[[7, 8]]],
            ],
        ),
    )


def _t_parse_query(rng: random.Random) -> Task:
    city = rng.choice(["Москва", "Тверь", "Сочи"])
    return Task(
        "parse-query", "normal", "code",
        "Разбор строки запроса",
        "Напиши функцию на Python `parse_query(text)`, которая разбирает строку запроса URL в "
        "словарь «ключ → СПИСОК значений» (повторяющиеся ключи не теряются, порядок ключей — по "
        "первому появлению). Разделитель пар только «&»; точка с запятой — обычный символ. Плюс "
        "означает пробел, последовательности %XX декодируются как UTF-8. Пара без «=» даёт пустое "
        "значение, пустые куски между «&» пропускаются, ведущий «?» отбрасывается.",
        _py(
            "from urllib.parse import unquote_plus\n"
            "def _dg_ref(text):\n"
            "    if text.startswith('?'):\n"
            "        text = text[1:]\n"
            "    out = {}\n"
            "    for chunk in text.split('&'):\n"
            "        if not chunk:\n"
            "            continue\n"
            "        key, sep, value = chunk.partition('=')\n"
            "        key = unquote_plus(key)\n"
            "        value = unquote_plus(value) if sep else ''\n"
            "        out.setdefault(key, []).append(value)\n"
            "    return out\n",
            "parse_query",
            [
                ["a=1&b=2&a=3"],
                ["?q=%s&page=2" % "".join("%%%02X" % byte for byte in city.encode("utf-8"))],
                ["flag&x=1"],
                ["a=1;b=2"],
                ["a=hello+world"],
                ["&&a=1&&"],
                [""],
                ["k%3Dey=v%26al"],
            ],
        ),
    )


def _t_allocate_weights(rng: random.Random) -> Task:
    total = rng.randint(100, 10000)
    weights = [rng.randint(1, 9) for _ in range(rng.randint(3, 5))]
    return Task(
        "allocate-weights", "normal", "code",
        "Раздача по весам",
        "Напиши функцию на Python `allocate(total, weights)`, которая делит целое total "
        "пропорционально весам так, чтобы сумма частей была равна total РОВНО. Метод: каждому "
        "достаётся целая часть от пропорции, оставшиеся единицы раздаются по убыванию дробного "
        "остатка, а при равных остатках — тому, чей индекс меньше. Нулевой вес получает ноль. "
        "Если весов нет, есть отрицательный вес или их сумма равна нулю — возбуди ValueError.",
        _py(
            "from fractions import Fraction\n"
            "def _dg_ref(total, weights):\n"
            "    if not weights or any(w < 0 for w in weights) or sum(weights) == 0:\n"
            "        raise ValueError('weights')\n"
            "    whole = sum(weights)\n"
            "    shares = [Fraction(total * w, whole) for w in weights]\n"
            "    out = [int(share) for share in shares]\n"
            "    rest = total - sum(out)\n"
            "    order = sorted(range(len(weights)), key=lambda i: (-(shares[i] - out[i]), i))\n"
            "    for index in order[:rest]:\n"
            "        out[index] += 1\n"
            "    return out\n",
            "allocate",
            [
                [total, weights],
                [100, [1, 1, 1]],
                [10, [1, 1]],
                [7, [1, 0, 1]],
                [0, [5, 5]],
                [5, [1, 2, 3]],
                [1, [1, 1, 1]],
            ],
            "for _dg_bad in [(10, []), (10, [1, -1]), (10, [0, 0])]:\n"
            "    try:\n"
            "        allocate(*_dg_bad)\n"
            "        raise AssertionError('нет ValueError')\n"
            "    except ValueError:\n"
            "        pass\n"
            "_dg_out = allocate(97, [3, 3, 3])\n"
            "assert sum(_dg_out) == 97, _dg_out\n",
        ),
    )


# ── deep: rules that are easy to state and easy to get wrong ────────────────


def _t_wildcard_match(rng: random.Random) -> Task:
    stem = rng.choice(["report", "backup", "delegator"])
    return Task(
        "wildcard-match", "deep", "code",
        "Сопоставление с маской",
        "Напиши функцию на Python `wildcard_match(pattern, text)`, которая проверяет, подходит ли "
        "строка под маску целиком. В маске `*` заменяет любую последовательность символов, включая "
        "пустую, а `?` — ровно один символ. Других спецсимволов нет: точка, скобки и прочее "
        "сравниваются буквально. Регулярные выражения использовать нельзя. Возвращай True или False.",
        _py(
            "def _dg_ref(pattern, text):\n"
            "    rows = len(pattern)\n"
            "    cols = len(text)\n"
            "    table = [[False] * (cols + 1) for _ in range(rows + 1)]\n"
            "    table[0][0] = True\n"
            "    for i in range(1, rows + 1):\n"
            "        if pattern[i - 1] == '*':\n"
            "            table[i][0] = table[i - 1][0]\n"
            "    for i in range(1, rows + 1):\n"
            "        for j in range(1, cols + 1):\n"
            "            symbol = pattern[i - 1]\n"
            "            if symbol == '*':\n"
            "                table[i][j] = table[i - 1][j] or table[i][j - 1]\n"
            "            elif symbol == '?' or symbol == text[j - 1]:\n"
            "                table[i][j] = table[i - 1][j - 1]\n"
            "    return table[rows][cols]\n",
            "wildcard_match",
            [
                ["*", ""], ["*", "anything"], ["", ""], ["", "x"],
                ["a*b*c", "abcbc"], ["a*b*c", "abbbbc"], ["a*b*c", "acb"],
                ["?%s" % stem, "x%s" % stem], ["?%s" % stem, "%s" % stem],
                ["*.txt", "note.txt"], ["*.txt", "note.txt.bak"],
                ["a.b", "axb"], ["a?c*", "abcdef"], ["**a", "za"],
            ],
        ),
    )


def _t_eval_expression(rng: random.Random) -> Task:
    left = rng.randint(2, 40)
    right = rng.randint(2, 9)
    return Task(
        "eval-expression", "deep", "code",
        "Калькулятор выражений",
        "Напиши функцию на Python `evaluate(text)`, которая вычисляет целочисленное выражение из "
        "чисел, операций + - * / , скобок и унарного минуса. Приоритет обычный. Деление — ЦЕЛОЕ с "
        "усечением В СТОРОНУ НУЛЯ (то есть -7/2 это -3, а не -4). Пробелы игнорируются. Деление на "
        "ноль — ZeroDivisionError, любой мусор во вводе — ValueError. Функцию eval использовать нельзя.",
        _py(
            "def _dg_ref(text):\n"
            "    tokens = []\n"
            "    index = 0\n"
            "    clean = text.replace(' ', '').replace('\\t', '')\n"
            "    while index < len(clean):\n"
            "        char = clean[index]\n"
            "        if char.isdigit():\n"
            "            number = ''\n"
            "            while index < len(clean) and clean[index].isdigit():\n"
            "                number += clean[index]\n"
            "                index += 1\n"
            "            tokens.append(int(number))\n"
            "            continue\n"
            "        if char not in '+-*/()':\n"
            "            raise ValueError('bad token')\n"
            "        tokens.append(char)\n"
            "        index += 1\n"
            "    position = [0]\n"
            "    def peek():\n"
            "        return tokens[position[0]] if position[0] < len(tokens) else None\n"
            "    def take():\n"
            "        value = peek()\n"
            "        position[0] += 1\n"
            "        return value\n"
            "    def unary():\n"
            "        token = peek()\n"
            "        if token == '-':\n"
            "            take()\n"
            "            return -unary()\n"
            "        if token == '+':\n"
            "            take()\n"
            "            return unary()\n"
            "        if token == '(': \n"
            "            take()\n"
            "            value = expression()\n"
            "            if take() != ')':\n"
            "                raise ValueError('unbalanced')\n"
            "            return value\n"
            "        if isinstance(token, int):\n"
            "            return take()\n"
            "        raise ValueError('unexpected')\n"
            "    def term():\n"
            "        value = unary()\n"
            "        while peek() in ('*', '/'):\n"
            "            operator = take()\n"
            "            right_value = unary()\n"
            "            if operator == '*':\n"
            "                value = value * right_value\n"
            "            else:\n"
            "                if right_value == 0:\n"
            "                    raise ZeroDivisionError('division by zero')\n"
            "                value = int(value / right_value)\n"
            "        return value\n"
            "    def expression():\n"
            "        value = term()\n"
            "        while peek() in ('+', '-'):\n"
            "            operator = take()\n"
            "            right_value = term()\n"
            "            value = value + right_value if operator == '+' else value - right_value\n"
            "        return value\n"
            "    result = expression()\n"
            "    if position[0] != len(tokens):\n"
            "        raise ValueError('trailing input')\n"
            "    return result\n",
            "evaluate",
            [
                ["2+3*4"], ["(2+3)*4"], ["-7/2"], ["7/-2"], ["-(3+4)"],
                ["10/3"], ["2*-3"], ["  1 + 2 * ( 3 - 1 ) "],
                ["%d/%d" % (left, right)], ["%d-%d*2" % (left, right)],
            ],
            "try:\n"
            "    evaluate('1/0')\n"
            "    raise AssertionError('нет ZeroDivisionError')\n"
            "except ZeroDivisionError:\n"
            "    pass\n"
            "for _dg_bad in ['2+', '(1+2', 'abc', '']:\n"
            "    try:\n"
            "        evaluate(_dg_bad)\n"
            "        raise AssertionError('нет ValueError для %r' % _dg_bad)\n"
            "    except ValueError:\n"
            "        pass\n",
        ),
    )


def _t_iso_duration(rng: random.Random) -> Task:
    hours = rng.randint(1, 20)
    minutes = rng.choice([5, 15, 30, 45])
    return Task(
        "iso-duration", "deep", "code",
        "Длительность ISO 8601",
        "Напиши функцию на Python `iso_duration_seconds(text)`, которая переводит длительность "
        "ISO 8601 в секунды. Формы: `PnW` (недели) либо `PnDTnHnMnS`, любые компоненты можно "
        "опустить, но `T` обязательна перед частями времени. Примеры: `P1DT2H30M`, `PT45S`, "
        "`P2W`, `PT0S`. Недели с другими компонентами не сочетаются. Всё, что не подходит под "
        "формат (пустая строка, `P`, `1D`, `PT`, `P1S`), — ValueError.",
        _py(
            "import re\n"
            "_DG_RE = re.compile(r'^P(?:(\\d+)W|(?:(\\d+)D)?(?:T(?:(\\d+)H)?(?:(\\d+)M)?(?:(\\d+)S)?)?)$')\n"
            "def _dg_ref(text):\n"
            "    match = _DG_RE.match(text or '')\n"
            "    if not match:\n"
            "        raise ValueError('bad duration')\n"
            "    weeks, days, hours, minutes, seconds = match.groups()\n"
            "    if weeks is None and days is None and hours is None and minutes is None and seconds is None:\n"
            "        raise ValueError('empty duration')\n"
            "    if 'T' in text and hours is None and minutes is None and seconds is None:\n"
            "        raise ValueError('empty time part')\n"
            "    total = 0\n"
            "    if weeks:\n"
            "        total += int(weeks) * 7 * 86400\n"
            "    if days:\n"
            "        total += int(days) * 86400\n"
            "    if hours:\n"
            "        total += int(hours) * 3600\n"
            "    if minutes:\n"
            "        total += int(minutes) * 60\n"
            "    if seconds:\n"
            "        total += int(seconds)\n"
            "    return total\n",
            "iso_duration_seconds",
            [
                ["P1DT2H30M"], ["PT45S"], ["P2W"], ["PT0S"], ["P3D"],
                ["PT%dH%dM" % (hours, minutes)], ["P1DT1S"], ["PT1H"],
            ],
            "for _dg_bad in ['', 'P', '1D', 'PT', 'P1S', 'P1WT1H', 'PT1D']:\n"
            "    try:\n"
            "        iso_duration_seconds(_dg_bad)\n"
            "        raise AssertionError('нет ValueError для %r' % _dg_bad)\n"
            "    except ValueError:\n"
            "        pass\n",
        ),
    )


def _t_next_business_day(rng: random.Random) -> Task:
    day = rng.randint(1, 20)
    return Task(
        "next-business-day", "normal", "code",
        "Следующий рабочий день",
        "Напиши функцию на Python `next_business_day(date_text, holidays)`, которая возвращает "
        "СТРОГО следующий рабочий день после указанной даты в формате ГГГГ-ММ-ДД. Суббота, "
        "воскресенье и даты из списка holidays (тоже строки ГГГГ-ММ-ДД) рабочими не считаются и "
        "пропускаются подряд, сколько бы их ни было. Сама переданная дата в расчёт не берётся, "
        "даже если она рабочая.",
        _py(
            "from datetime import date, timedelta\n"
            "def _dg_ref(date_text, holidays):\n"
            "    skip = set(holidays or [])\n"
            "    year, month, day = (int(part) for part in date_text.split('-'))\n"
            "    current = date(year, month, day)\n"
            "    while True:\n"
            "        current += timedelta(days=1)\n"
            "        if current.weekday() >= 5:\n"
            "            continue\n"
            "        if current.isoformat() in skip:\n"
            "            continue\n"
            "        return current.isoformat()\n",
            "next_business_day",
            [
                ["2026-08-13", []],
                ["2026-08-14", []],
                ["2026-08-15", []],
                ["2026-08-13", ["2026-08-14", "2026-08-17"]],
                ["2026-12-31", ["2027-01-01"]],
                ["2026-08-%02d" % day, ["2026-08-%02d" % (day + 1)]],
            ],
        ),
    )


# ── multi-constraint specifications ─────────────────────────────────────────
#
# Five runs said the same thing: a modern model does not fail a short task that
# asks for one known algorithm. Runs #4 and #5 (deepseek-v4-flash-free) came
# back 21/24 and 24/24 with ELEVEN and TWELVE ties — the set measured nothing,
# and Delegator had nothing to improve.
#
# What models do still fail is a specification with many simultaneous rules that
# interact: they satisfy eight of eleven and quietly drop the rest. That is the
# class this section adds, and it is the one partial credit was built for — the
# score finally lands between 0 and full, which is where a difference between
# the two arms can appear at all.


def _spec_checks(entry: str, groups: list[tuple[str, str, list]]) -> list[dict]:
    """A gate plus one named check per rule of the specification."""
    checks = [
        check(
            "contract",
            "функция %s определена" % entry,
            code="assert callable(%s), 'нет функции %s'" % (entry, entry),
            weight=0,
        )
    ]
    checks.extend(check(name, title, cases=cases) for name, title, cases in groups)
    return checks


def _t_validate_order(rng: random.Random) -> Task:
    coupon = rng.choice(["SAVE20", "AB12", "PROMOCODE1"])
    good = {"qty": rng.randint(2, 9), "price": 12.5, "email": "a@b.co", "country": "DE"}
    reference = (
        "def _dg_ref(order):\n"
        "    errors = []\n"
        "    qty = order.get('qty')\n"
        "    price = order.get('price')\n"
        "    qty_ok = isinstance(qty, int) and qty >= 1\n"
        "    if not qty_ok:\n"
        "        errors.append('qty-invalid')\n"
        "    price_ok = isinstance(price, (int, float)) and price > 0\n"
        "    if not price_ok:\n"
        "        errors.append('price-invalid')\n"
        "    elif round(price, 2) != price:\n"
        "        errors.append('price-precision')\n"
        "    email = order.get('email')\n"
        "    ok_email = False\n"
        "    if isinstance(email, str) and email.count('@') == 1:\n"
        "        name, _, domain = email.partition('@')\n"
        "        ok_email = bool(name) and '.' in domain\n"
        "    if not ok_email:\n"
        "        errors.append('email-invalid')\n"
        "    country = order.get('country')\n"
        "    country_ok = (\n"
        "        isinstance(country, str) and len(country) == 2\n"
        "        and all('A' <= ch <= 'Z' for ch in country)\n"
        "    )\n"
        "    if not country_ok:\n"
        "        errors.append('country-invalid')\n"
        "    if country == 'US':\n"
        "        zip_code = order.get('zip')\n"
        "        if not (isinstance(zip_code, str) and len(zip_code) == 5 and zip_code.isdigit()):\n"
        "            errors.append('zip-invalid')\n"
        "    has_coupon = order.get('coupon') is not None\n"
        "    if has_coupon:\n"
        "        value = order['coupon']\n"
        "        ok = (\n"
        "            isinstance(value, str) and 4 <= len(value) <= 10\n"
        "            and all(ch.isdigit() or 'A' <= ch <= 'Z' for ch in value)\n"
        "        )\n"
        "        if not ok:\n"
        "            errors.append('coupon-invalid')\n"
        "    if qty_ok and qty > 100 and order.get('approved') is not True:\n"
        "        errors.append('approval-required')\n"
        "    if qty_ok and price_ok and qty * price > 10000 and has_coupon:\n"
        "        errors.append('coupon-not-allowed')\n"
        "    return sorted(errors)\n"
    )
    return Task(
        "validate-order", "deep", "spec",
        "Проверка заказа по девяти правилам",
        "Напиши функцию на Python `validate_order(order)`. На вход — словарь. Верни "
        "ОТСОРТИРОВАННЫЙ по алфавиту список кодов ошибок; если нарушений нет — пустой список. "
        "Правила ровно такие и никаких других:\n"
        "1. `qty-invalid` — поля `qty` нет, оно не целое число или меньше 1.\n"
        "2. `price-invalid` — поля `price` нет, оно не число или не больше нуля.\n"
        "3. `price-precision` — цена корректна (правило 2 не сработало), но в ней больше двух "
        "знаков после запятой. Если сработало правило 2, это правило НЕ проверяется.\n"
        "4. `email-invalid` — `email` не строка, либо в нём не ровно одна `@`, либо перед `@` "
        "пусто, либо после `@` нет точки.\n"
        "5. `country-invalid` — `country` не строка ровно из двух заглавных латинских букв.\n"
        "6. `zip-invalid` — `country` равен `US`, а `zip` не строка ровно из пяти цифр. "
        "Для других стран `zip` не проверяется вообще.\n"
        "7. `coupon-invalid` — `coupon` присутствует и не равен None, но это не строка длиной "
        "от 4 до 10 из заглавных латинских букв и цифр.\n"
        "8. `approval-required` — `qty` корректен и больше 100, а `approved` не равен True.\n"
        "9. `coupon-not-allowed` — `qty` и `price` корректны, `qty * price` больше 10000, "
        "и при этом купон присутствует.",
        _py(
            reference,
            "validate_order",
            [],
            checks=_spec_checks(
                "validate_order",
                [
                    ("valid-order", "корректный заказ даёт пустой список", [[good]]),
                    ("qty-invalid", "правило 1: количество", [
                        [{"qty": 0, "price": 5, "email": "a@b.co", "country": "DE"}],
                        [{"price": 5, "email": "a@b.co", "country": "DE"}],
                        [{"qty": "3", "price": 5, "email": "a@b.co", "country": "DE"}],
                    ]),
                    ("price-invalid", "правило 2: цена", [
                        [{"qty": 1, "price": 0, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 1, "price": -3.0, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 1, "email": "a@b.co", "country": "DE"}],
                    ]),
                    ("price-precision", "правило 3: не больше двух знаков", [
                        [{"qty": 1, "price": 5.005, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 1, "price": 5.5, "email": "a@b.co", "country": "DE"}],
                    ]),
                    ("price-precision-suppressed", "правило 3 молчит, когда сработало правило 2", [
                        [{"qty": 1, "price": -5.005, "email": "a@b.co", "country": "DE"}],
                    ]),
                    ("email-invalid", "правило 4: адрес", [
                        [{"qty": 1, "price": 5, "email": "a@bco", "country": "DE"}],
                        [{"qty": 1, "price": 5, "email": "@b.co", "country": "DE"}],
                        [{"qty": 1, "price": 5, "email": "a@b@c.co", "country": "DE"}],
                        [{"qty": 1, "price": 5, "email": 42, "country": "DE"}],
                    ]),
                    ("country-invalid", "правило 5: страна", [
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "de"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DEU"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co"}],
                    ]),
                    ("zip-only-for-us", "правило 6: индекс только для US", [
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "US"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "US", "zip": "1234"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "US", "zip": "12345"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DE", "zip": "x"}],
                    ]),
                    ("coupon-invalid", "правило 7: купон", [
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DE", "coupon": "ab12"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DE", "coupon": "AB1"}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DE", "coupon": coupon}],
                        [{"qty": 1, "price": 5, "email": "a@b.co", "country": "DE", "coupon": None}],
                    ]),
                    ("approval-required", "правило 8: согласование больших заказов", [
                        [{"qty": 101, "price": 1, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 101, "price": 1, "email": "a@b.co", "country": "DE", "approved": True}],
                        [{"qty": 100, "price": 1, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 0, "price": 1, "email": "a@b.co", "country": "DE", "approved": False}],
                    ]),
                    ("coupon-not-allowed", "правило 9: купон на крупный заказ", [
                        [{"qty": 50, "price": 300.0, "email": "a@b.co", "country": "DE", "coupon": "SAVE20"}],
                        [{"qty": 50, "price": 300.0, "email": "a@b.co", "country": "DE"}],
                        [{"qty": 50, "price": 200.0, "email": "a@b.co", "country": "DE", "coupon": "SAVE20"}],
                    ]),
                    ("sorted-output", "коды отсортированы по алфавиту", [
                        [{"qty": 0, "price": 0, "email": "x", "country": "x"}],
                    ]),
                ],
            ),
        ),
    )


def _t_apply_discounts(rng: random.Random) -> Task:
    total = rng.choice([12345, 9900, 25000, 7777])
    reference = (
        "def _dg_ref(total, percent, fixed, coupon):\n"
        "    if not isinstance(percent, int) or percent < 0 or percent > 100:\n"
        "        raise ValueError('percent')\n"
        "    if total < 0 or fixed < 0 or coupon < 0:\n"
        "        raise ValueError('negative')\n"
        "    running = total - (total * percent + 50) // 100\n"
        "    running = max(0, running - fixed)\n"
        "    if running >= 5000:\n"
        "        running = max(0, running - coupon)\n"
        "    return running\n"
    )
    return Task(
        "apply-discounts", "deep", "spec",
        "Скидки в строгом порядке",
        "Напиши функцию на Python `apply_discounts(total, percent, fixed, coupon)`. Все суммы — "
        "целые числа в копейках. Правила ровно такие:\n"
        "1. Скидки применяются строго по порядку: процентная, затем фиксированная, затем купон.\n"
        "2. Процентная скидка равна сумме, умноженной на percent и делённой на 100 с округлением "
        "«половина ВВЕРХ» до целой копейки, и вычитается из суммы.\n"
        "3. Фиксированная скидка вычитается следом, но итог не может стать меньше нуля.\n"
        "4. Купон применяется ТОЛЬКО если сумма после шагов 2 и 3 не меньше 5000 копеек; "
        "иначе шаг пропускается целиком.\n"
        "5. После купона итог тоже не может стать меньше нуля.\n"
        "6. Если percent не целое число или выходит за границы 0..100 — возбуди ValueError.\n"
        "7. Если total, fixed или coupon отрицательные — возбуди ValueError.\n"
        "8. Проверки из правил 6 и 7 выполняются ДО любых вычислений.\n"
        "9. Возвращается целое число.",
        _py(
            reference,
            "apply_discounts",
            [],
            checks=[
                check(
                    "contract", "функция apply_discounts определена",
                    code="assert callable(apply_discounts), 'нет функции apply_discounts'",
                    weight=0,
                ),
                check("percent-half-up", "правило 2: округление половины вверх",
                      cases=[[1005, 50, 0, 0], [total, 13, 0, 0], [3, 50, 0, 0], [1, 50, 0, 0]]),
                check("order-of-steps", "правило 1: порядок шагов",
                      cases=[[total, 10, 1000, 500], [20000, 25, 2000, 1000]]),
                check("fixed-not-below-zero", "правило 3: не уходим в минус",
                      cases=[[1000, 0, 5000, 0], [1000, 50, 900, 0]]),
                check("coupon-threshold", "правило 4: купон только от 5000",
                      cases=[[6000, 0, 0, 1000], [6000, 0, 1500, 1000], [5000, 0, 0, 100],
                             [4999, 0, 0, 100]]),
                check("coupon-not-below-zero", "правило 5: купон тоже не уводит в минус",
                      cases=[[6000, 0, 0, 99999]]),
                check(
                    "percent-validation", "правило 6: ValueError на неверном проценте",
                    code=(
                        "for _bad in (101, -1, 5.0, '10'):\n"
                        "    try:\n"
                        "        apply_discounts(1000, _bad, 0, 0)\n"
                        "    except ValueError:\n"
                        "        continue\n"
                        "    raise AssertionError('нет ValueError при percent=%r' % (_bad,))\n"
                    ),
                ),
                check(
                    "negative-validation", "правило 7: ValueError на отрицательных суммах",
                    code=(
                        "for _args in ((-1, 0, 0, 0), (100, 0, -1, 0), (100, 0, 0, -1)):\n"
                        "    try:\n"
                        "        apply_discounts(*_args)\n"
                        "    except ValueError:\n"
                        "        continue\n"
                        "    raise AssertionError('нет ValueError при %r' % (_args,))\n"
                    ),
                ),
                check(
                    "validation-comes-first", "правило 8: проверки до вычислений",
                    code=(
                        "try:\n"
                        "    apply_discounts(-100, 200, -5, -5)\n"
                        "except ValueError:\n"
                        "    pass\n"
                        "else:\n"
                        "    raise AssertionError('нет ValueError на полностью неверном входе')\n"
                    ),
                ),
                check(
                    "integer-result", "правило 9: результат целый",
                    code=(
                        "_got = apply_discounts(%d, 13, 7, 11)\n"
                        "assert isinstance(_got, int), 'результат не целое число: %%r' %% (_got,)\n"
                        % total
                    ),
                ),
            ],
        ),
    )


# ── debug from a failing case ───────────────────────────────────────────────
#
# The closest thing in the set to what an IDE agent actually does all day: here
# is code, here is one input where it is wrong, fix it without breaking the
# rest. It is also the class where `improve` should be strongest, because it is
# handed a concrete failure instead of being asked to review in the abstract.


def _t_fix_insert_point(rng: random.Random) -> Task:
    data = sorted(rng.sample(range(1, 40), 5))
    missing = data[-1] + rng.randint(1, 5)
    reference = (
        "def _dg_ref(items, value):\n"
        "    low, high = 0, len(items)\n"
        "    while low < high:\n"
        "        mid = (low + high) // 2\n"
        "        if items[mid] <= value:\n"
        "            low = mid + 1\n"
        "        else:\n"
        "            high = mid\n"
        "    return low\n"
    )
    return Task(
        "fix-insert-point", "deep", "debug",
        "Починить точку вставки",
        "Этот код должен возвращать индекс, КУДА вставить value в отсортированный список items, "
        "чтобы он остался отсортированным; при равных значениях — правее всех равных "
        "(как `bisect.bisect_right`).\n\n"
        "```python\n"
        "def insert_point(items, value):\n"
        "    low, high = 0, len(items) - 1\n"
        "    while low < high:\n"
        "        mid = (low + high) // 2\n"
        "        if items[mid] <= value:\n"
        "            low = mid + 1\n"
        "        else:\n"
        "            high = mid\n"
        "    return low\n"
        "```\n\n"
        "Он ошибается: `insert_point(%r, %d)` возвращает %d, а должно быть %d.\n\n"
        "Почини ошибку и верни ИСПРАВЛЕННУЮ функцию целиком, с тем же именем. Остальное "
        "поведение менять нельзя. Модуль `bisect` использовать нельзя — нужен исправленный "
        "двоичный поиск."
        % (data, missing, max(0, len(data) - 1), len(data)),
        _py(
            reference,
            "insert_point",
            [],
            checks=_spec_checks(
                "insert_point",
                [
                    ("reported-case", "указанный в задаче падающий пример",
                     [[data, missing]]),
                    ("append-at-end", "вставка за концом списка",
                     [[[1, 3, 5], 9], [[1], 2], [[1, 2, 3, 4], 100]]),
                    ("insert-before-first", "вставка перед первым элементом",
                     [[data, data[0] - 1], [[5, 7], 1]]),
                    ("insert-in-the-middle", "вставка в середину",
                     [[data, (data[0] + data[-1]) // 2], [[1, 3, 5], 4]]),
                    ("right-of-equals", "правее всех равных значений",
                     [[[1, 2, 2, 2, 3], 2], [[2, 2], 2], [data, data[2]]]),
                    ("empty-and-single", "пустой список и список из одного элемента",
                     [[[], 5], [[5], 5], [[5], 4], [[5], 6]]),
                ],
            ),
            solution=(
                "def insert_point(items, value):\n"
                "    low, high = 0, len(items)\n"
                "    while low < high:\n"
                "        mid = (low + high) // 2\n"
                "        if items[mid] <= value:\n"
                "            low = mid + 1\n"
                "        else:\n"
                "            high = mid\n"
                "    return low\n"
            ),
        ),
    )


def _t_fix_pagination(rng: random.Random) -> Task:
    per_page = rng.choice([10, 20, 25])
    total = per_page * rng.randint(2, 5)
    reference = (
        "def _dg_ref(total, per_page):\n"
        "    if not isinstance(per_page, int) or per_page < 1:\n"
        "        raise ValueError('per_page')\n"
        "    if total < 0:\n"
        "        raise ValueError('total')\n"
        "    return -(-total // per_page)\n"
    )
    return Task(
        "fix-pagination", "deep", "debug",
        "Починить счётчик страниц",
        "Этот код должен считать, сколько страниц нужно, чтобы разложить total записей по "
        "per_page штук на страницу.\n\n"
        "```python\n"
        "def page_count(total, per_page):\n"
        "    return total // per_page + 1\n"
        "```\n\n"
        "Он ошибается: `page_count(%d, %d)` возвращает %d, а должно быть %d.\n\n"
        "Почини и верни исправленную функцию целиком, с тем же именем. Дополнительно должно "
        "выполняться: при total = 0 страниц ноль; если per_page не целое число или меньше 1 — "
        "ValueError; если total отрицательный — ValueError."
        % (total, per_page, total // per_page + 1, total // per_page),
        _py(
            reference,
            "page_count",
            [],
            checks=[
                check(
                    "contract", "функция page_count определена",
                    code="assert callable(page_count), 'нет функции page_count'", weight=0,
                ),
                check("reported-case", "указанный в задаче падающий пример",
                      cases=[[total, per_page]]),
                check("exact-multiples", "точные кратные не дают лишней страницы",
                      cases=[[20, 10], [100, 25], [per_page, per_page]]),
                check("with-remainder", "остаток даёт ещё одну страницу",
                      cases=[[21, 10], [1, 10], [total + 1, per_page]]),
                check("zero-total", "нулевой total — ноль страниц", cases=[[0, per_page], [0, 1]]),
                check(
                    "per-page-validation", "ValueError при неверном per_page",
                    code=(
                        "for _bad in (0, -1, 2.5, '10'):\n"
                        "    try:\n"
                        "        page_count(10, _bad)\n"
                        "    except ValueError:\n"
                        "        continue\n"
                        "    raise AssertionError('нет ValueError при per_page=%r' % (_bad,))\n"
                    ),
                ),
                check(
                    "negative-total-validation", "ValueError при отрицательном total",
                    code=(
                        "try:\n"
                        "    page_count(-1, 10)\n"
                        "except ValueError:\n"
                        "    pass\n"
                        "else:\n"
                        "    raise AssertionError('нет ValueError при отрицательном total')\n"
                    ),
                ),
            ],
            solution=(
                "def page_count(total, per_page):\n"
                "    if not isinstance(per_page, int) or per_page < 1:\n"
                "        raise ValueError('per_page')\n"
                "    if total < 0:\n"
                "        raise ValueError('total')\n"
                "    return -(-total // per_page)\n"
            ),
        ),
    )


# ── performance constraint ──────────────────────────────────────────────────
#
# "Correct but quadratic" is invisible to a single-case test and is exactly what
# a weak model produces when it reaches for `list.count` in a loop. The budget
# is stated in the task, so the requirement is not hidden, and the check runs
# LAST — the harness streams results to disk before each check, so a candidate
# killed by the timeout still keeps everything it satisfied before it.


def _t_top_k_fast(rng: random.Random) -> Task:
    size = rng.choice([120000, 160000, 200000])
    # MANY distinct values on purpose: counting with `items.count(x)` in a loop
    # is O(n × distinct), and only a large `distinct` makes that miss the budget.
    # With 500 distinct values the quadratic answer finished in about a second
    # (list.count runs at C speed) and the task measured nothing.
    distinct = rng.choice([18000, 24000])
    reference = (
        "def _dg_ref(items, k):\n"
        "    if k <= 0:\n"
        "        return []\n"
        "    counts = {}\n"
        "    for item in items:\n"
        "        counts[item] = counts.get(item, 0) + 1\n"
        "    ordered = sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))\n"
        "    return [value for value, _ in ordered[:k]]\n"
    )
    return Task(
        "top-k-fast", "deep", "performance",
        "Топ-k частых значений в срок",
        "Напиши функцию на Python `top_k(items, k)`, которая возвращает список из k самых часто "
        "встречающихся значений списка items. Порядок: сначала по убыванию частоты, при равной "
        "частоте — по возрастанию самого значения. Если различных значений меньше k — верни все. "
        "При k <= 0 верни пустой список.\n\n"
        "ВАЖНО: решение обязано обрабатывать список из %d элементов быстрее чем за 5 секунд. "
        "Подсчёт частоты перебором для каждого значения (`items.count(...)` внутри цикла) в этот "
        "срок не укладывается." % size,
        _py(
            reference,
            "top_k",
            [],
            checks=[
                check(
                    "contract", "функция top_k определена",
                    code="assert callable(top_k), 'нет функции top_k'", weight=0,
                ),
                check("basic", "обычный случай",
                      cases=[[["a", "b", "a", "c", "b", "a"], 2], [[1, 1, 2, 2, 3], 2]]),
                check("ties-by-value", "при равной частоте — меньшее значение раньше",
                      cases=[[[3, 1, 2, 3, 1, 2], 3], [["b", "a"], 2]]),
                check("k-larger-than-distinct", "k больше числа различных значений",
                      cases=[[[1, 2, 3], 10], [[], 3]]),
                check("non-positive-k", "k <= 0 даёт пустой список",
                      cases=[[[1, 2, 2], 0], [[1, 2, 2], -1]]),
                check(
                    "within-time-budget",
                    "укладывается в бюджет на %d элементах" % size,
                    code=(
                        "_dg_big = [(_i * 7919) %% %d for _i in range(%d)]\n"
                        "_dg_started = __import__('time').monotonic()\n"
                        "_dg_got = top_k(_dg_big, 10)\n"
                        "_dg_spent = __import__('time').monotonic() - _dg_started\n"
                        "assert _dg_got == _dg_ref(_dg_big, 10), 'неверный ответ на большом входе'\n"
                        "assert _dg_spent < 5.0, 'слишком медленно: %%.1f с' %% _dg_spent\n"
                        % (distinct, size)
                    ),
                    weight=2,
                ),
            ],
        ),
    )


@dataclass(frozen=True)
class TemplateGroup:
    level: str
    builders: list[Callable[[random.Random], Task]] = field(default_factory=list)


# Levels are graded by MEASURED difficulty, not by how the task feels to write.
# Two live runs (Gemini 3.1 Pro and gemini-3.6-flash) scored 24/24, and both
# draws were full of "implement the standard algorithm" tasks — so those moved
# down, and `deep` now means "the spec hinges on a rule people misremember".
TEMPLATES: dict[str, list[Callable[[random.Random], Task]]] = {
    "fast": [_t_unique_ordered, _t_chunk, _t_safe_div, _t_flatten_once, _t_roman],
    "normal": [
        _t_top_words, _t_natural_sort, _t_split_amount, _t_retry_delays,
        _t_window_max, _t_first_repeating, _t_fold_ranges, _t_base_convert,
        _t_parse_ini, _t_insert_index, _t_topo_sort, _t_lru_cache,
        _t_normalize_key, _t_dedup_by, _t_merge_intervals,
        _t_interval_intersection, _t_sql_dup_emails,
        # Demoted 2026-08-13 by MEASUREMENT, not opinion: every one of these was
        # answered perfectly by both arms in runs #4 and #5 (p = 1.0). A task
        # nobody fails cannot be a deep task, whatever it felt like to write.
        _t_allocate_weights, _t_next_business_day, _t_parse_csv_line,
        _t_parse_query, _t_round_half_up, _t_semver_compare,
    ],
    "deep": [
        # Kept: never observed solved, or observed FAILED (sql-streaks broke
        # both arms in run #4 — that is what a deep task looks like).
        _t_find_semver, _t_json_pointer, _t_deep_merge, _t_normalize_path,
        _t_sql_top_n, _t_sql_streaks, _t_sql_running_total, _t_cron_match,
        _t_semver_range, _t_min_rooms, _t_wildcard_match, _t_eval_expression,
        _t_iso_duration,
        # New classes (see the section comments): many interacting rules,
        # debug-from-a-failing-case, and a stated time budget.
        _t_validate_order, _t_apply_discounts, _t_fix_insert_point,
        _t_fix_pagination, _t_top_k_fast,
    ],
}

# Weighted toward the level that still measures something. Runs #4 and #5 gave
# 4/4 and 8/8 on the fast and normal tiers — eight of twelve slots of a
# ten-minute run spent on questions already answered. Still 12 rows in the
# printed table, as the owner asked.
LEVEL_MIX = {"fast": 2, "normal": 4, "deep": 6}
TASKS_PER_RUN = sum(LEVEL_MIX.values())
MAX_POINTS = sum(LEVEL_POINTS[level] * count for level, count in LEVEL_MIX.items())


_KNOWN_IDS: dict[str, str] | None = None
_BUILDER_IDS: dict[int, str] = {}
_BUILDER_CATEGORIES: dict[int, str] = {}


def _index_templates() -> None:
    """Builds one task per template, once, to learn the ids.

    The ids live inside the builders, so the only honest way to enumerate them
    is to build one of each — which also costs a few sqlite fixtures, hence the
    cache. Item statistics need this to report which templates have never been
    drawn (a sample covering two thirds of the pool must not read as if it
    covered all of it), and the weighted draw needs builder → id.
    """
    global _KNOWN_IDS
    if _KNOWN_IDS is not None:
        return
    rng = random.Random(0)
    known: dict[str, str] = {}
    for level, builders in TEMPLATES.items():
        for builder in builders:
            sample = builder(rng)
            known[sample.template_id] = level
            _BUILDER_IDS[id(builder)] = sample.template_id
            _BUILDER_CATEGORIES[id(builder)] = sample.category
    _KNOWN_IDS = known


def known_template_ids() -> dict[str, str]:
    """{template id: level} for the whole pool, built once."""
    _index_templates()
    return dict(_KNOWN_IDS or {})


def template_id_of(builder: Callable[[random.Random], Task]) -> str:
    _index_templates()
    return _BUILDER_IDS.get(id(builder), "")


def template_category_of(builder: Callable[[random.Random], Task]) -> str:
    _index_templates()
    return _BUILDER_CATEGORIES.get(id(builder), "")


# An item nobody has ever failed still gets drawn sometimes — the measurement
# has to be able to change its mind — but it competes at a tenth of the weight
# of one that keeps producing failures.
UNKNOWN_DIFFICULTY = 0.5
MIN_DRAW_WEIGHT = 0.1

# What to assume about a template NOBODY HAS MEASURED YET. Treating "never
# drawn" as one bucket was a real mistake: run #6 put twelve unmeasured legacy
# templates in the same bucket as the five written specifically to break a
# model, so the new classes got one of six deep slots and the run came back
# 28/28 again. Five runs of ceilings are evidence about the legacy classes;
# the new ones deserve the opposite prior. ONE recorded observation replaces
# either of them.
CATEGORY_PRIOR = {
    "code": 0.9,
    "sql": 0.9,
    "spec": 0.35,
    "debug": 0.35,
    "performance": 0.35,
}


def _draw_weight(
    template_id: str, category: str, difficulty: dict[str, float] | None
) -> float:
    if difficulty is None:
        return 1.0
    measured = difficulty.get(template_id)
    p_value = (
        float(measured)
        if measured is not None
        else CATEGORY_PRIOR.get(category, UNKNOWN_DIFFICULTY)
    )
    return max(MIN_DRAW_WEIGHT, 1.0 - p_value)


def _weighted_sample(rng: random.Random, pool: list[tuple], count: int) -> list:
    """Weighted draw WITHOUT replacement — a run must never ask the same
    template twice. Deterministic for a given rng and pool order."""
    remaining = list(pool)
    chosen = []
    while remaining and len(chosen) < count:
        total = sum(weight for _, weight in remaining)
        if total <= 0:
            chosen.append(remaining.pop(rng.randrange(len(remaining)))[0])
            continue
        target = rng.random() * total
        acc = 0.0
        picked = len(remaining) - 1
        for index, (_, weight) in enumerate(remaining):
            acc += weight
            if target <= acc:
                picked = index
                break
        chosen.append(remaining.pop(picked)[0])
    return chosen


def build_tasks(seed: int, difficulty: dict[str, float] | None = None) -> list[Task]:
    """Deterministic for a given seed, different for every new one.

    `difficulty` maps template id → measured pass share (`items.jsonl`, see
    `stats.difficulty_map`). Templates nobody ever fails are drawn far less
    often: runs #4 and #5 spent eight of twelve slots on tasks with p = 1.0,
    which is a ten-minute run measuring nothing. An EMPTY dict still weights the
    draw — by `CATEGORY_PRIOR`, which is the whole point on a fresh machine.
    Passing None keeps the plain uniform draw, so a seed alone still reproduces
    a run in tests.
    """
    rng = random.Random(seed)
    tasks: list[Task] = []
    for level, count in LEVEL_MIX.items():
        builders = TEMPLATES[level]
        if difficulty is not None:
            pool = [
                (
                    builder,
                    _draw_weight(
                        template_id_of(builder), template_category_of(builder), difficulty
                    ),
                )
                for builder in builders
            ]
            chosen = _weighted_sample(rng, pool, count)
        else:
            chosen = rng.sample(builders, min(count, len(builders)))
        while len(chosen) < count:
            chosen.append(rng.choice(builders))
        for builder in chosen:
            tasks.append(builder(rng))
    return tasks

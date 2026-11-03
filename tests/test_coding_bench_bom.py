"""The one static check (coding-bench/code_rules.py): BOM handling and the rules the old Delegator guard had."""
import os
import sys

BENCH = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "coding-bench"))
sys.path.insert(0, BENCH)

import code_rules  # noqa: E402

CODE = "import math\n\n\ndef f(x):\n    return math.sqrt(x)\n"


def _write(path, text, encoding="utf-8"):
    path.write_bytes(text.encode(encoding))
    return str(path)


def _check(tmp_path, text, task="routing", encoding="utf-8"):
    return code_rules.check_code(_write(tmp_path / "sol.py", text, encoding), task)


def test_a_bom_prefixed_solution_is_checked_like_the_same_file_without_one(tmp_path):
    for task in ("routing", "sat", "compress"):
        assert _check(tmp_path, CODE, task, "utf-8") is None
        assert _check(tmp_path, CODE, task, "utf-8-sig") is None


def test_a_bom_does_not_hide_a_real_violation(tmp_path):
    bad = _check(tmp_path, "import os\n", "routing", "utf-8-sig")
    assert bad is not None and "forbidden import" in bad


def test_what_the_old_guard_rejected_is_still_rejected_for_routing_and_sat(tmp_path):
    cases = ["import math\nx = memoryview(b'a')\n",
             "import math\nopen('x')\n",
             "import sys\nsys.stdout.write('x')\n",
             "import math\nx = getattr(math, 'pi')\n",
             "import math\n# peeks at hidden/ data\n",
             "import math\nS = 'run_info.json'\n",
             "import re\n"]
    for task in ("routing", "sat"):
        for text in cases:
            assert _check(tmp_path, text, task) is not None, (task, text)


def test_the_grader_data_text_rule_does_not_touch_compress(tmp_path):
    assert _check(tmp_path, "import math\n# trained on a corpus of logs\n", "compress") is None


def test_the_template_copy_is_byte_identical_to_the_graders(tmp_path):
    with open(os.path.join(BENCH, "code_rules.py"), "rb") as a, \
            open(os.path.join(BENCH, "template", "code_rules.py"), "rb") as b:
        assert a.read() == b.read()


def test_the_shipped_stubs_pass_their_own_rules():
    for task, name in (("routing", "routing.py"), ("sat", "solver.py"), ("compress", "codec.py")):
        assert code_rules.check_code(os.path.join(BENCH, "template", task, name), task) is None

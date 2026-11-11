"""Shape of the coding benchmark as shipped: version, weights, corpus sizes, installer coverage, old-grade tolerance."""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
BENCH = os.path.join(ROOT, "coding-bench")
sys.path.insert(0, BENCH)

import grade_run  # noqa: E402
import start  # noqa: E402


def test_version_and_weights_are_the_v17_ones():
    assert grade_run.VERSION == "1.7" and start.BENCH_VERSION == "1.7"
    weights = {task: spec[0] for task, spec in grade_run.TASKS.items()}
    assert weights == {"routing": 35, "compress": 35, "sat": 30} and sum(weights.values()) == 100
    assert grade_run.REPEATS == {"routing": 3, "compress": 1, "sat": 3}


def test_the_hidden_data_is_the_v17_corpus():
    with open(os.path.join(BENCH, "hidden", "sat", "index.json"), encoding="utf-8") as fh:
        index = json.load(fh)
    assert len(index) == 41
    for item in index:
        assert os.path.isfile(os.path.join(BENCH, "hidden", "sat", "instances", item["file"]))
    assert len(os.listdir(os.path.join(BENCH, "hidden", "compress", "corpus"))) == 9
    with open(os.path.join(BENCH, "hidden", "routing", "instances.json"), encoding="utf-8") as fh:
        assert len(json.load(fh)) == 8


def test_every_shipped_benchmark_file_has_an_installer_line_and_no_line_is_dangling():
    with open(os.path.join(ROOT, "installer", "Delegator.iss"), encoding="utf-8-sig") as fh:
        wanted = set(re.findall(r'Source: "\.\.\\coding-bench\\([^"]+)"', fh.read()))
    wanted = {path.replace("\\", "/") for path in wanted}
    on_disk = set()
    for folder, dirs, names in os.walk(BENCH):
        dirs[:] = [d for d in dirs if d not in ("__pycache__", "runs_archive")]
        on_disk.update(os.path.relpath(os.path.join(folder, n), BENCH).replace("\\", "/") for n in names)
    assert on_disk - wanted == set(), "files without an installer line"
    assert wanted - on_disk == set(), "installer lines without a file"


def test_the_grader_pre_scan_names_a_violation_and_skips_the_scorer(tmp_path):
    task_dir = tmp_path / "sat"
    task_dir.mkdir()
    (task_dir / "solver.py").write_text("import os\n", encoding="utf-8")
    result = grade_run.run_scorer("sat", str(task_dir))
    assert result["score"] == 0.0 and result["max"] == 30
    assert result["detail"]["violation"].startswith("forbidden import")


def test_summary_ignores_grades_of_other_versions_and_reads_both_arms(tmp_path):
    def grade(folder, name, version, mode):
        d = tmp_path / folder
        d.mkdir(parents=True, exist_ok=True)
        tasks = {t: {"score": 1.0, "max": m, "note": "", "detail": {}} for t, m in
                 (("routing", 35), ("compress", 35), ("sat", 30))}
        (d / ("%s__v%s__grade.json" % (name, version))).write_text(json.dumps(
            {"run": name, "model": "m", "mode": mode, "bench_version": version, "total": 3.0, "tasks": tasks,
             "minutes": 1, "calibration_error": None, "flags": []}), encoding="utf-8")
    grade("m/native", "native-m-1", "1.7", "native")
    grade("m/delegator", "delegator-m-1", "1.7", "delegator")
    grade("m/native", "native-m-0", "1.5", "native")  # an old grade: not in the v1.7 table, must not crash it
    grade_run.summary(str(tmp_path), "1.7")
    text = (tmp_path / "SUMMARY_v1.7.md").read_text(encoding="utf-8")
    assert "native-m-1" in text and "delegator-m-1" in text and "native-m-0" not in text

import json
from pathlib import Path
import shutil
import subprocess

import pytest


def test_rendered_links_only_use_safe_schemes():
    node = shutil.which("node")
    if not node:
        pytest.skip("Node.js is needed to execute the browser URL sanitizer")
    source = (Path(__file__).resolve().parents[1] / "delegator_core/static/app.js").read_text()
    sanitizer = source[source.index("function normalizeHref("):source.index("function appendTextNode(")]
    script = "const window = {location: {href: 'http://127.0.0.1:1380/'}};\n" + sanitizer + "\n"
    script += "const inputs = " + json.dumps([
        "javascript:alert(1)", "JaVaScRiPt:alert(1)", "java\nscript:alert(1)",
        "data:text/html,<script>alert(1)</script>", "vbscript:msgbox(1)",
        "https://example.com/docs", "mailto:dev@example.com", "/api/uploads/a/content",
        "C:\\Users\\Public\\notes.txt",
    ]) + "; console.log(JSON.stringify(inputs.map(normalizeHref)));"
    result = subprocess.run([node, "-"], input=script, text=True, capture_output=True, check=True)
    links = json.loads(result.stdout)
    assert links[:5] == ["#"] * 5
    assert links[5:] == [
        "https://example.com/docs", "mailto:dev@example.com",
        "http://127.0.0.1:1380/api/uploads/a/content", "file:///C:/Users/Public/notes.txt",
    ]

import json

from delegator_core.providers.gemini_web import gemini_web_flags


def test_flags_follow_config(tmp_path, monkeypatch):
    cfg = tmp_path / "config.json"
    monkeypatch.setenv("DELEGATOR_CONFIG_FILE", str(cfg))
    assert gemini_web_flags() == (False, True)  # no file
    cfg.write_text(json.dumps({"gemini_web_enabled": True, "delegator_enabled": False}), encoding="utf-8-sig")
    assert gemini_web_flags() == (True, False)
    cfg.write_text("{}", encoding="utf-8")
    assert gemini_web_flags() == (False, True)

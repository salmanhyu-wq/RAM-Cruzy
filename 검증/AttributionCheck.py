"""Check exact attribution and profile connection using disposable databases."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "연결"))
from request_identity import match_request, text_content
import setup


def database(home, profile, session, text, model="local/model-one", ended=None):
    home.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(home / "state.db") as db:
        db.executescript("CREATE TABLE sessions(id TEXT PRIMARY KEY,profile_name TEXT,source TEXT,model TEXT,ended_at REAL); CREATE TABLE messages(session_id TEXT,role TEXT,content TEXT,timestamp REAL);")
        db.execute("INSERT INTO sessions VALUES(?,?,?,?,?)", (session, profile, "tool", model, ended))
        db.execute("INSERT INTO messages VALUES(?,?,?,?)", (session, "user", text, time.time()))


with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp) / ".hermes"
    needle = "이것은 실제 대화 요청을 정확하게 대조하는 한국어 검증 문장입니다."
    database(base / "profiles/one", "one", "chat-1", needle)
    body = {"model": "model-one", "messages": [{"role": "user", "content": needle}]}
    match = match_request(body, base)
    assert match["profile"] == "one" and match["session"] == "chat-1" and match["scope"] == "profiles"
    assert match["attribution"] == "message_match"
    assert not match_request({**body, "model": "other-model"}, base)
    assert not match_request({"messages": [{"role": "user", "content": "계속해"}]}, base)
    database(base / "office-runtime/profiles/one", "custom", "chat-2", needle)
    assert not match_request(body, base), "Ambiguous matches must not name a caller"
    with sqlite3.connect(base / "profiles/one/state.db") as db:
        db.execute("UPDATE sessions SET ended_at=?", (time.time(),))
    match = match_request(body, base)
    assert match["scope"] == "office" and match["session"] == "chat-2"
    assert match["client"] == "Paperclip → Hermes"
    assert text_content('[{"type":"text","text":"대화"}]') == "대화"
    spec = importlib.util.spec_from_file_location("identity_plugin", ROOT / "연결/Hermes/ai-ram-manager/__init__.py")
    plugin = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(plugin)
    with patch("pathlib.Path.home", return_value=Path(tmp)), patch("hermes_constants.get_hermes_home", return_value=base / "office-runtime/profiles/one"):
        payload = plugin.attach_identity({}, "http://127.0.0.1:8002/bot/v1", "chat-2", "turn")
        assert payload["request"]["extra_headers"]["X-AIRAM-Scope"] == plugin.encode("office")
        assert plugin.attach_identity({}, "https://example.com:8002/v1", "chat-2", "turn") is None
    # Include per-chat model changes and JSON runtime profiles without converting their format.
    for folder in [base, base / "profiles/one", base / "office-runtime/profiles/one"]:
        (folder / "config.yaml").write_text(json.dumps({"model": {"provider": "remote"}, "plugins": {"enabled": []}}))
    with patch.object(setup, "HOME", Path(tmp)), patch.object(setup, "HERMES", base):
        changed = setup.configure_plugin(True)
        assert len(changed) == 3
        for config in setup.profiles():
            assert "ai-ram-manager" in json.loads(config.read_text())["plugins"]["enabled"]
            assert (config.parent / "plugins/ai-ram-manager").is_symlink()
        assert setup.configure_plugin(True) == []
        assert len(setup.configure_plugin(False)) == 3
print("앱·봇·세션 식별, 회사 프로필 분리, 중복 대화 거부, JSON 설정 보존과 재연결 검증 통과")

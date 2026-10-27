"""Admin settings + queue tests — no GPU, scheduler, or network needed.

Covers INTEGRATION2.md: settings validation (unknown values -> 422),
hot-reload via the scheduler's provider hook (read_server_settings), and
queue controls against a fake scheduler dir. Auth is faked by overriding
require_user; IAM flag and data dir are monkeypatched per test.
"""
import json
import os

import pytest
from fastapi.testclient import TestClient

import server.config as cfg
from server import auth
from server.main import app


@pytest.fixture()
def admin_env(tmp_path, monkeypatch):
    out = tmp_path / "output"
    up = tmp_path / "uploads"
    out.mkdir()
    up.mkdir()
    monkeypatch.setattr(cfg, "OUTPUT_DIR", str(out))
    monkeypatch.setattr(cfg, "UPLOAD_DIR", str(up))
    monkeypatch.setattr(cfg, "JOBS_DB_PATH", str(tmp_path / "jobs.sqlite3"))
    monkeypatch.setenv("FIREBRAT_IAM", "1")
    monkeypatch.delenv("FIREBRAT_ALLOWED_USER_IDS", raising=False)
    monkeypatch.delenv("FIREBRAT_ADMIN_EMAILS", raising=False)
    monkeypatch.setitem(app.dependency_overrides, auth.require_user,
                        lambda: {"uid": "root", "email": "root@x.com",
                                 "email_verified": True, "name": "Root"})
    yield tmp_path


def _login(monkeypatch, uid, email, verified=True):
    monkeypatch.setitem(app.dependency_overrides, auth.require_user,
                        lambda: {"uid": uid, "email": email,
                                 "email_verified": verified})


def _client():
    return TestClient(app, raise_server_exceptions=False)


@pytest.fixture()
def admin_client(admin_env, monkeypatch):
    from server import iam
    code = iam.ensure_setup_code()
    with _client() as client:
        assert client.post("/admin/bootstrap", json={"code": code}).status_code == 200
        yield client


def test_admin_settings_shape_and_auth(admin_client, admin_env, monkeypatch):
    body = admin_client.get("/admin/settings").json()
    assert set(body) == {"values", "options", "availability", "notes"}
    assert body["values"]["llm"]["model"] == "qwen3.5-9b"
    models = body["options"]["llm"]["models"]
    assert {m["id"] for m in models} == {"qwen3.5-9b", "qwen3.5-4b"}
    for m in models:
        assert {"vram_gb", "description", "available"} <= set(m)
    assert {e["id"] for e in body["options"]["tts"]["engines"]} == {
        "qwen3-tts-1.7b", "qwen3-tts-0.6b", "chatterbox"}
    # Non-admin is forbidden, anonymous is unauthorized.
    _login(monkeypatch, "nobody", "n@x.com", True)
    assert admin_client.get("/admin/settings").status_code == 403
    app.dependency_overrides.clear()
    try:
        assert _client().get("/admin/settings").status_code == 401
    finally:
        _login(monkeypatch, "root", "root@x.com", True)


@pytest.mark.parametrize("patch", [
    {"llm": {"model": "gpt-99"}},
    {"llm": {"quantization": "int4"}},
    {"tts": {"engine": "elevenlabs"}},
    {"run_pattern": {"phase_mode": "turbo"}},
    {"run_pattern": {"max_books_per_llm_phase": 99}},
    {"run_pattern": {"max_books_per_llm_phase": "many"}},
    {"run_pattern": {"audio_order": "longest_first"}},
    {"run_pattern": {"paused": "yes"}},
    {"run_pattern": {"quiet_hours": {"start": "25:00", "end": "06:00"}}},
    {"run_pattern": {"quiet_hours": "night"}},
    {"limits": {"max_upload_mb": -1}},
    {"limits": {"max_cast_chars": 5}},
    {"nope": {}},
    {"llm": {"model": "qwen3.5-9b", "bogus": 1}},
])
def test_settings_validation_rejects(admin_client, patch):
    assert admin_client.put("/admin/settings", json=patch).status_code == 422


def test_settings_roundtrip_and_hot_reload(admin_client, admin_env):
    from server import server_settings as _ss
    patch = {"llm": {"model": "qwen3.5-4b"},
             "run_pattern": {"phase_mode": "sequential",
                             "max_books_per_llm_phase": 2,
                             "audio_order": "fifo", "paused": True,
                             "quiet_hours": {"start": "22:00", "end": "06:00"}},
             "limits": {"max_upload_mb": 100, "max_cast_chars": 50000}}
    r = admin_client.put("/admin/settings", json=patch)
    assert r.status_code == 200, r.text
    assert r.json()["values"]["run_pattern"]["paused"] is True
    # The scheduler's hot-reload hook sees the same values, no restart.
    snap = _ss.read_server_settings()
    assert snap["llm"]["model"] == "qwen3.5-4b"
    assert snap["run_pattern"]["quiet_hours"] == {"start": "22:00", "end": "06:00"}
    assert snap["limits"]["max_upload_mb"] == 100
    # Atomic file on disk.
    stored = json.load(open(_ss.SETTINGS_PATH()))
    assert stored == snap


def test_settings_invalid_file_falls_back(admin_client, admin_env):
    from server import server_settings as _ss
    with open(_ss.SETTINGS_PATH(), "w") as f:
        f.write('{"llm": {"model": "nope"}}')
    assert _ss.read_server_settings()["llm"]["model"] == "qwen3.5-9b"


def test_single_catalog_used_for_options_and_validation(admin_client):
    """Decision 4: server_settings reads firebrat_cast.catalog only."""
    from firebrat_cast import catalog
    from server import server_settings as _ss
    opts = _ss.build_options()
    assert [m["id"] for m in opts["llm"]["models"]] == list(catalog.LLM_MODELS)
    assert [e["id"] for e in opts["tts"]["engines"]] == list(catalog.TTS_ENGINES)
    for entry in opts["llm"]["models"] + opts["tts"]["engines"]:
        assert {"id", "vram_gb", "description", "available"} <= set(entry)
    vals = _ss.read_server_settings()
    assert vals["run_pattern"] == {"phase_mode": "batched", "max_books_per_llm_phase": 4,
                                   "audio_order": "shortest_first", "paused": False,
                                   "quiet_hours": None}
    assert _ss.validate_values(vals) == vals


def test_available_means_weights_in_hf_hub(admin_client, tmp_path, monkeypatch):
    from server import server_settings as _ss
    monkeypatch.setenv("HF_HOME", str(tmp_path / "hf"))
    snap = tmp_path / "hf" / "hub" / "models--Qwen--Qwen3.5-9B" / "snapshots" / "abc"
    snap.mkdir(parents=True)
    avail = {m["id"]: m["available"] for m in _ss.build_options()["llm"]["models"]}
    assert avail == {"qwen3.5-9b": True, "qwen3.5-4b": False}


def test_settings_file_is_what_scheduler_gets(admin_client, admin_env, monkeypatch):
    """cast_bridge exports FIREBRAT_SETTINGS_FILE = the file the PUT wrote,
    and the scheduler reads it back (hot reload end to end)."""
    from firebrat_cast import scheduler as sch
    from server import cast_bridge
    body = admin_client.get("/admin/settings").json()["values"]
    body["llm"]["model"] = "qwen3.5-4b"
    body["run_pattern"]["quiet_hours"] = {"start": "22:00", "end": "06:00"}
    assert admin_client.put("/admin/settings", json={"values": body}).status_code == 200
    env = cast_bridge.build_env()
    path = env["FIREBRAT_SETTINGS_FILE"]
    assert path == str(admin_env / "server_settings.json") and os.path.isfile(path)
    assert not [f for f in os.listdir(admin_env) if f.endswith(".tmp")]
    monkeypatch.setenv("FIREBRAT_SETTINGS_FILE", path)
    cfg2 = sch.SchedulerConfig(root=str(admin_env / "elsewhere"))
    sch.refresh_settings(cfg2)
    assert cfg2.served_name == "qwen3.5-4b"
    assert cfg2.quiet_hours == {"start": "22:00", "end": "06:00"}


def test_cancel_and_priority_write_scheduler_controls(admin_client, admin_env, monkeypatch):
    from server import jobs as _jobs
    root = admin_env / "cast"
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(root))
    (root / "inbox").mkdir(parents=True)
    (root / "inbox" / "tale.json").write_text("{}")
    _jobs.create_job(book_id="tale", filename="t.epub", title="T",
                     pdf_path="/tmp/t.epub", content_mode="cast", owner_uid="root")
    r = admin_client.post("/admin/queue/tale/priority", json={"top": True})
    assert r.status_code == 200, r.text
    assert json.loads((root / "priority.json").read_text()) == {"top": ["tale"]}
    assert admin_client.post("/admin/queue/tale/cancel").status_code == 200
    assert (root / "cancel" / "tale").exists()
    from server import iam
    acts = [a["action"] for a in iam.list_audit(20)]
    assert "queue_priority" in acts and "queue_cancel" in acts


def test_admin_endpoints_need_admin(admin_client, monkeypatch):
    from server import iam
    admin_client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
    _login(monkeypatch, "u", "u@x.com")
    assert admin_client.get("/me").json()["role"] == "user"
    for method, url in (("get", "/admin/settings"), ("get", "/admin/queue"),
                        ("get", "/admin/audit"), ("get", "/admin/users"),
                        ("post", "/admin/queue/pause")):
        assert getattr(admin_client, method)(url).status_code == 403, url
    assert admin_client.put("/admin/settings", json={"values": {}}).status_code == 403
    assert iam.get_user("u")["role"] == "user"


def test_queue_pause_resume_and_empty(admin_client, admin_env, monkeypatch):
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(admin_env / "cast"))
    q = admin_client.get("/admin/queue").json()
    assert set(q) == {"scheduler", "paused"}
    assert q["scheduler"]["books"] == [] and q["paused"] is False
    assert admin_client.post("/admin/queue/pause").json() == {"paused": True}
    assert admin_client.get("/admin/queue").json()["paused"] is True
    assert admin_client.post("/admin/queue/resume").json() == {"paused": False}
    from server import iam
    assert "settings_update" in [a["action"] for a in iam.list_audit(10)]


def test_queue_with_fake_scheduler(admin_client, admin_env, monkeypatch):
    from server import jobs as _jobs
    root = admin_env / "cast"
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(root))
    (root / "jobs" / "tale").mkdir(parents=True)
    (root / "jobs" / "tale" / "state.json").write_text(
        json.dumps({"slug": "tale", "stage": "synth", "status": "running"}))
    (root / "scheduler_status.json").write_text(json.dumps({"detail": "busy"}))
    (root / "inbox").mkdir()
    (root / "inbox" / "tale.json").write_text("{}")
    _jobs.create_job(book_id="tale", filename="tale.epub", title="Tale",
                     pdf_path="/tmp/tale.epub", content_mode="cast",
                     owner_uid="root")
    q = admin_client.get("/admin/queue").json()
    stages = {b["slug"]: b["stage"] for b in q["scheduler"]["books"]}
    assert stages.get("tale") == "recording voices"
    # Cancel drops the inbox entry and flags the job; unknown slugs 404.
    r = admin_client.post("/admin/queue/tale/cancel")
    assert r.status_code == 200 and r.json()["removed_inbox"] is True
    assert not (root / "inbox" / "tale.json").exists()
    assert _jobs.latest_job_for_book("tale")["state"] == "cancelled"
    assert admin_client.post("/admin/queue/ghost/cancel").status_code == 404
    assert admin_client.post("/admin/queue/tale/priority",
                             json={"top": False}).status_code == 422


def test_queue_priority_moves_queued_job(admin_client, admin_env, monkeypatch):
    from server import jobs as _jobs
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(admin_env / "cast"))
    _jobs.create_job(book_id="slow-book", filename="s.pdf", title="Slow",
                     pdf_path="/tmp/s.pdf", owner_uid="root")
    r = admin_client.post("/admin/queue/slow-book/priority", json={"top": True})
    assert r.status_code == 200, r.text
    assert r.json()["job_id"] == _jobs.latest_job_for_book("slow-book")["job_id"]
    assert admin_client.post("/admin/queue/nope/priority",
                             json={"top": True}).status_code == 404

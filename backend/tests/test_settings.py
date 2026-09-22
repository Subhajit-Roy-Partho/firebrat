"""Settings + per-job options + web UI: the external-user surface.

Covers: GET /settings shape (presets, gpu, workers), POST /settings
persistence + validation, job rows carrying provider/chunk_pages, and the
static web UI served at / with its JS/CSS. Auth: conftest.py already
installs the test-user bypass, so these exercise logic, not tokens.
"""
import tempfile

from fastapi.testclient import TestClient

import server.config as cfg
from server import storage


def _client(tmpdir):
    from server.main import app
    return TestClient(app, raise_server_exceptions=False)


def test_settings_roundtrip_and_validation():
    with tempfile.TemporaryDirectory() as tmpdir:
        orig_out, orig_db = cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH
        cfg.OUTPUT_DIR = tmpdir
        cfg.JOBS_DB_PATH = f"{tmpdir}/jobs.sqlite3"
        try:
            client = _client(tmpdir)
            s = client.get("/settings").json()
            assert s["default_provider"] == "nanogpt"
            assert "qwen3-4b" in s["presets"]
            assert "qwen3-1.7b" in s["presets"]
            assert "gpu" in s and "max_concurrent_jobs" in s

            bad = client.post("/settings", json={
                "default_provider": "wat", "local_model_preset": "nope",
            }).json()
            assert bad["default_provider"] == "nanogpt"
            assert bad["local_model_preset"] == "qwen3-4b"

            ok = client.post("/settings", json={
                "default_provider": "local", "default_chunk_pages": 2,
                "local_model_preset": "qwen3-1.7b",
            }).json()
            assert ok["default_provider"] == "local"
            assert ok["local_model_preset"] == "qwen3-1.7b"
            again = client.get("/settings").json()
            assert again["default_provider"] == "local"
            assert again["default_chunk_pages"] == 2
        finally:
            cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH = orig_out, orig_db
            storage._zip_cache.clear()


def test_upload_accepts_provider_options():
    from server import jobs
    with tempfile.TemporaryDirectory() as tmpdir:
        orig_out, orig_db = cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH
        orig_up = getattr(cfg, "UPLOAD_DIR", None)
        cfg.OUTPUT_DIR = tmpdir
        cfg.JOBS_DB_PATH = f"{tmpdir}/jobs.sqlite3"
        cfg.UPLOAD_DIR = f"{tmpdir}/uploads"
        try:
            client = _client(tmpdir)
            pdf = b"%PDF-1.4 fake" + b"0" * 100
            r = client.post("/books/upload", files={"file": ("t.pdf", pdf)},
                            data={"provider": "local", "chunk_pages": "2"})
            assert r.status_code == 200, r.text[:200]
            body = r.json()
            assert body["provider"] == "local"
            assert body["chunk_pages"] == 2
            # unknown provider falls back instead of breaking the queue
            r2 = client.post("/books/upload", files={"file": ("u.pdf", pdf)},
                             data={"provider": "wat"})
            assert r2.json()["provider"] == "nanogpt"
            # default listing carries the new columns
            ids = {j["job_id"] for j in client.get("/jobs").json()}
            assert body["job_id"] in ids
        finally:
            cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH = orig_out, orig_db
            if orig_up is not None:
                cfg.UPLOAD_DIR = orig_up
            storage._zip_cache.clear()


def test_web_ui_served():
    with tempfile.TemporaryDirectory() as tmpdir:
        orig = cfg.OUTPUT_DIR
        cfg.OUTPUT_DIR = tmpdir
        try:
            client = _client(tmpdir)
            index = client.get("/")
            assert index.status_code == 200
            assert "Firebrat Server" in index.text
            assert "/static/app.js" in index.text
            js = client.get("/static/app.js")
            assert js.status_code == 200 and "authedFetch" in js.text
            fb = client.get("/firebase-config").json()
            assert fb["projectId"] == "firebrat-8c597"
        finally:
            cfg.OUTPUT_DIR = orig
            storage._zip_cache.clear()

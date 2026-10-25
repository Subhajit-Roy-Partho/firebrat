"""GET /models picker + per-job model override. No GPU or network needed.

Covers: /models 401 unsigned, 200 shape (providers, cloud models incl.
/free fallback chain, local presets, gpu, default_provider, live list
fallback that never 500s), upload accepting an optional model override,
and job_runner mapping that override onto the subprocess env.
"""
import os
import tempfile

from fastapi.testclient import TestClient

import server.config as cfg
from server import auth, storage
from server.main import app


def _authed_client():
    return TestClient(app, raise_server_exceptions=False)


def test_models_requires_auth():
    app.dependency_overrides.clear()
    try:
        client = TestClient(app, raise_server_exceptions=False)
        assert client.get("/models").status_code == 401
        assert client.get("/models?provider=local").status_code == 401
    finally:
        app.dependency_overrides[auth.require_user] = lambda: {
            "uid": "test-user",
            "email": "test@example.com",
        }


def test_models_shape_and_fallback(monkeypatch):
    with tempfile.TemporaryDirectory() as tmpdir:
        orig_db = cfg.JOBS_DB_PATH
        cfg.JOBS_DB_PATH = f"{tmpdir}/jobs.sqlite3"
        # Force the live proxy to fail: unreachable base => env fallback.
        monkeypatch.setenv("NANO_API_URL", "http://127.0.0.1:9/v1")
        monkeypatch.delenv("FIREBRAT_SPARK_MODEL", raising=False)
        monkeypatch.delenv("FIREBRAT_DEEPSEEK_MODEL", raising=False)
        try:
            body = _authed_client().get("/models").json()
            assert body["providers"] == ["nanogpt", "local"]
            assert body["default_provider"] == "nanogpt"
            assert "nvidia/nemotron-3-super-120b-a12b:free" in body["cloud_models"]
            assert "google/gemma-4-31b-it:free" in body["cloud_models"]
            assert body["cloud_model_default"] == "z-ai/glm-5.3-flash"
            assert "qwen3-4b" in body["presets"]
            assert "qwen3-4b" in body["local_presets"]
            assert "gpu" in body
            # Proxy failed => env list, flagged — never a 500.
            assert body["live_ok"] is False
            assert body["live_models"] == body["cloud_models"]
            # Unknown provider normalizes instead of erroring.
            assert _authed_client().get("/models?provider=wat").json()["provider"] == "nanogpt"
            assert _authed_client().get("/models?provider=local").json()["provider"] == "local"
        finally:
            cfg.JOBS_DB_PATH = orig_db
            storage._zip_cache.clear()


def test_upload_model_override_echoed():
    with tempfile.TemporaryDirectory() as tmpdir:
        orig_out, orig_db = cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH
        orig_up = getattr(cfg, "UPLOAD_DIR", None)
        cfg.OUTPUT_DIR = tmpdir
        cfg.JOBS_DB_PATH = f"{tmpdir}/jobs.sqlite3"
        cfg.UPLOAD_DIR = f"{tmpdir}/uploads"
        try:
            client = _authed_client()
            pdf = b"%PDF-1.4 fake" + b"0" * 100
            r = client.post("/books/upload", files={"file": ("m.pdf", pdf)},
                            data={"model": "nvidia/nemotron-3-super-120b-a12b:free"})
            assert r.status_code == 200, r.text[:200]
            assert r.json()["model"] == "nvidia/nemotron-3-super-120b-a12b:free"
            # Omitted model preserves the env default (empty string).
            r2 = client.post("/books/upload", files={"file": ("n.pdf", pdf)})
            assert r2.status_code == 200, r2.text[:200]
            assert r2.json()["model"] == ""
        finally:
            cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH = orig_out, orig_db
            if orig_up is not None:
                cfg.UPLOAD_DIR = orig_up
            storage._zip_cache.clear()


def test_job_runner_honors_model_override(monkeypatch):
    """_run_job maps job["model"] onto both tier env vars; empty keeps env."""
    import subprocess
    import server.job_runner as runner
    import server.jobs as jobs_module

    with tempfile.TemporaryDirectory() as tmpdir:
        orig_out, orig_db = cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH
        cfg.OUTPUT_DIR = tmpdir
        cfg.JOBS_DB_PATH = f"{tmpdir}/jobs.sqlite3"
        monkeypatch.setenv("FIREBRAT_SPARK_MODEL", "env-default")
        captured: dict = {}

        def fake_run(cmd, **kwargs):
            captured.update(kwargs.get("env", {}))

            class _FakeProc:
                def wait(self):
                    return 0

            return _FakeProc()

        monkeypatch.setattr(runner.subprocess, "Popen", fake_run)
        try:
            pdf = os.path.join(tmpdir, "b.pdf")
            open(pdf, "wb").write(b"%PDF-1.4 fake")
            jid = jobs_module.create_job(
                book_id="bk", filename="b.pdf", title="B", pdf_path=pdf,
                model="nvidia/nemotron-3-super-120b-a12b:free")
            runner._run_job(jid, [])
            assert captured.get("FIREBRAT_SPARK_MODEL") == "nvidia/nemotron-3-super-120b-a12b:free"
            assert captured.get("FIREBRAT_DEEPSEEK_MODEL") == "nvidia/nemotron-3-super-120b-a12b:free"

            captured.clear()
            jid2 = jobs_module.create_job(
                book_id="bk2", filename="b.pdf", title="B", pdf_path=pdf)
            runner._run_job(jid2, [])
            assert captured.get("FIREBRAT_SPARK_MODEL") == "env-default"
            assert "FIREBRAT_DEEPSEEK_MODEL" not in captured
        finally:
            cfg.OUTPUT_DIR, cfg.JOBS_DB_PATH = orig_out, orig_db
            storage._zip_cache.clear()

"""Upload/status/retry job-queue tests — no GPU or network needed. A fake
convert.py stand-in is used instead of the real pipeline so this stays fast
and deterministic; it exercises the same CLI contract (argv shape, status.json
writes) the real one honors.
"""
import json
import os
import sys
import textwrap
import time


_FAKE_CONVERT_PY = textwrap.dedent(
    """
    import argparse, json, os, sys, time

    p = argparse.ArgumentParser()
    p.add_argument("pdf")
    p.add_argument("--output", required=True)
    p.add_argument("--book-id", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--skip-extraction", action="store_true")
    p.add_argument("--retry-failed", action="store_true")
    args = p.parse_args()

    pkg_dir = os.path.join(args.output, args.book_id)
    os.makedirs(pkg_dir, exist_ok=True)

    behavior = os.environ.get("FAKE_CONVERT_BEHAVIOR", "succeed")
    if behavior == "fail" and not args.retry_failed:
        with open(os.path.join(pkg_dir, "status.json"), "w") as f:
            json.dump({"status": "failed", "stage": "compiling", "error": "simulated failure"}, f)
        sys.exit(1)

    manifest = {
        "schema_version": "1.0", "book_id": args.book_id, "title": args.title, "author": "",
        "source_pdf": os.path.basename(args.pdf), "generated_at": "2026-08-23T00:00:00Z",
        "pipeline_version": "0.1.0",
        "narrator_voice": {"engine": "chatterbox-tts", "model_class": "ChatterboxTTS", "sample_rate": 24000, "exaggeration": 0.4, "cfg_weight": 0.5},
        "audio_format": {"codec": "aac", "container": "m4a", "sample_rate": 24000, "channels": 1, "fallback_codec": "mp3"},
        "total_duration_ms": 0, "sections": [], "figures": [], "formulas": [], "tables": [],
    }
    with open(os.path.join(pkg_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f)
    with open(os.path.join(pkg_dir, "status.json"), "w") as f:
        json.dump({"status": "done", "stage": "done", "detail": "0 sections", "needs_review_count": 0}, f)
    sys.exit(0)
    """
)


def _wait_for(predicate, timeout=5.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def test_upload_status_retry_flow(tmp_path):
    fake_convert = tmp_path / "fake_convert.py"
    fake_convert.write_text(_FAKE_CONVERT_PY)

    output_dir = tmp_path / "output"
    upload_dir = tmp_path / "uploads"
    jobs_db = tmp_path / "jobs.sqlite3"
    output_dir.mkdir()

    import server.config as cfg
    cfg.OUTPUT_DIR = str(output_dir)
    cfg.UPLOAD_DIR = str(upload_dir)
    cfg.JOBS_DB_PATH = str(jobs_db)
    cfg.CONVERT_PY = sys.executable
    cfg.CONVERT_SCRIPT = str(fake_convert)
    cfg.MAX_CONCURRENT_JOBS = 1

    os.environ["FAKE_CONVERT_BEHAVIOR"] = "fail"

    from fastapi.testclient import TestClient
    from server.main import app

    with TestClient(app) as client:
        resp = client.post(
            "/books/upload",
            files={"file": ("mybook.pdf", b"%PDF-1.4 fake", "application/pdf")},
        )
        assert resp.status_code == 200, resp.text
        job = resp.json()
        assert job["book_id"] == "mybook"
        assert job["state"] in ("queued", "running", "failed")
        job_id = job["job_id"]

        assert _wait_for(lambda: client.get(f"/jobs/{job_id}").json()["state"] == "failed")
        failed = client.get(f"/jobs/{job_id}").json()
        assert failed["stage"] == "compiling"
        assert "simulated failure" in failed["error"]

        # not in /books yet — conversion never finished
        assert job["book_id"] not in [b["book_id"] for b in client.get("/books").json()]

        # non-pdf upload is rejected
        bad = client.post("/books/upload", files={"file": ("notes.txt", b"hi", "text/plain")})
        assert bad.status_code == 400

        # retry now succeeds
        os.environ["FAKE_CONVERT_BEHAVIOR"] = "succeed"
        retry_resp = client.post(f"/jobs/{job_id}/retry")
        assert retry_resp.status_code == 200, retry_resp.text
        assert retry_resp.json()["retry_count"] == 1

        assert _wait_for(lambda: client.get(f"/jobs/{job_id}").json()["state"] == "done")
        done = client.get(f"/jobs/{job_id}").json()
        assert done["stage"] == "done"
        assert done["error"] is None

        # now it shows up as a completed book
        books = client.get("/books").json()
        assert job["book_id"] in [b["book_id"] for b in books]

        # retrying a job that's already done is allowed (needs_review re-attempt)
        again = client.post(f"/jobs/{job_id}/retry")
        assert again.status_code == 200
        assert _wait_for(lambda: client.get(f"/jobs/{job_id}").json()["state"] == "done")

        # retrying an unknown job 404s
        assert client.post("/jobs/does-not-exist/retry").status_code == 404

        # resume only makes sense for a stuck queued/running job, not a done one
        assert client.post(f"/jobs/{job_id}/resume").status_code == 409
        assert client.post("/jobs/does-not-exist/resume").status_code == 404

        listing = client.get("/jobs").json()
        assert any(j["job_id"] == job_id for j in listing)


def test_orphaned_job_resumes_automatically_on_startup(tmp_path):
    """Simulates a server restart while a job was mid-flight: the job row
    is left saying "running" (nothing marked it otherwise), but no worker
    is actually processing it since this is a fresh process/queue. The
    lifespan startup hook should notice and requeue it without anyone
    calling /resume by hand.
    """
    fake_convert = tmp_path / "fake_convert.py"
    fake_convert.write_text(_FAKE_CONVERT_PY)

    output_dir = tmp_path / "output"
    upload_dir = tmp_path / "uploads"
    jobs_db = tmp_path / "jobs.sqlite3"
    output_dir.mkdir()
    upload_dir.mkdir()
    pdf_path = upload_dir / "orphan.pdf"
    pdf_path.write_bytes(b"%PDF-1.4 fake")

    import server.config as cfg
    cfg.OUTPUT_DIR = str(output_dir)
    cfg.UPLOAD_DIR = str(upload_dir)
    cfg.JOBS_DB_PATH = str(jobs_db)
    cfg.CONVERT_PY = sys.executable
    cfg.CONVERT_SCRIPT = str(fake_convert)
    cfg.MAX_CONCURRENT_JOBS = 1
    os.environ["FAKE_CONVERT_BEHAVIOR"] = "succeed"

    import server.jobs as jobs_module
    import server.job_runner as job_runner_module
    # Fresh module-level state — these guards exist so a real server only
    # scans/starts once per process, but that's exactly what breaks test
    # isolation when several "process lifetimes" run in the same pytest
    # session. A real restart always gets fresh globals; this test recreates
    # that condition on purpose.
    job_runner_module._workers_started = False
    job_runner_module._resumed_orphans = False

    orphan_job_id = jobs_module.create_job(
        book_id="orphanbook", filename="orphan.pdf", title="Orphan Book", pdf_path=str(pdf_path)
    )
    jobs_module.set_state(orphan_job_id, "running")  # as if the old process died mid-run

    from fastapi.testclient import TestClient
    from server.main import app

    with TestClient(app) as client:
        assert _wait_for(lambda: client.get(f"/jobs/{orphan_job_id}").json()["state"] == "done")
        assert "orphanbook" in [b["book_id"] for b in client.get("/books").json()]

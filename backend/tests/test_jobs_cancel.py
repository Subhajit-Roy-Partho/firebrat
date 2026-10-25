"""DELETE /jobs/{id} cancel/delete tests — no GPU or network needed.

Covers: 401 unsigned, 404 missing, queued cancel removing row + upload (+
never touching a sibling job's files), running cancel terminating the
subprocess and leaving the row `cancelled`, and the worker skipping a
cancelled job without running convert.py. `cancelled` is terminal by
design (see server/jobs.py) — not resumable, not retryable, never
re-enqueued after a restart.
"""
import os
import sys
import textwrap
import time

_SLEEP_CONVERT_PY = textwrap.dedent(
    """
    import argparse, time

    p = argparse.ArgumentParser()
    p.add_argument("pdf")
    p.add_argument("--output", required=True)
    p.add_argument("--book-id", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--skip-extraction", action="store_true")
    p.add_argument("--retry-failed", action="store_true")
    p.add_argument("--content-mode", default="illustrated")
    args = p.parse_args()

    time.sleep(30)
    """
)


def _configure(tmp_path, convert_source=None):
    fake_convert = tmp_path / "fake_convert.py"
    fake_convert.write_text(convert_source or "import sys; sys.exit(0)\n")

    output_dir = tmp_path / "output"
    upload_dir = tmp_path / "uploads"
    jobs_db = tmp_path / "jobs.sqlite3"
    output_dir.mkdir(exist_ok=True)
    upload_dir.mkdir(exist_ok=True)

    import server.config as cfg
    cfg.OUTPUT_DIR = str(output_dir)
    cfg.UPLOAD_DIR = str(upload_dir)
    cfg.JOBS_DB_PATH = str(jobs_db)
    cfg.CONVERT_PY = sys.executable
    cfg.CONVERT_SCRIPT = str(fake_convert)
    cfg.MAX_CONCURRENT_JOBS = 1
    return output_dir, upload_dir


def _wait_for(predicate, timeout=10.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


def test_delete_requires_auth(tmp_path):
    _configure(tmp_path)
    from server import auth
    from server.main import app

    saved = dict(app.dependency_overrides)
    app.dependency_overrides.clear()
    try:
        from fastapi.testclient import TestClient
        with TestClient(app, raise_server_exceptions=False) as client:
            assert client.delete("/jobs/anything").status_code == 401
    finally:
        app.dependency_overrides.update(saved)


def test_delete_missing_is_404(tmp_path):
    _configure(tmp_path)
    from fastapi.testclient import TestClient
    from server.main import app

    with TestClient(app) as client:
        resp = client.delete("/jobs/does-not-exist")
        assert resp.status_code == 404


def test_queued_delete_removes_row_upload_and_output(tmp_path):
    output_dir, upload_dir = _configure(tmp_path)
    from fastapi.testclient import TestClient
    from server import jobs as jobs_module
    from server.main import app

    with TestClient(app) as client:
        pdf = upload_dir / "doomed.pdf"
        pdf.write_bytes(b"%PDF-1.4 fake")
        pkg = output_dir / "doomed"
        pkg.mkdir()
        (pkg / "partial.txt").write_text("in-progress output")
        # Sibling job whose files must survive.
        other_pdf = upload_dir / "keeper.pdf"
        other_pdf.write_bytes(b"%PDF-1.4 fake")
        other_id = jobs_module.create_job(
            book_id="keeper", filename="keeper.pdf", title="Keeper", pdf_path=str(other_pdf))

        job_id = jobs_module.create_job(
            book_id="doomed", filename="doomed.pdf", title="Doomed", pdf_path=str(pdf))

        resp = client.delete(f"/jobs/{job_id}")
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["deleted"] is True

        assert client.get(f"/jobs/{job_id}").status_code == 404
        assert jobs_module.get_job(job_id) is None
        assert not pdf.exists()
        assert not pkg.exists()
        # Untouched sibling.
        assert jobs_module.get_job(other_id) is not None
        assert other_pdf.exists()


def test_running_cancel_marks_cancelled_and_kills_subprocess(tmp_path):
    _configure(tmp_path, convert_source=_SLEEP_CONVERT_PY)
    from fastapi.testclient import TestClient
    from server import job_runner as job_runner_module
    from server.main import app

    job_runner_module._workers_started = False
    job_runner_module._resumed_orphans = False

    with TestClient(app) as client:
        resp = client.post(
            "/books/upload",
            files={"file": ("slowbook.pdf", b"%PDF-1.4 fake", "application/pdf")},
        )
        assert resp.status_code == 200, resp.text
        job_id = resp.json()["job_id"]

        assert _wait_for(lambda: client.get(f"/jobs/{job_id}").json()["state"] == "running")
        assert job_runner_module.cancel_running("no-such-job") is False

        del_resp = client.delete(f"/jobs/{job_id}")
        assert del_resp.status_code == 200, del_resp.text
        assert del_resp.json()["state"] == "cancelled"

        # Worker must keep the terminal state, not flip to failed from the
        # SIGTERM exit code — and the row stays (only files/rows of queued
        # deletes are forgotten).
        time.sleep(1.0)
        assert client.get(f"/jobs/{job_id}").json()["state"] == "cancelled"
        assert _wait_for(lambda: not job_runner_module._procs, timeout=10.0)

        # Terminal: neither resumable nor retryable.
        assert client.post(f"/jobs/{job_id}/resume").status_code == 409
        assert client.post(f"/jobs/{job_id}/retry").status_code == 409


def test_cancelled_queued_job_is_skipped_by_worker(tmp_path):
    output_dir, _ = _configure(tmp_path)
    from fastapi.testclient import TestClient
    from server import job_runner as job_runner_module
    from server import jobs as jobs_module
    from server.main import app

    job_runner_module._workers_started = False
    job_runner_module._resumed_orphans = False

    with TestClient(app) as client:
        pdf = tmp_path / "uploads" / "skipped.pdf"
        pdf.write_bytes(b"%PDF-1.4 fake")
        job_id = jobs_module.create_job(
            book_id="skipped", filename="skipped.pdf", title="Skipped", pdf_path=str(pdf))
        assert jobs_module.request_cancel(job_id)["state"] == "cancelled"
        assert jobs_module.request_cancel("no-such-job") is None
        job_runner_module.enqueue(job_id)

        time.sleep(1.0)  # generous: the fake convert exits instantly if run
        assert jobs_module.get_job(job_id)["state"] == "cancelled"
        assert not (output_dir / "skipped" / "status.json").exists()
        assert not (output_dir / "skipped" / "manifest.json").exists()

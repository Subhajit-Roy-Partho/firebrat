"""Background conversion queue. Jobs are run out-of-process (convert.py as a
subprocess, exactly like the documented manual CLI invocation) so a crash in
marker-pdf/torch/chatterbox can never take the API server down with it.

A fixed pool of worker threads (MAX_CONCURRENT_JOBS, default 1 — conversion
is memory/GPU heavy, see AGENTS.md) pulls job ids off a queue and blocks on
each subprocess in turn. Per-run progress is NOT tracked here — the status
endpoint reads it straight from the job's status.json (firebrat.pipeline.status),
written by convert.py itself as it runs. This module only owns the
queued -> running -> done/failed transition that status.json can't express
on its own (there's no status.json at all until the subprocess actually starts).
"""
import logging
import os
import queue
import subprocess
import threading

from server import config, jobs
from firebrat.pipeline.status import read_status

log = logging.getLogger("firebrat.server.jobs")

_queue: "queue.Queue[str]" = queue.Queue()
_workers_started = False
_workers_lock = threading.Lock()
_resumed_orphans = False
_resume_lock = threading.Lock()


def _job_log_path(book_id: str) -> str:
    return os.path.join(config.OUTPUT_DIR, book_id, "convert_stdout.log")


def skip_extraction_arg_for_stage(stage: str | None) -> list[str]:
    """Shared with server/routes/jobs.py's retry/resume endpoints so both
    apply the same "never redo a stage that already produced output" rule.
    """
    if stage in ("compiling", "rendering_formulas", "synthesizing", "packaging", "manifest", "done"):
        return ["--skip-extraction"]
    return []


def _run_job(job_id: str, extra_args: list[str]) -> None:
    job = jobs.get_job(job_id)
    if job is None:
        log.error("Job %s vanished before it could run", job_id)
        return

    jobs.set_state(job_id, "running")
    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    os.makedirs(pkg_dir, exist_ok=True)
    log_path = _job_log_path(job["book_id"])

    cmd = [
        config.CONVERT_PY, config.CONVERT_SCRIPT, job["pdf_path"],
        "--output", config.OUTPUT_DIR,
        "--book-id", job["book_id"],
        "--title", job["title"],
        *extra_args,
    ]
    log.info("Starting conversion job %s: %s", job_id, " ".join(cmd))
    try:
        with open(log_path, "a", encoding="utf-8") as logf:
            logf.write(f"\n=== job {job_id} start: {' '.join(cmd)} ===\n")
            logf.flush()
            result = subprocess.run(cmd, stdout=logf, stderr=subprocess.STDOUT)
        if result.returncode == 0:
            jobs.set_state(job_id, "done")
            log.info("Job %s (%s) finished successfully", job_id, job["book_id"])
        else:
            jobs.set_state(job_id, "failed", error=f"convert.py exited {result.returncode} — see {log_path}")
            log.error("Job %s (%s) failed with exit code %d", job_id, job["book_id"], result.returncode)
    except Exception as e:  # subprocess launch itself failed (bad path, etc.)
        log.exception("Job %s failed to launch", job_id)
        jobs.set_state(job_id, "failed", error=str(e))


def _worker_loop() -> None:
    while True:
        job_id, extra_args = _queue.get()
        try:
            _run_job(job_id, extra_args)
        finally:
            _queue.task_done()


def ensure_workers_started() -> None:
    global _workers_started
    with _workers_lock:
        if _workers_started:
            return
        n = max(1, config.MAX_CONCURRENT_JOBS)
        for _ in range(n):
            t = threading.Thread(target=_worker_loop, daemon=True)
            t.start()
        _workers_started = True
        log.info("Started %d conversion worker thread(s)", n)


def enqueue(job_id: str, extra_args: list[str] | None = None) -> None:
    ensure_workers_started()
    _queue.put((job_id, extra_args or []))


def resume_orphaned_jobs() -> None:
    """Called once at server startup. A job left in `queued` or `running`
    state means the server process that owned it is gone (crashed, was
    restarted, whatever) — this process's in-memory queue is empty
    regardless of what the jobs table says, so nothing would ever pick
    those back up on its own. convert.py resumes from checkpoint by design
    (see AGENTS.md), so simply re-enqueueing is safe and correct — this is
    what makes "the server restarted mid-conversion" a non-event instead of
    a silently stuck job the user has to notice and manually retry.
    """
    global _resumed_orphans
    with _resume_lock:
        if _resumed_orphans:
            return
        _resumed_orphans = True

    orphaned = [j for j in jobs.list_jobs() if j["state"] in ("queued", "running")]
    for job in orphaned:
        if not os.path.isfile(job["pdf_path"]):
            jobs.set_state(job["job_id"], "failed", error="original upload no longer on disk after server restart")
            continue
        pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
        status = read_status(pkg_dir) or {}
        extra_args = skip_extraction_arg_for_stage(status.get("stage"))
        jobs.set_state(job["job_id"], "queued")
        log.info("Resuming orphaned job %s (%s) left in state after restart", job["job_id"], job["book_id"])
        enqueue(job["job_id"], extra_args)

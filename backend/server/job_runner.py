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
import calendar
import collections
import logging
import os
import queue
import subprocess
import threading
import time

from server import config, jobs
from firebrat.pipeline.status import read_status

log = logging.getLogger("firebrat.server.jobs")

_queue: "queue.Queue[str]" = queue.Queue()
_workers_started = False
_workers_lock = threading.Lock()
# Tracked worker threads so the watchdog can restart any that died — a dead
# worker with MAX_CONCURRENT_JOBS=1 means the queue silently never drains.
_workers: list[threading.Thread] = []
# Tick interval for the stuck-job watchdog below.
_WATCHDOG_TICK_S = 60
# Default quiet-period after which a `running` job with no live subprocess is
# considered stuck. Deliberately exceeds legitimate quiet periods (local-LLM
# compilation goes 20+ min without a status.json update — observed).
# Overridable via FIREBRAT_STUCK_AFTER_MIN (minutes).
_DEFAULT_STUCK_AFTER_MIN = 30.0
_resumed_orphans = False
_resume_lock = threading.Lock()
# Live convert.py subprocess per running job id, so DELETE /jobs/{id} can
# terminate a running conversion. Guarded by _procs_lock; entries are added
# just before Popen.wait() and removed right after it returns.
_procs: dict[str, subprocess.Popen] = {}
_procs_lock = threading.Lock()
# Priority lane for "Convert this now": promote_now() appends the target here
# and _worker_loop drains it before the main queue, so the promoted job
# jumps the front without disturbing the relative order of the rest.
_priority: "collections.deque[tuple[str, list[str]]]" = collections.deque()
_priority_lock = threading.Lock()
# Job ids flagged for checkpoint pause by promote_now(). The worker's
# post-wait pause check sees the flag, flips the row back to queued (partial
# output stays on disk for checkpoint resume), and returns without ever
# marking the job failed/cancelled. Guarded by _paused_lock.
_paused: set[str] = set()
_paused_lock = threading.Lock()


def _job_log_path(book_id: str) -> str:
    return os.path.join(config.OUTPUT_DIR, book_id, "convert_stdout.log")


# Poll interval for the cast scheduler state files (seconds). Tests with a
# fake scheduler dir monkeypatch this down so the mirror loop stays fast.
_CAST_POLL_S = 2.0


def _run_cast_job(job_id: str, job: dict, pkg_dir: str) -> None:
    """Run a cast job: write the scheduler inbox entry, then mirror the
    scheduler's progress into status.json until it reports done/failed.

    The scheduler owns retries/resume (its state.json is resumable) — a
    re-enqueued cast job just rewrites the same inbox entry and picks up
    where the scheduler left off. Never raises: all failures mark the job
    failed with a readable reason instead of killing the worker thread.
    """
    from server import cast_bridge
    try:
        slug = cast_bridge.write_inbox_entry(
            job["book_id"], job["title"], job["pdf_path"])
    except Exception as e:
        log.exception("Cast job %s failed to write inbox entry", job_id)
        jobs.set_state(job_id, "failed", error=str(e))
        return
    cast_bridge.mirror_status(pkg_dir, cast_bridge.cast_job_view(slug))
    log.info("Cast job %s (%s) handed to scheduler as %s", job_id, job["book_id"], slug)
    while True:
        time.sleep(_CAST_POLL_S)
        if (jobs.get_job(job_id) or {}).get("state") == "cancelled":
            # Cancelled while waiting: keep the terminal cancelled state.
            log.info("Cast job %s (%s) was cancelled, leaving state", job_id, job["book_id"])
            return
        try:
            view = cast_bridge.cast_job_view(slug)
        except Exception:
            log.exception("Cast job %s progress read failed", job_id)
            continue
        try:
            cast_bridge.mirror_status(pkg_dir, view)
        except Exception:
            log.exception("Cast job %s status mirror failed", job_id)
        if view["terminal"] == "done":
            jobs.set_state(job_id, "done")
            log.info("Cast job %s (%s) finished successfully", job_id, job["book_id"])
            return
        if view["terminal"] == "failed":
            jobs.set_state(job_id, "failed", error=view["error"] or "cast scheduler reported failure")
            log.error("Cast job %s (%s) failed: %s", job_id, job["book_id"], view["error"])
            return


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
    if job.get("state") == "cancelled":
        # DELETE /jobs/{id} on a still-queued job flags it before removing
        # the row; when the row is already gone the get_job() above returns
        # None and we skip the same way. Either way convert.py never runs.
        log.info("Job %s cancelled while queued, skipping", job_id)
        return

    jobs.set_state(job_id, "running")
    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    os.makedirs(pkg_dir, exist_ok=True)
    if (job.get("content_mode") or "") == "cast":
        # Expressive-cast jobs never run convert.py: the scheduler owns the
        # pipeline, this worker only feeds it and mirrors its progress.
        _run_cast_job(job_id, job, pkg_dir)
        return
    log_path = _job_log_path(job["book_id"])

    cmd = [
        config.CONVERT_PY, config.CONVERT_SCRIPT, job["pdf_path"],
        "--output", config.OUTPUT_DIR,
        "--book-id", job["book_id"],
        # `--opt=value` form: a user-chosen title starting with "-" must
        # not be parsed as another option by argparse.
        f"--title={job['title']}",
        *extra_args,
    ]
    if job.get("content_mode") == "novel":
        cmd += ["--content-mode", "novel"]
        if job.get("research_characters"):
            cmd += ["--research-characters"]
        for line in (job.get("character_traits") or "").splitlines():
            if line.strip():
                cmd += [f"--character-trait={line.strip()}"]
    # Per-job conversion options (see jobs.create_job): a local-provider
    # job points the pipeline at the on-server LLM shim, and a chunk_pages
    # override rides along as FIREBRAT_CHUNK_PAGES for this subprocess
    # only — the server default is untouched.
    run_env = dict(os.environ)
    provider = (job.get("provider") or "nanogpt")
    if provider == "local":
        run_env["NANO_API_URL"] = config.LOCAL_LLM_URL
        log.info("Job %s uses LOCAL provider (%s)", job_id, config.LOCAL_LLM_URL)
    else:
        # Per-job cloud-model override: both LLM tiers use the picked id
        # so every chunk runs on it. Empty preserves the env defaults.
        override = ((job.get("model") or "").strip())[:200]
        if override:
            run_env["FIREBRAT_SPARK_MODEL"] = override
            run_env["FIREBRAT_DEEPSEEK_MODEL"] = override
            log.info("Job %s uses model override %s", job_id, override)
    try:
        chunk_pages = int(job.get("chunk_pages") or 0)
    except (TypeError, ValueError):
        chunk_pages = 0
    if chunk_pages <= 0:
        # Callers that omit chunk_pages (the mobile app) inherit the
        # server default from /settings instead of the hardcoded 10.
        try:
            from server.routes.settings import read_settings
            chunk_pages = int(read_settings().get("default_chunk_pages") or 0)
        except Exception:
            chunk_pages = 0
    if chunk_pages > 0:
        run_env["FIREBRAT_CHUNK_PAGES"] = str(chunk_pages)
    log.info("Starting conversion job %s: %s", job_id, " ".join(cmd))
    try:
        with open(log_path, "a", encoding="utf-8") as logf:
            logf.write(f"\n=== job {job_id} start: {' '.join(cmd)} ===\n")
            logf.flush()
            # Popen (not subprocess.run) so cancel_running() can terminate
            # a conversion DELETE-d mid-flight; wait() blocks the same way.
            proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=run_env)
            with _procs_lock:
                _procs[job_id] = proc
            try:
                returncode = proc.wait()
            finally:
                with _procs_lock:
                    _procs.pop(job_id, None)
        with _paused_lock:
            was_paused = job_id in _paused
            if was_paused:
                _paused.discard(job_id)
        if was_paused:
            # Paused by promote_now ("Convert this now"): the SIGTERM above
            # was a checkpoint pause, not a user cancel or a failure.
            # Partial output stays on disk; the job was already re-enqueued
            # by promote_now and resumes from checkpoint when dequeued.
            jobs.set_state(job_id, "queued")
            log.info("Job %s (%s) paused for priority job, back to queued", job_id, job["book_id"])
            return
        if (jobs.get_job(job_id) or {}).get("state") == "cancelled":
            # Cancelled while running: keep the terminal cancelled state —
            # never overwrite it with done/failed from the killed process.
            log.info("Job %s (%s) was cancelled mid-run, leaving state", job_id, job["book_id"])
            return
        if returncode == 0:
            jobs.set_state(job_id, "done")
            log.info("Job %s (%s) finished successfully", job_id, job["book_id"])
            # Push to topic job-<id> (no-op without FCM credentials — the
            # app also polls this same state, so nothing is lost).
            try:
                from server import auth as _auth
                _auth.notify_topic(
                    _auth.job_topic(job_id),
                    "Conversion finished",
                    f"{job['title']} is ready to download.",
                )
            except Exception:
                log.exception("FCM notify failed for job %s", job_id)
        else:
            jobs.set_state(job_id, "failed", error=f"convert.py exited {returncode} — see the job log")
            log.error("Job %s (%s) failed with exit code %d", job_id, job["book_id"], returncode)
            try:
                from server import auth as _auth
                _auth.notify_topic(
                    _auth.job_topic(job_id),
                    "Conversion failed",
                    f"{job['title']} failed — check the job log and retry.",
                )
            except Exception:
                log.exception("FCM notify failed for job %s", job_id)
    except Exception as e:  # subprocess launch itself failed (bad path, etc.)
        log.exception("Job %s failed to launch", job_id)
        jobs.set_state(job_id, "failed", error=str(e))


def _worker_loop() -> None:
    while True:
        # Priority lane first (non-blocking): a promoted "Convert this now"
        # job jumps the front of the main queue. The deque needs no
        # task_done() — only items from the real Queue do.
        try:
            with _priority_lock:
                job_id, extra_args = _priority.popleft()
            _run_job(job_id, extra_args)
            continue
        except IndexError:
            pass
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
            _workers.append(t)
        t = threading.Thread(target=_watchdog_loop, daemon=True)
        t.start()
        _workers_started = True
        log.info("Started %d conversion worker thread(s)", n)


def _stuck_after_seconds() -> float:
    """Quiet-period threshold (seconds) after which a proc-less `running`
    job is treated as stuck. Read per tick so the env override never needs
    a restart to take effect; garbage/non-positive values fall back to the
    default rather than nuking healthy quiet jobs."""
    try:
        mins = float(os.environ.get("FIREBRAT_STUCK_AFTER_MIN", "") or _DEFAULT_STUCK_AFTER_MIN)
    except (TypeError, ValueError):
        mins = _DEFAULT_STUCK_AFTER_MIN
    if mins <= 0:
        mins = _DEFAULT_STUCK_AFTER_MIN
    return mins * 60.0


def _parse_updated_at(value: object) -> float | None:
    """Parse a status.json / jobs-table updated_at (%Y-%m-%dT%H:%M:%SZ, UTC)
    into epoch seconds. Returns None when missing or unparseable."""
    if not isinstance(value, str) or not value:
        return None
    try:
        return float(calendar.timegm(time.strptime(value, "%Y-%m-%dT%H:%M:%SZ")))
    except (ValueError, OverflowError):
        return None


def _watchdog_tick() -> None:
    # (a) Restart dead workers so the queue always drains. With
    # MAX_CONCURRENT_JOBS=1 a single dead thread wedges every later job.
    with _workers_lock:
        for i, t in enumerate(list(_workers)):
            if not t.is_alive():
                log.warning("Conversion worker thread %d died, restarting it", i)
                new_t = threading.Thread(target=_worker_loop, daemon=True)
                new_t.start()
                _workers[i] = new_t
    # (b) Requeue stuck jobs: `running` in the table but no live convert.py
    # subprocess and quiet (no status.json update) for longer than the
    # threshold. Untouched, always: jobs with a live proc, queued jobs
    # (including ones with no status.json — legitimately waiting), and
    # cancelled/done/failed states.
    stuck_after = _stuck_after_seconds()
    now = time.time()
    with _procs_lock:
        live = set(_procs.keys())
    for job in jobs.list_jobs():
        if job.get("state") != "running":
            continue
        if job["job_id"] in live:
            continue
        pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
        status = read_status(pkg_dir) or {}
        updated = _parse_updated_at(status.get("updated_at"))
        if updated is None:
            # No (parseable) status.json yet — fall back to the job row's own
            # timestamp (set when the worker flipped it to running). A fresh
            # row means the worker only just dequeued it (Popen not yet
            # registered in _procs), so only treat old rows as stuck.
            updated = _parse_updated_at(job.get("updated_at"))
        if updated is None:
            continue
        if now - updated < stuck_after:
            continue
        log.warning(
            "Job %s (%s) stuck in running with no live subprocess for %.0fs, requeueing",
            job["job_id"], job["book_id"], now - updated,
        )
        jobs.set_state(job["job_id"], "queued")
        enqueue(job["job_id"], skip_extraction_arg_for_stage(status.get("stage")))


def _watchdog_loop() -> None:
    while True:
        try:
            _watchdog_tick()
        except Exception:
            log.exception("Stuck-job watchdog tick failed")
        time.sleep(_WATCHDOG_TICK_S)


def cancel_running(job_id: str) -> bool:
    """Terminate the live convert.py subprocess for a running job, if any.

    Only kills this job's own process (tracked per job id in _procs) — other
    jobs are untouched. Returns True if a process was found and signalled.
    The worker's post-wait cancelled check keeps the row cancelled rather
    than flipping it to failed from the killed exit code.
    """
    with _procs_lock:
        proc = _procs.get(job_id)
    if proc is None:
        return False
    try:
        proc.terminate()
    except Exception:
        log.exception("Failed to terminate job %s subprocess", job_id)
        return False
    return True


def promote_now(job_id: str) -> list[str]:
    """Pause every running job and jump [job_id] to the front of the queue.

    Each currently-running job (other than the target) with a live convert.py
    subprocess is flagged in _paused, SIGTERM-ed via cancel_running(), flipped
    back to `queued`, and re-enqueued with checkpoint-resume args so it
    continues — not restarts — when its turn comes back. Partial output on
    disk is never touched.

    The target is pulled out of the main queue when present (under
    _queue.mutex, adjusting unfinished_tasks) and appended to the priority
    lane with checkpoint-resume args; the worker loop drains the priority
    lane before the main queue. Its state is ensured `queued`.

    Returns the ids that were paused. Uploads/packages are never deleted.
    """
    paused_ids: list[str] = []
    with _procs_lock:
        live_ids = [jid for jid in _procs.keys() if jid != job_id]
    for rjid in live_ids:
        rjob = jobs.get_job(rjid)
        if rjob is None or rjob.get("state") != "running":
            continue
        with _paused_lock:
            _paused.add(rjid)
        cancelled = cancel_running(rjid)
        pkg_dir = os.path.join(config.OUTPUT_DIR, rjob["book_id"])
        status = read_status(pkg_dir) or {}
        extra = skip_extraction_arg_for_stage(status.get("stage"))
        jobs.set_state(rjid, "queued")
        enqueue(rjid, extra)
        paused_ids.append(rjid)
        log.info("Job %s (%s) paused for priority job %s (proc signalled: %s)",
                 rjid, rjob["book_id"], job_id, cancelled)

    target = jobs.get_job(job_id)
    if target is not None:
        pkg_dir = os.path.join(config.OUTPUT_DIR, target["book_id"])
        status = read_status(pkg_dir) or {}
        extra = skip_extraction_arg_for_stage(status.get("stage"))
        # Pull any already-queued entries for the target out of the main
        # queue so it runs exactly once, from the priority lane.
        removed = 0
        with _queue.mutex:
            kept = collections.deque()
            while _queue.queue:
                item = _queue.queue.popleft()
                if item[0] == job_id:
                    removed += 1
                else:
                    kept.append(item)
            _queue.queue.extend(kept)
            if removed:
                _queue.unfinished_tasks = max(0, _queue.unfinished_tasks - removed)
        with _priority_lock:
            _priority.append((job_id, extra))
        jobs.set_state(job_id, "queued")
        log.info("Job %s promoted to front (removed %d queued entr%s, paused %d running): %s",
                 job_id, removed, "y" if removed == 1 else "ies",
                 len(paused_ids), paused_ids)
    return paused_ids


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
    # `cancelled` is terminal on purpose: a user-cancelled job must never be
    # picked back up, by restart recovery or by the worker's dequeue check.
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

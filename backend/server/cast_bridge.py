"""Expressive-cast ("cast") server bridge: inbox entries, progress mirroring, scheduler supervisor.

The cast scheduler (``firebrat_cast.scheduler``, owned by another worker) is a
separate long-lived process: it watches ``<cast_root>/inbox/*.json`` and turns
each entry into a standard book package under ``<cast_root>/out/<slug>/``. This
module is the server side of that contract (see ``firebrat_cast/INTEGRATION.md``):

- inbox: one JSON file per cast job so the scheduler picks it up;
- progress: the scheduler's ``jobs/<slug>/state.json`` (+ ``progress.json``)
  mirrored into the job's ``status.json`` so the normal ``/jobs`` views work;
- supervisor: starts the scheduler as a child process at server startup and
  restarts it at most 3 times if it dies unexpectedly.
"""
from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import threading
import time

log = logging.getLogger("firebrat.server.cast")

# Inbox slugs must match ^[a-z0-9][a-z0-9-]{2,99}$ (INTEGRATION.md contract).
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,99}$")

# Scheduler stage -> job stage text shown in /jobs (INTEGRATION.md contract).
_STAGE_TEXT = {
    "fetch": "preparing text",
    "segment": "preparing text",
    "cast": "casting characters",
    "synth": "recording voices",
    "package": "packaging",
}

# How many times the supervisor relaunches a scheduler that keeps dying.
MAX_RESTARTS = 3


def cast_root() -> str:
    from server import config
    return config.cast_root()


def normalize_slug(book_id: str) -> str:
    """Map a job book_id onto a valid inbox slug.

    Upload names are usually already valid (lowercase alnum/dashes); only
    underscores (kept by sanitize_book_id) and too-short names need fixing.
    """
    slug = re.sub(r"[^a-z0-9-]+", "-", (book_id or "").lower()).strip("-")
    slug = re.sub(r"-{2,}", "-", slug) or "book"
    if not slug[0].isalnum():
        slug = "book-" + slug.strip("-")
    slug = slug.strip("-") or "book"
    if len(slug) < 3:
        slug = (slug + "-book")[:3]
    slug = slug[:100].rstrip("-") or "book"
    # Safety net: whatever came in, the result is always a plain slug that
    # is safe to join into <root>/jobs/<slug>, inbox/ and cancel/ paths
    # (never "..", never a separator).
    return slug if SLUG_RE.match(slug) else "book"


def inbox_path(slug: str, root: str | None = None) -> str:
    return os.path.join(root or cast_root(), "inbox", f"{slug}.json")


def write_inbox_entry(book_id: str, title: str, source_path: str,
                      root: str | None = None) -> str:
    """Write the scheduler inbox entry for a cast job. Returns the slug."""
    slug = normalize_slug(book_id)
    if not SLUG_RE.match(slug):
        raise ValueError(f"book_id {book_id!r} cannot form a valid cast slug")
    entry = {
        "slug": slug,
        "title": title or book_id,
        "author": "",
        "source_path": source_path,
        "category": "fiction",
        "language": "en",
        "description": "",
    }
    path = inbox_path(slug, root)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    # A re-submission of a slug must not inherit an old cancel flag.
    clear_cancel(slug, root)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entry, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    log.info("Cast inbox entry written for %s -> %s", book_id, path)
    return slug


def remove_inbox_entry(book_id: str, root: str | None = None) -> bool:
    """Remove a still-queued inbox entry (delete-before-pickup). Never fails."""
    path = inbox_path(normalize_slug(book_id), root)
    try:
        if os.path.isfile(path):
            os.remove(path)
            return True
    except OSError:
        log.warning("Could not remove cast inbox entry %s", path)
    return False


def cancel_flag_path(slug: str, root: str | None = None) -> str:
    return os.path.join(root or cast_root(), "cancel", slug)


def request_cancel(slug: str, root: str | None = None) -> bool:
    """Tell the scheduler to skip/stop this book (marker file
    <root>/cancel/<slug>, re-read by the scheduler on every decision)."""
    slug = normalize_slug(slug)
    path = cancel_flag_path(slug, root)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8"):
            pass
        return True
    except OSError:
        log.warning("Could not write cancel flag %s", path)
        return False


def clear_cancel(slug: str, root: str | None = None) -> None:
    try:
        os.remove(cancel_flag_path(normalize_slug(slug), root))
    except OSError:
        pass


def priority_path(root: str | None = None) -> str:
    return os.path.join(root or cast_root(), "priority.json")


def set_priority_top(slug: str, root: str | None = None) -> list[str]:
    """Move a slug to the front of <root>/priority.json ({"top": [...]})."""
    slug = normalize_slug(slug)
    path = priority_path(root)
    cur = _read_json(path).get("top")
    top = [s for s in (cur if isinstance(cur, list) else [])
           if isinstance(s, str) and s != slug][:49]
    top.insert(0, slug)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"top": top}, f)
    os.replace(tmp, path)
    return top


def settings_file() -> str:
    """The exact path server_settings.py writes; exported to the scheduler."""
    from server import server_settings
    return server_settings.SETTINGS_PATH()


def build_env() -> dict:
    """Scheduler child environment: ours plus FIREBRAT_SETTINGS_FILE pointing
    at <data>/server_settings.json (INTEGRATION2 decision 2)."""
    return dict(os.environ, FIREBRAT_SETTINGS_FILE=settings_file())


def ensure_out_symlink(root: str | None = None) -> str:
    """Point <cast_root>/out at FIREBRAT_OUTPUT_DIR so /books lists cast output.

    Returns the out dir. When it already exists (dir or correct symlink) it is
    left alone; a stale symlink is repointed.
    """
    from server import config
    root = root or cast_root()
    out = os.path.join(root, "out")
    target = config.OUTPUT_DIR
    os.makedirs(target, exist_ok=True)
    if os.path.islink(out):
        if os.path.realpath(out) == os.path.realpath(target):
            return out
        os.remove(out)
    if not os.path.exists(out):
        os.makedirs(root, exist_ok=True)
        try:
            os.symlink(target, out)
        except OSError:
            # Symlinks need privileges on some platforms — fall back to a
            # plain directory (packages still build, just not listed).
            log.warning("Could not symlink %s -> %s, using a plain dir", out, target)
            os.makedirs(out, exist_ok=True)
    return out


def _read_json(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def read_cast_state(slug: str, root: str | None = None) -> dict:
    """Raw scheduler state for a slug: state.json (+ scheduler_status.json)."""
    root = root or cast_root()
    state = _read_json(os.path.join(root, "jobs", slug, "state.json"))
    status = _read_json(os.path.join(root, "scheduler_status.json"))
    return {"state": state, "scheduler_status": status,
            "progress": _read_json(os.path.join(root, "jobs", slug, "progress.json"))}


def cast_job_view(slug: str, root: str | None = None) -> dict:
    """Map scheduler files onto job stage text.

    Returns {stage, detail, progress, terminal, error}: terminal is
    "done"/"failed" once the scheduler says so, else None.
    """
    seen = read_cast_state(slug, root)
    state, progress = seen["state"], seen["progress"]
    status = (state.get("status") or "").strip()
    if status == "done":
        return {"stage": "done", "detail": state.get("stage") or "done",
                "progress": 1.0, "terminal": "done", "error": None}
    if status == "failed":
        return {"stage": "failed", "detail": state.get("stage") or "failed",
                "progress": progress.get("percent") if isinstance(progress, dict) else None,
                "terminal": "failed",
                "error": state.get("error") or "cast scheduler reported failure"}
    stage = (state.get("stage") or "").strip()
    text = _STAGE_TEXT.get(stage, "queued" if not stage else stage)
    pct = progress.get("percent") if isinstance(progress, dict) else None
    try:
        frac = float(pct) / 100.0 if pct is not None else None
    except (TypeError, ValueError):
        frac = None
    detail = state.get("detail") or seen["scheduler_status"].get("detail") or text
    return {"stage": text, "detail": detail, "progress": frac,
            "terminal": None, "error": None}


def mirror_status(pkg_dir: str, view: dict) -> None:
    """Write the job's status.json from a cast_job_view so /jobs shows it."""
    from firebrat.pipeline.status import write_status
    status = "failed" if view["terminal"] == "failed" else (
        "done" if view["terminal"] == "done" else "running")
    write_status(pkg_dir, status=status, stage=view["stage"],
                 detail=view.get("detail") or view["stage"],
                 progress=view.get("progress"),
                 error=view.get("error") if status == "failed" else None)


def build_command(root: str | None = None) -> list[str]:
    """Scheduler child-process argv (interpreters from FIREBRAT_CAST_*_PY).

    The scheduler's settings file travels in the environment, not argv:
    see build_env() (FIREBRAT_SETTINGS_FILE=<data>/server_settings.json),
    which CastSupervisor passes to Popen."""
    from server import config
    root = root or cast_root()
    cmd = [sys.executable, "-m", "firebrat_cast.scheduler", "run",
           "--root", root]
    llm_py = os.environ.get("FIREBRAT_CAST_LLM_PY", config.CAST_LLM_PY).strip()
    tts_py = os.environ.get("FIREBRAT_CAST_TTS_PY", config.CAST_TTS_PY).strip()
    vllm_bin = os.environ.get("FIREBRAT_CAST_VLLM_BIN", "").strip()
    if llm_py:  # interpreter for the cast stage client (talks to the managed vLLM server over HTTP)
        cmd += ["--cast-python", llm_py]
    if tts_py:
        cmd += ["--tts-python", tts_py]
    if vllm_bin:
        cmd += ["--vllm-bin", vllm_bin]
    return cmd


class CastSupervisor:
    """Starts the scheduler child process and restarts it at most 3 times.

    A watcher thread waits on the process: an unexpected exit relaunches it
    (up to MAX_RESTARTS), an expected one (after stop()) does not. Pass an
    explicit command in tests to avoid needing the real scheduler module.
    """

    def __init__(self, command: list[str] | None = None,
                 root: str | None = None):
        self._command = command
        self._root = root
        self._proc: subprocess.Popen | None = None
        self._watcher: threading.Thread | None = None
        self._stopping = threading.Event()
        self._lock = threading.Lock()
        self.restarts = 0

    @property
    def running(self) -> bool:
        with self._lock:
            return self._proc is not None and self._proc.poll() is None

    def start(self) -> bool:
        """Launch (or keep) the scheduler. False when cast is unavailable."""
        from server import config
        if self.running:
            return True
        if self._command is None and not config.cast_available():
            log.info("Cast not available, scheduler supervisor staying idle")
            return False
        self._stopping.clear()
        self.restarts = 0
        if not self._launch():
            return False
        self._watcher = threading.Thread(target=self._watch, daemon=True)
        self._watcher.start()
        return True

    def _launch(self) -> bool:
        cmd = self._command or build_command(self._root)
        try:
            self._proc = subprocess.Popen(cmd, env=build_env())
            log.info("Cast scheduler started: %s", " ".join(cmd))
            return True
        except Exception:
            log.exception("Could not start cast scheduler")
            with self._lock:
                self._proc = None
            return False

    def _watch(self) -> None:
        while not self._stopping.is_set():
            proc = self._proc
            if proc is None:
                return
            proc.wait()
            if self._stopping.is_set():
                return
            # Unexpected exit — relaunch a bounded number of times.
            if self.restarts >= MAX_RESTARTS:
                log.error("Cast scheduler died %d times, giving up", self.restarts + 1)
                with self._lock:
                    self._proc = None
                return
            self.restarts += 1
            log.warning("Cast scheduler exited, restarting (%d/%d)",
                        self.restarts, MAX_RESTARTS)
            time.sleep(1.0)
            if self._stopping.is_set():
                return
            if not self._launch():
                return

    def stop(self) -> None:
        """Terminate the child process; the watcher will not relaunch it."""
        self._stopping.set()
        with self._lock:
            proc = self._proc
        if proc is not None and proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=10)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
                log.exception("Error stopping cast scheduler")
        with self._lock:
            self._proc = None


_supervisor: CastSupervisor | None = None
_supervisor_lock = threading.Lock()


def ensure_supervisor_started(command: list[str] | None = None) -> bool:
    """Start (or keep) the process-wide scheduler supervisor. Idempotent."""
    global _supervisor
    with _supervisor_lock:
        if _supervisor is not None and _supervisor.running:
            return True
        _supervisor = CastSupervisor(command=command)
        return _supervisor.start()


def shutdown_supervisor() -> None:
    """Stop the scheduler child process (server shutdown). Never raises."""
    global _supervisor
    with _supervisor_lock:
        sup, _supervisor = _supervisor, None
    if sup is not None:
        try:
            sup.stop()
        except Exception:
            log.exception("Error shutting down cast supervisor")

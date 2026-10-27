"""Inbox-driven scheduler: prefetch CPU work anytime, LLM cast in waves, audio synth shortest-first.

CLI: ``python -m firebrat_cast.scheduler <run|submit|status> ...``

Inbox: ``<root>/inbox/<slug>.json`` (catalog entries). ``submit`` validates and
writes atomically. ``run --catalog FILE`` imports a catalog list into the
inbox (skipping existing slugs) then loops:

1. discover inbox entries; fetch+segment every new/unfetched one immediately
   (CPU only, allowed at any time).
2. LLM PHASE when some book has segment done and cast not done (and not
   failed beyond retries): snapshot that set; start vLLM once, cast the whole
   snapshot, ALWAYS stop vLLM. GpuLock held for the whole phase.
3. AUDIO PHASE when no LLM work pending and some book has cast done and synth
   not done: snapshot sorted shortest-first, synth+package one at a time.
   Books arriving mid-phase are only prefetched until the snapshot finishes.
   GPU lock held only while each synth stage runs.
4. LLM beats audio; a running audio snapshot is never interrupted.

Per-book attempts live in ``jobs/<slug>/state.json`` (reuse
queue_runner.load_state/save_state); skip after ``--max-retries``.
``<root>/scheduler_status.json`` is written atomically on every transition.
SIGTERM/SIGINT stops after the current book, stops vLLM, exits cleanly.

All GPU/network/subprocess work is injectable via ``hooks`` so unit tests run
with pure fakes (see SchedulerConfig.hooks).
"""
from __future__ import annotations

import argparse
import datetime
import inspect
import logging
import os
import re
import signal
import subprocess
import sys
import time
import urllib.request
from contextlib import nullcontext
from dataclasses import dataclass, field

from firebrat_cast import catalog as _catalog

# Local settings reader (additive; replaces the never-created
# ``firebrat_cast.settings`` module). Server persists admin choices to
# server_settings.json; the scheduler re-reads them before every phase.
# Resolution: $FIREBRAT_SETTINGS_FILE else <root>/server_settings.json.

log = logging.getLogger("firebrat_cast.scheduler")

STATUS_NAME = "scheduler_status.json"
INBOX_NAME = "inbox"

BATCH_PARAM_NAMES = frozenset({
    "slugs", "slug_list", "slugs_list", "book_slugs", "batch",
    "entries", "books", "items",
})


# ── config ──────────────────────────────────────────────────────────

@dataclass
class SchedulerConfig:
    root: str
    poll_s: float = 20.0
    once: bool = False
    llm_model: str = "Qwen/Qwen3.5-9B"
    vllm_bin: str = "vllm"
    port: int = 8100
    served_name: str = "qwen3.5-9b"
    tts: str = "qwen"
    tts_python: str | None = None
    cast_python: str | None = None
    max_retries: int = 2
    max_vram_util: float = 0.90
    max_model_len: int = 8192
    catalog: str | None = None
    hooks: dict = field(default_factory=dict)
    # Server settings hot-reload (INTEGRATION2.md). When a settings source
    # exists (settings_provider hook, else <data>/server_settings.json),
    # refresh_settings() applies it before every phase; no restart needed.
    # Absent keys leave the corresponding CLI/field value untouched.
    settings_provider: object = None  # callable returning a settings dict
    phase_mode: str = "batched"  # batched | sequential (one book end-to-end)
    max_books_per_llm_phase: int | None = None  # cap on the LLM snapshot
    audio_order: str = "shortest_first"  # shortest_first | fifo
    paused: bool = False  # when true: status "paused", no GPU work
    tts_engine: str = "qwen3-tts-1.7b"  # full catalog id (cfg.tts is the kind)
    quiet_hours: dict | None = None  # None or {start,end HH:MM}: ALLOWED GPU window


# ── paths / inbox / status ──────────────────────────────────────────

def inbox_dir(root: str) -> str:
    return os.path.join(root, INBOX_NAME)


def status_path(root: str) -> str:
    return os.path.join(root, STATUS_NAME)


def list_inbox(root: str) -> list[dict]:
    """Read inbox/*.json in sorted slug order; invalid files are skipped."""
    from firebrat_cast.fetch import read_json, validate_entry

    d = inbox_dir(root)
    if not os.path.isdir(d):
        return []
    out: list[dict] = []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(d, name)
        try:
            out.append(validate_entry(read_json(path)))
        except (OSError, ValueError) as e:
            log.warning("Skipping bad inbox file %s: %s", path, e)
    return out


def submit_entry(root: str, entry: dict) -> str:
    """Validate and atomically write inbox/<slug>.json. Returns the path."""
    from firebrat_cast.fetch import validate_entry, write_json_atomic

    norm = validate_entry(entry)
    path = os.path.join(inbox_dir(root), f"{norm['slug']}.json")
    write_json_atomic(path, norm)
    return path


def import_catalog(root: str, catalog_path: str) -> dict:
    """Import catalog list entries into the inbox; skip slugs already present."""
    from firebrat_cast.fetch import read_json, validate_entry

    raw = read_json(catalog_path)
    if not isinstance(raw, list):
        raise ValueError(f"Catalog must be a list: {catalog_path}")
    imported, skipped = [], []
    for item in raw:
        norm = validate_entry(item)
        dest = os.path.join(inbox_dir(root), f"{norm['slug']}.json")
        if os.path.isfile(dest):
            skipped.append(norm["slug"])
            continue
        from firebrat_cast.fetch import write_json_atomic

        write_json_atomic(dest, norm)
        imported.append(norm["slug"])
    return {"imported": imported, "skipped": skipped}


def _now_iso(cfg: SchedulerConfig) -> str:
    now = cfg.hooks.get("now")
    if now is not None:
        try:
            return _call_clock(now, cfg.root)
        except TypeError:
            return now()
    return datetime.datetime.utcnow().isoformat() + "Z"


def _sleep(cfg: SchedulerConfig, s: float) -> None:
    fn = cfg.hooks.get("sleep")
    if fn is not None:
        fn(s)
        return
    time.sleep(s)


def _arity(fn) -> int:
    try:
        params = list(inspect.signature(fn).parameters.values())
    except (TypeError, ValueError):
        return 99  # unknown: assume flexible, try widest call first
    n = 0
    for p in params:
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD):
            return 99
        if p.default is p.empty:
            n += 1
        else:
            n += 1
    # return number of positional params (required or not); callers try widest first
    return len(params)


def _required(fn) -> int:
    """Number of REQUIRED positional parameters (defaults do not count)."""
    try:
        params = list(inspect.signature(fn).parameters.values())
    except (TypeError, ValueError):
        return 0
    return sum(1 for p in params
               if p.default is p.empty
               and p.kind in (p.POSITIONAL_ONLY, p.POSITIONAL_OR_KEYWORD))


def _call_clock(fn, root: str):
    """Call a clock hook as fn() or fn(root) depending on required args."""
    return fn() if _required(fn) == 0 else fn(root)


def _first_param_name(fn) -> str:
    try:
        params = list(inspect.signature(fn).parameters.values())
    except (TypeError, ValueError):
        return ""
    return params[0].name if params else ""


def _entries(cfg: SchedulerConfig) -> list[dict]:
    """List inbox entries via hook (0-arg or 1-arg) or disk."""
    fn = cfg.hooks.get("list_inbox")
    if fn is not None:
        try:
            if _arity(fn) == 0:
                return list(fn())
            return list(fn(cfg.root))
        except TypeError:
            # hook with unexpected arity: try the other shape once
            try:
                return list(fn())
            except TypeError:
                return list(fn(cfg.root))
    return list_inbox(cfg.root)


def _text_size(cfg: SchedulerConfig, entry: dict) -> int | None:
    fn = cfg.hooks.get("text_size")
    if fn is not None:
        try:
            if _arity(fn) >= 2:
                return fn(entry, cfg.root)
            return fn(entry)
        except TypeError:
            try:
                return fn(entry)
            except TypeError:
                return fn(entry, cfg.root)
    from firebrat_cast.queue_runner import book_size_chars

    return book_size_chars(entry, cfg.root)


def _gpu_lock_cm(cfg: SchedulerConfig):
    fn = cfg.hooks.get("gpu_lock")
    if fn is not None:
        try:
            if _arity(fn) == 0:
                return fn()
            return fn()
        except TypeError:
            return fn()
    from firebrat_cast.gpu import GpuLock

    return GpuLock()


def _free_vram(cfg: SchedulerConfig):
    fn = cfg.hooks.get("free_vram")
    if fn is not None:
        return fn()
    from firebrat_cast.gpu import free_vram_gb

    return free_vram_gb()



# ── operator controls: priority file + cancel flags ─────────────────
# The server (admin queue endpoints) writes <root>/priority.json
# ({"top": [slug, ...]}, front of the list runs first) and one marker file
# <root>/cancel/<slug> per cancelled book. Both are re-read on every
# decision, so they work without restarting the scheduler.

PRIORITY_NAME = "priority.json"
CANCEL_DIR = "cancel"


def priority_path(root: str) -> str:
    return os.path.join(root, PRIORITY_NAME)


def cancel_path(root: str, slug: str) -> str:
    return os.path.join(root, CANCEL_DIR, slug)


def _priority_rank(cfg: SchedulerConfig) -> dict:
    import json as _json

    try:
        with open(priority_path(cfg.root), encoding="utf-8") as f:
            data = _json.load(f)
        top = data.get("top") if isinstance(data, dict) else data
        if not isinstance(top, list):
            return {}
        rank: dict = {}
        for s in top:
            if isinstance(s, str) and s not in rank:
                rank[s] = len(rank)
        return rank
    except (OSError, ValueError):
        return {}


def _by_priority(cfg: SchedulerConfig, entries: list[dict]) -> list[dict]:
    """Stable sort: prioritized slugs first (in priority order)."""
    rank = _priority_rank(cfg)
    if not rank:
        return entries
    return sorted(entries, key=lambda e: (e["slug"] not in rank,
                                          rank.get(e["slug"], 0)))


def _cancelled(cfg: SchedulerConfig, slug: str) -> bool:
    return os.path.exists(cancel_path(cfg.root, slug))


def _inbox_mtime_ns(cfg: SchedulerConfig, slug: str) -> int:
    try:
        return os.stat(os.path.join(inbox_dir(cfg.root), f"{slug}.json")).st_mtime_ns
    except OSError:
        return 0


# ── per-book state helpers (reuse queue_runner state) ───────────────

def _state(cfg: SchedulerConfig, slug: str) -> dict:
    from firebrat_cast.queue_runner import load_state

    return load_state(cfg.root, slug)


def _done_flag(cfg: SchedulerConfig, slug: str, stage: str) -> bool:
    return (_state(cfg, slug).get("done") or {}).get(stage) == "done"


def _attempts(cfg: SchedulerConfig, slug: str, stage: str) -> int:
    try:
        return int((_state(cfg, slug).get("attempts") or {}).get(stage, 0))
    except (TypeError, ValueError):
        return 0


def _permanent_fail(cfg: SchedulerConfig, slug: str, stage: str) -> bool:
    return _attempts(cfg, slug, stage) >= cfg.max_retries


def _book_failed(cfg: SchedulerConfig, slug: str) -> bool:
    st = _state(cfg, slug)
    if st.get("status") != "failed":
        return False
    atts = st.get("attempts") or {}
    try:
        return any(int(v) >= cfg.max_retries for v in atts.values())
    except (TypeError, ValueError):
        return True


def _is_done(cfg: SchedulerConfig, slug: str) -> bool:
    from firebrat_cast.queue_runner import is_done

    return is_done(cfg.root, slug)


def _llm_pending(cfg: SchedulerConfig, entries: list[dict]) -> list[dict]:
    out = []
    for e in entries:
        slug = e["slug"]
        if _is_done(cfg, slug) or _book_failed(cfg, slug) or _cancelled(cfg, slug):
            continue
        if _permanent_fail(cfg, slug, "cast"):
            continue
        if _done_flag(cfg, slug, "segment") and not _done_flag(cfg, slug, "cast"):
            out.append(e)
    return _by_priority(cfg, out)


def _audio_pending(cfg: SchedulerConfig, entries: list[dict]) -> list[dict]:
    out = []
    for e in entries:
        slug = e["slug"]
        if _is_done(cfg, slug) or _book_failed(cfg, slug) or _cancelled(cfg, slug):
            continue
        if _permanent_fail(cfg, slug, "synth"):
            continue
        if _done_flag(cfg, slug, "cast") and not _done_flag(cfg, slug, "synth"):
            out.append(e)
    if getattr(cfg, "audio_order", "shortest_first") == "fifo":
        # arrival order: inbox file mtime (ties -> slug), no size sort
        out.sort(key=lambda e: (_inbox_mtime_ns(cfg, e["slug"]), e["slug"]))
        return _by_priority(cfg, out)
    # shortest first; unknown sizes last; stable by inbox order
    sized = [(_text_size(cfg, e), i, e) for i, e in enumerate(out)]
    sized.sort(key=lambda t: (t[0] is None, t[0] if t[0] is not None else 0, t[1]))
    return _by_priority(cfg, [e for _, _, e in sized])


def _unfetched(cfg: SchedulerConfig, entries: list[dict]) -> list[dict]:
    out = []
    for e in entries:
        slug = e["slug"]
        if _is_done(cfg, slug) or _book_failed(cfg, slug) or _cancelled(cfg, slug):
            continue
        if _done_flag(cfg, slug, "segment"):
            continue
        if _permanent_fail(cfg, slug, "fetch") or _permanent_fail(cfg, slug, "segment"):
            continue
        out.append(e)
    return out


def _queue_snapshot(cfg: SchedulerConfig, entries: list[dict]) -> dict:
    waiting_cast = [e["slug"] for e in _llm_pending(cfg, entries)]
    waiting_audio = [e["slug"] for e in _audio_pending(cfg, entries)]
    done, failed, cancelled = [], [], []
    for e in entries:
        slug = e["slug"]
        if _is_done(cfg, slug):
            done.append(slug)
        elif _cancelled(cfg, slug):
            cancelled.append(slug)
        elif _book_failed(cfg, slug):
            failed.append(slug)
    return {"waiting_cast": waiting_cast, "waiting_audio": waiting_audio,
            "done": done, "failed": failed, "cancelled": cancelled}


def write_status(cfg: SchedulerConfig, phase: str, current_book: str | None,
                 entries: list[dict], llm_up: bool = False,
                 eta_hint: str | None = None, since: str | None = None) -> dict:
    """Atomically write scheduler_status.json; return the payload."""
    from firebrat_cast.fetch import write_json_atomic

    payload = {
        "phase": phase,
        "current_book": current_book,
        "queue": _queue_snapshot(cfg, entries),
        "since": since or _now_iso(cfg),
        "llm_server": {"up": bool(llm_up), "port": cfg.port},
        "eta_hint": eta_hint,
    }
    write_json_atomic(status_path(cfg.root), payload)
    return payload


# ── stage execution with retry counting (do_stage semantics) ────────

def _tracked(cfg: SchedulerConfig, entry: dict, stage: str, fn) -> bool:
    """Run one stage via queue_runner.do_stage; count attempts in state.

    Returns True on success (or already done). On exception increments
    ``attempts[stage]``; leaves status failed once attempts >= max_retries,
    else resets status to running so the book retries next phase. One bad
    book never raises to the caller.
    """
    from firebrat_cast.queue_runner import RunnerConfig, do_stage, load_state, save_state

    slug = entry["slug"]
    if _done_flag(cfg, slug, stage):
        return True
    if _attempts(cfg, slug, stage) >= cfg.max_retries:
        return False
    fake = RunnerConfig(catalog="", root=cfg.root, hooks={})
    try:
        do_stage(fake, entry, stage, fn, time.monotonic())
        return True
    except Exception:
        st = load_state(cfg.root, slug)
        atts = dict(st.get("attempts") or {})
        try:
            cur = int(atts.get(stage, 0))
        except (TypeError, ValueError):
            cur = 0
        atts[stage] = cur + 1
        st["attempts"] = atts
        if atts[stage] < cfg.max_retries:
            st["status"] = "running"  # retryable: not permanently failed
            if "error" in st:
                st["error"] = f"attempt {atts[stage]}/{cfg.max_retries}: {st.get('error', '')}"
        save_state(cfg.root, slug, st)
        return False


def _call2(hook, entry: dict, root: str):
    """Call hook as (entry, root) or (entry) depending on arity."""
    if _arity(hook) >= 2:
        return hook(entry, root)
    return hook(entry)


def _call_cast_hook(hook, entry: dict, root: str):
    """Support per-book fn(entry[, root]) and batch fn(slugs[, root]) hooks.

    Always called once per book (single-element batch) so one failure never
    blocks the rest of the snapshot.
    """
    name = _first_param_name(hook)
    ar = _arity(hook)
    if name in BATCH_PARAM_NAMES:
        if ar >= 2:
            return hook([entry["slug"]], root)
        return hook([entry["slug"]])
    return _call2(hook, entry, root)


def _default_prefetch(cfg: SchedulerConfig, entry: dict) -> None:
    from firebrat_cast import queue_runner as qr

    _tracked(cfg, entry, "fetch", lambda: qr.default_fetch(entry, cfg.root))
    if _done_flag(cfg, entry["slug"], "fetch") or _done_flag(cfg, entry["slug"], "segment"):
        # fetch ok (or already done) -> try segment unless permanently failed
        if not _permanent_fail(cfg, entry["slug"], "segment"):
            _tracked(cfg, entry, "segment", lambda: qr.default_segment(entry, cfg.root))


def prefetch_one(cfg: SchedulerConfig, entry: dict) -> None:
    hook = cfg.hooks.get("prefetch")
    if hook is not None:
        try:
            _call2(hook, entry, cfg.root)
        except Exception:
            # count against fetch so retry limits still isolate bad books
            from firebrat_cast.queue_runner import load_state, save_state

            slug = entry["slug"]
            st = load_state(cfg.root, slug)
            atts = dict(st.get("attempts") or {})
            try:
                cur = int(atts.get("fetch", 0))
            except (TypeError, ValueError):
                cur = 0
            atts["fetch"] = cur + 1
            st["attempts"] = atts
            if atts["fetch"] >= cfg.max_retries:
                st["stage"] = "fetch"
                st["status"] = "failed"
                st["error"] = st.get("error") or "prefetch failed"
            else:
                st["status"] = "running"
            save_state(cfg.root, slug, st)
        return
    _default_prefetch(cfg, entry)


def default_run_cast(cfg: SchedulerConfig, entry: dict) -> None:
    """Cast one book via stage_proc in --cast-python (external LLM backend)."""
    from firebrat_cast import queue_runner as qr

    if cfg.cast_python:
        cmd = [cfg.cast_python, "-m", "firebrat_cast.stage_proc", "cast-wave",
               "--catalog", _catalog_for_slugs(cfg),
               "--root", cfg.root, "--slugs", entry["slug"],
               "--llm-backend", "external", "--tts", cfg.tts]
        env = dict(os.environ, CAST_LLM_URL=f"http://127.0.0.1:{cfg.port}/v1",
                   CAST_LLM_MODEL=cfg.served_name,
                   PYTHONPATH=os.pathsep.join(
                       p for p in (os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                   os.environ.get("PYTHONPATH", "")) if p))
        subprocess.run(cmd, check=True, env=env)
        return
    # no subprocess interpreter: reuse in-process external-backend path
    backend = qr.make_llm_backend("external")
    qr.do_stage(qr.RunnerConfig(catalog="", root=cfg.root, hooks={}),
                entry, "cast",
                lambda: qr.default_cast_one(entry, cfg.root, backend),
                time.monotonic())


def default_run_synth(cfg: SchedulerConfig, entry: dict) -> None:
    """Synth one book via stage_proc in --tts-python, else in-process engine."""
    from firebrat_cast import queue_runner as qr

    if cfg.tts_python:
        cmd = [cfg.tts_python, "-m", "firebrat_cast.stage_proc", "synth-wave",
               "--catalog", _catalog_for_slugs(cfg),
               "--root", cfg.root, "--slugs", entry["slug"],
               "--llm-backend", "external", "--tts", cfg.tts]
        env = dict(os.environ, PYTHONPATH=os.pathsep.join(
            p for p in (os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        os.environ.get("PYTHONPATH", "")) if p))
        subprocess.run(cmd, check=True, env=env)
        return
    engine = qr.make_tts_engine(cfg.tts)
    engine.load()
    try:
        qr.do_stage(qr.RunnerConfig(catalog="", root=cfg.root, hooks={}),
                    entry, "synth",
                    lambda: qr.default_synth_one(entry, cfg.root, engine),
                    time.monotonic())
    finally:
        try:
            engine.unload()
        except Exception:
            pass


def _catalog_for_slugs(cfg: SchedulerConfig) -> str:
    """stage_proc needs a catalog file; materialize the inbox as one."""
    from firebrat_cast.fetch import write_json_atomic

    path = os.path.join(cfg.root, "jobs", ".scheduler-catalog.json")
    write_json_atomic(path, _entries(cfg))
    return path


def run_cast_one(cfg: SchedulerConfig, entry: dict) -> bool:
    hook = cfg.hooks.get("run_cast")
    if hook is not None:
        return _tracked(cfg, entry, "cast",
                        lambda: _call_cast_hook(hook, entry, cfg.root))
    return _tracked(cfg, entry, "cast", lambda: default_run_cast(cfg, entry))


def run_synth_one(cfg: SchedulerConfig, entry: dict) -> bool:
    hook = cfg.hooks.get("run_synth")
    if hook is not None:
        return _tracked(cfg, entry, "synth",
                        lambda: _call2(hook, entry, cfg.root))
    return _tracked(cfg, entry, "synth", lambda: default_run_synth(cfg, entry))


def run_package_one(cfg: SchedulerConfig, entry: dict) -> bool:
    from firebrat_cast import queue_runner as qr

    hook = cfg.hooks.get("package")
    if hook is not None:
        return _tracked(cfg, entry, "package",
                        lambda: _call2(hook, entry, cfg.root))
    return _tracked(cfg, entry, "package",
                    lambda: qr.default_package(entry, cfg.root))


# ── managed vLLM server (real defaults; fakes via hooks) ───────────

_LLM_PROC: subprocess.Popen | None = None
_LLM_LOG = "vllm.log"


def vllm_cmd(cfg: SchedulerConfig) -> list[str]:
    return [cfg.vllm_bin, "serve", cfg.llm_model,
            "--quantization", "fp8",
            "--max-model-len", str(cfg.max_model_len),
            "--max-num-seqs", "8",
            "--gpu-memory-utilization", str(cfg.max_vram_util),
            "--port", str(cfg.port),
            "--served-model-name", cfg.served_name]


def vllm_env() -> dict:
    return dict(os.environ,
                VLLM_USE_FLASHINFER_SAMPLER="0",
                HF_HUB_OFFLINE="1",
                CUDA_MPS_PIPE_DIRECTORY="/tmp/firebrat-no-mps")


def _vllm_log_path(cfg: SchedulerConfig) -> str:
    return os.path.join(cfg.root, _LLM_LOG)


def _wait_http_ok(url: str, timeout_s: float, poll_s: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            with urllib.request.urlopen(url, timeout=10) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(poll_s)


def default_start_llm(cfg: SchedulerConfig) -> None:
    """Launch vLLM as a process group; wait for GET /v1/models (15 min)."""
    global _LLM_PROC
    if _LLM_PROC is not None and _LLM_PROC.poll() is None:
        return
    log_path = _vllm_log_path(cfg)
    os.makedirs(os.path.dirname(os.path.abspath(log_path)), exist_ok=True)
    logf = open(log_path, "ab")
    _LLM_PROC = subprocess.Popen(vllm_cmd(cfg), env=vllm_env(),
                                 stdout=logf, stderr=subprocess.STDOUT,
                                 start_new_session=True)
    ok = _wait_http_ok(f"http://127.0.0.1:{cfg.port}/v1/models",
                       timeout_s=15 * 60, poll_s=5.0)
    if not ok:
        tail = ""
        try:
            with open(log_path, "rb") as f:
                f.seek(max(0, os.path.getsize(log_path) - 8000))
                tail = f.read().decode("utf-8", "replace")
        except OSError:
            pass
        try:
            default_stop_llm(cfg)
        finally:
            pass
        raise RuntimeError(
            f"vLLM server did not answer GET /v1/models within 15 min "
            f"(port {cfg.port}). Log tail:\n{tail}")


def default_stop_llm(cfg: SchedulerConfig) -> None:
    """SIGTERM the vLLM process group, SIGKILL after 30 s; wait VRAM >= 12 GiB."""
    global _LLM_PROC
    proc = _LLM_PROC
    _LLM_PROC = None
    if proc is not None and proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except (OSError, ProcessLookupError):
            pass
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                pass
    # wait until >= 12 GiB free (3 min); no GPU -> return immediately
    deadline = time.monotonic() + 3 * 60
    while True:
        free = _free_vram(cfg)
        if free is None or free >= 12.0:
            return
        if time.monotonic() >= deadline:
            log.warning("VRAM still %.1f GiB free after vLLM stop (want >= 12)", free)
            return
        time.sleep(5.0)


def start_llm(cfg: SchedulerConfig) -> None:
    fn = cfg.hooks.get("start_llm")
    if fn is not None:
        fn()
        return
    default_start_llm(cfg)


def stop_llm(cfg: SchedulerConfig) -> None:
    fn = cfg.hooks.get("stop_llm")
    if fn is not None:
        fn()
        return
    default_stop_llm(cfg)


# ── server settings hot-reload (INTEGRATION2.md) ─────────────────
# The server validates admin choices against firebrat_cast.catalog and
# persists them to server_settings.json; the scheduler re-reads them
# before every phase so no restart is needed. Tests inject a fake via
# cfg.settings_provider or hooks["settings_provider"].
# A present source is authoritative (merged onto defaults()); with no
# source (no provider, no file) cfg is left untouched so CLI flags keep
# working. Invalid sources fall back to defaults with a warning.
# quiet_hours is the QUIET window (no new GPU work inside it, null =
# always allowed); overnight windows like 22:00-06:00 wrap midnight.

SETTINGS_FILE_NAME = "server_settings.json"

_RUN_PATTERN_FIELDS = ("phase_mode", "max_books_per_llm_phase",
                       "audio_order", "paused", "quiet_hours")


def settings_path(root: str) -> str:
    """Settings file: $FIREBRAT_SETTINGS_FILE else <root>/server_settings.json.

    Falls back to the parent dir (<data>/server_settings.json when
    root is <data>/cast) so a server-owned file next to the root is still
    honoured when no env pointer is exported. First hit wins."""

    env = os.environ.get("FIREBRAT_SETTINGS_FILE")
    if env:
        return env
    direct = os.path.join(root, SETTINGS_FILE_NAME)
    if os.path.isfile(direct):
        return direct
    parent = os.path.join(os.path.dirname(os.path.abspath(root)),
                          SETTINGS_FILE_NAME)
    if os.path.isfile(parent):
        return parent
    return direct


def settings_candidates(root: str) -> list:
    """All local settings paths, in priority order (for tests/diagnostics)."""
    env = os.environ.get("FIREBRAT_SETTINGS_FILE")
    if env:
        return [env]
    direct = os.path.join(root, SETTINGS_FILE_NAME)
    parent = os.path.join(os.path.dirname(os.path.abspath(root)),
                          SETTINGS_FILE_NAME)
    return [direct, parent]


def defaults() -> dict:
    """Default settings values (preserve current batched behaviour)."""
    return {
        "llm": {"model": "qwen3.5-9b", "quantization": "fp8"},
        "tts": {"engine": "qwen3-tts-1.7b"},
        "run_pattern": {"phase_mode": "batched",
                        "max_books_per_llm_phase": 4,
                        "audio_order": "shortest_first",
                        "paused": False,
                        "quiet_hours": None},
    }


def _valid_hm(s) -> bool:
    if not isinstance(s, str):
        return False
    try:
        datetime.datetime.strptime(s, "%H:%M")
        return True
    except ValueError:
        return False


def _normalize_quiet_hours(q):
    """Validate a quiet_hours value -> {start,end} dict or None."""
    if q is None:
        return None
    if isinstance(q, (list, tuple)) and len(q) == 2:
        q = {"start": q[0], "end": q[1]}
    if not isinstance(q, dict):
        return None
    start, end = q.get("start"), q.get("end")
    if _valid_hm(start) and _valid_hm(end):
        return {"start": start, "end": end}
    return None


def merge_validated(base: dict, raw: dict) -> dict:
    """Merge raw onto base with per-field validation; invalid -> default.

    Accepts nested {llm,tts,run_pattern} and flat run_pattern keys
    (e.g. {"max_books_per_llm_phase": 2}) for hook convenience.
    Never raises on bad values.
    """
    if not isinstance(base, dict):
        base = defaults()
    if not isinstance(raw, dict):
        return defaults()
    out = {"llm": dict(base.get("llm") or {}),
           "tts": dict(base.get("tts") or {}),
           "run_pattern": dict(base.get("run_pattern") or {})}
    # lift flat run_pattern keys (provider convenience form)
    lifted = {k: raw[k] for k in _RUN_PATTERN_FIELDS if k in raw}
    raw_llm = raw.get("llm") if isinstance(raw.get("llm"), dict) else {}
    raw_tts = raw.get("tts") if isinstance(raw.get("tts"), dict) else {}
    raw_run = raw.get("run_pattern") if isinstance(raw.get("run_pattern"), dict) else {}
    raw_run = {**lifted, **raw_run} if lifted else raw_run

    llm_id = raw_llm.get("model", out["llm"].get("model"))
    out["llm"]["model"] = (llm_id if llm_id in _catalog.LLM_MODELS
                           else defaults()["llm"]["model"])
    quant = raw_llm.get("quantization", out["llm"].get("quantization"))
    out["llm"]["quantization"] = (quant if quant in ("fp8",) else "fp8")

    tts_id = raw_tts.get("engine", out["tts"].get("engine"))
    out["tts"]["engine"] = (tts_id if tts_id in _catalog.TTS_ENGINES
                            else defaults()["tts"]["engine"])

    rp, dflt_rp = out["run_pattern"], defaults()["run_pattern"]
    pm = raw_run.get("phase_mode", rp.get("phase_mode"))
    rp["phase_mode"] = pm if pm in ("batched", "sequential") else dflt_rp["phase_mode"]
    ao = raw_run.get("audio_order", rp.get("audio_order"))
    rp["audio_order"] = (ao if ao in ("shortest_first", "fifo")
                         else dflt_rp["audio_order"])
    cap = raw_run.get("max_books_per_llm_phase", rp.get("max_books_per_llm_phase"))
    if isinstance(cap, bool) or not isinstance(cap, int) or not 1 <= cap <= 20:
        rp["max_books_per_llm_phase"] = dflt_rp["max_books_per_llm_phase"]
    else:
        rp["max_books_per_llm_phase"] = cap
    paused = raw_run.get("paused", rp.get("paused"))
    rp["paused"] = paused if isinstance(paused, bool) else False
    rp["quiet_hours"] = _normalize_quiet_hours(
        raw_run.get("quiet_hours", rp.get("quiet_hours")))
    if "limits" in base or "limits" in raw:
        out["limits"] = dict(base.get("limits") or {})
    return out


def load(path: str):
    """Load+validate a settings file. (None, None) when absent; on invalid
    content returns (defaults(), err) with a warning string."""
    import json as _json

    try:
        with open(path) as f:
            raw = _json.load(f)
    except FileNotFoundError:
        return None, None
    except OSError as e:
        return defaults(), f"unreadable ({e}); using defaults"
    except ValueError as e:
        return defaults(), f"invalid JSON ({e}); using defaults"
    if not isinstance(raw, dict):
        return defaults(), "invalid (non-object); using defaults"
    try:
        return merge_validated(defaults(), raw), None
    except Exception as e:  # never break the loop on weird content
        return defaults(), f"invalid ({e}); using defaults"


def _apply_values(cfg: SchedulerConfig, values: dict) -> None:
    """Copy validated settings values onto cfg (ids -> runtime config)."""
    try:
        llm_id = (values.get("llm") or {}).get("model")
        entry = _catalog.LLM_MODELS.get(llm_id)
        if entry is not None:
            cfg.llm_model = entry["repo"]
            cfg.served_name = entry["served_name"]
        tts_id = (values.get("tts") or {}).get("engine")
        tentry = _catalog.TTS_ENGINES.get(tts_id)
        if tentry is not None:
            cfg.tts_engine = tts_id
            cfg.tts = tentry["scheduler_tts"]
        run = values.get("run_pattern") or {}
        if run.get("phase_mode") in ("batched", "sequential"):
            cfg.phase_mode = run["phase_mode"]
        if "max_books_per_llm_phase" in run:
            cfg.max_books_per_llm_phase = run["max_books_per_llm_phase"]
        if run.get("audio_order") in ("shortest_first", "fifo"):
            cfg.audio_order = run["audio_order"]
        if isinstance(run.get("paused"), bool):
            cfg.paused = run["paused"]
        if "quiet_hours" in run:
            cfg.quiet_hours = run["quiet_hours"]
    except Exception as e:
        log.warning("Settings apply failed (%s); keeping current values", e)


def _call_provider(cfg: SchedulerConfig):
    """Call the settings provider hook as () or (root) or (cfg)."""
    prov = cfg.settings_provider
    if prov is None:
        prov = cfg.hooks.get("settings_provider")
    if prov is None:
        return None
    if _arity(prov) == 0:
        return prov()
    try:
        return prov(cfg.root)
    except TypeError:
        return prov(cfg)


def current_settings(cfg: SchedulerConfig) -> dict:
    """Normalized view of the hot-reloadable values currently on cfg."""
    return {"llm_model": cfg.llm_model, "served_name": cfg.served_name,
            "tts": cfg.tts, "tts_engine": getattr(cfg, "tts_engine", None),
            "phase_mode": getattr(cfg, "phase_mode", "batched"),
            "max_books_per_llm_phase": getattr(cfg, "max_books_per_llm_phase", None),
            "audio_order": getattr(cfg, "audio_order", "shortest_first"),
            "paused": bool(getattr(cfg, "paused", False)),
            "quiet_hours": getattr(cfg, "quiet_hours", None)}


def refresh_settings(cfg: SchedulerConfig) -> dict:
    """Re-read server settings and apply them to cfg (hot reload).

    A present source (provider hook, else the settings file) is
    authoritative: values merge onto defaults(). With no source
    (no provider, no file) cfg is left untouched so CLI flags and direct
    field sets keep working. Never raises. Returns current_settings.
    """
    try:
        if cfg.settings_provider is not None or "settings_provider" in cfg.hooks:
            try:
                raw = _call_provider(cfg)
            except Exception as e:
                log.warning("Settings provider failed (%s); using defaults", e)
                raw = {}
            if not isinstance(raw, dict):
                log.warning("Settings provider returned non-object; using defaults")
                raw = {}
            try:
                values = merge_validated(defaults(), raw)
            except ValueError as e:
                log.warning("Invalid settings (%s); using defaults", e)
                values = defaults()
            _apply_values(cfg, values)
        else:
            path = settings_path(cfg.root)
            values, err = load(path)
            if values is None:
                return current_settings(cfg)  # no file: leave cfg untouched
            if err:
                log.warning("Settings file %s: %s", path, err)
            _apply_values(cfg, values)
    except Exception as e:
        log.warning("Settings refresh failed (%s); keeping current values", e)
    return current_settings(cfg)


def _peek_paused(cfg: SchedulerConfig) -> bool:
    """Current `paused` from the settings source WITHOUT applying other
    values (a model switch only takes effect at the next phase). Falls back
    to cfg.paused when there is no source."""
    try:
        if cfg.settings_provider is not None or "settings_provider" in cfg.hooks:
            raw = _call_provider(cfg)
            values = merge_validated(defaults(), raw if isinstance(raw, dict) else {})
        else:
            values, _err = load(settings_path(cfg.root))
            if values is None:
                return bool(getattr(cfg, "paused", False))
        return bool(values["run_pattern"]["paused"])
    except Exception:
        return bool(getattr(cfg, "paused", False))


def _now_dt(cfg: SchedulerConfig):
    """Now as a datetime (fakeable via hooks now_hm/clock/now). None when
    the clock is unreadable (callers fail open: GPU work proceeds)."""
    hm: str | None = None
    for key in ("now_hm", "clock"):
        fn = cfg.hooks.get(key)
        if fn is not None:
            try:
                hm = str(_call_clock(fn, cfg.root)).strip()
            except Exception:
                return None
            break
    else:
        fn = cfg.hooks.get("now")
        if fn is not None:
            try:
                s = str(_call_clock(fn, cfg.root))
            except Exception:
                return None
            m = re.search(r"(\d{2}):(\d{2})", s)
            hm = f"{m.group(1)}:{m.group(2)}" if m else None
    if hm is None:
        try:
            return datetime.datetime.now()
        except Exception:
            return None
    try:
        t = datetime.datetime.strptime(hm, "%H:%M")
    except ValueError:
        return None
    try:
        return datetime.datetime.now().replace(hour=t.hour, minute=t.minute,
                                              second=0, microsecond=0)
    except Exception:
        return None


def _quiet_contains(q, now) -> bool:
    """True when datetime now falls inside the quiet (no-GPU) window."""
    qq = _normalize_quiet_hours(q)
    if qq is None:
        return False
    try:
        s = datetime.datetime.strptime(qq["start"], "%H:%M")
        e = datetime.datetime.strptime(qq["end"], "%H:%M")
    except ValueError:
        return False
    cur = (now.hour, now.minute)
    start, end = (s.hour, s.minute), (e.hour, e.minute)
    if start <= end:
        # same-day window; end is exclusive (06:00 allows, 22:00 blocks)
        return start <= cur < end if start != end else True
    return cur >= start or cur < end


def in_allowed_window(q, now) -> bool:
    """Compat: allowed == outside the quiet window."""
    return not _quiet_contains(q, now)


def _in_quiet_hours(cfg: SchedulerConfig) -> bool:
    """True when now is inside cfg.quiet_hours (GPU must wait)."""
    q = getattr(cfg, "quiet_hours", None)
    if not q:
        return False
    now = _now_dt(cfg)
    if now is None:
        return False  # clock unreadable: fail open
    try:
        return _quiet_contains(q, now)
    except Exception as e:
        log.warning("quiet_hours check failed (%s); allowing GPU work", e)
        return False


def gpu_blocked(cfg: SchedulerConfig) -> bool:
    """True when GPU work must wait: paused, or now is inside the
    quiet_hours window (null window = never blocked)."""
    if bool(getattr(cfg, "paused", False)):
        return True
    q = getattr(cfg, "quiet_hours", None)
    if not q:
        return False
    now = _now_dt(cfg)
    if now is None:
        return False  # clock unreadable: fail open, GPU work proceeds
    try:
        return _quiet_contains(q, now)
    except Exception as e:
        log.warning("quiet_hours check failed (%s); allowing GPU work", e)
        return False


# ── phases ──────────────────────────────────────────────────────────

def llm_phase(cfg: SchedulerConfig, snapshot: list[dict], stop_flag: dict) -> None:
    """Cast a fixed snapshot under one vLLM server + GpuLock. Never extended."""
    if not snapshot:
        return
    refresh_settings(cfg)  # hot reload: vllm_cmd below uses current values
    entries = _entries(cfg)
    since = _now_iso(cfg)
    write_status(cfg, "llm", snapshot[0]["slug"], entries, llm_up=False,
                 eta_hint=f"casting {len(snapshot)} book(s)", since=since)
    with _gpu_lock_cm(cfg):
        start_llm(cfg)
        try:
            entries = _entries(cfg)
            write_status(cfg, "llm", snapshot[0]["slug"], entries, llm_up=True,
                         eta_hint=f"casting {len(snapshot)} book(s)", since=since)
            for entry in snapshot:
                if stop_flag.get("stop"):
                    break
                if _cancelled(cfg, entry["slug"]):
                    continue
                if _peek_paused(cfg):
                    break  # paused mid-snapshot: stop after the current book
                write_status(cfg, "llm", entry["slug"], _entries(cfg), llm_up=True,
                             eta_hint=f"casting {entry['slug']}", since=since)
                try:
                    run_cast_one(cfg, entry)
                except Exception as e:
                    log.warning("cast %s failed (isolated): %s", entry["slug"], e)
        finally:
            try:
                stop_llm(cfg)
            except Exception as e:
                log.warning("stop_llm failed: %s", e)


def audio_phase(cfg: SchedulerConfig, snapshot: list[dict], stop_flag: dict) -> None:
    """Synth+package a fixed shortest-first snapshot. New arrivals wait."""
    if not snapshot:
        return
    refresh_settings(cfg)  # hot reload: synth below uses the current tts
    since = _now_iso(cfg)
    for entry in snapshot:
        if stop_flag.get("stop"):
            break
        if _cancelled(cfg, entry["slug"]):
            continue
        if _peek_paused(cfg):
            break  # paused mid-snapshot: stop after the current book
        # prefetch any books that arrived mid-phase (CPU only, not added here)
        try:
            for fresh in _unfetched(cfg, _entries(cfg)):
                if fresh["slug"] not in {e["slug"] for e in snapshot}:
                    prefetch_one(cfg, fresh)
        except Exception as e:
            log.warning("mid-phase prefetch failed (isolated): %s", e)
        write_status(cfg, "audio", entry["slug"], _entries(cfg), llm_up=False,
                     eta_hint=f"synth {entry['slug']}", since=since)
        try:
            with _gpu_lock_cm(cfg):
                ok = run_synth_one(cfg, entry)
            if ok and not stop_flag.get("stop"):
                try:
                    run_package_one(cfg, entry)
                except Exception as e:
                    log.warning("package %s failed (isolated): %s", entry["slug"], e)
        except Exception as e:
            log.warning("synth %s failed (isolated): %s", entry["slug"], e)


def _sequential_step(cfg: SchedulerConfig, entries: list[dict],
                     stop_flag: dict) -> bool:
    """Run one book end-to-end for phase_mode=sequential. True when work ran.

    Picks the first actionable book in inbox order: cast it (when needed),
    then synth+package it (when ready) within this single tick. Books whose
    segment step is still pending are left for the loop-top prefetch batch.
    """
    for e in _by_priority(cfg, entries):
        slug = e["slug"]
        if _is_done(cfg, slug) or _book_failed(cfg, slug) or _cancelled(cfg, slug):
            continue
        if not _done_flag(cfg, slug, "segment"):
            continue
        cast_ok = (not _done_flag(cfg, slug, "cast")
                   and not _permanent_fail(cfg, slug, "cast"))
        audio_ok = (_done_flag(cfg, slug, "cast")
                    and not _done_flag(cfg, slug, "synth")
                    and not _permanent_fail(cfg, slug, "synth"))
        if not (cast_ok or audio_ok):
            continue
        if stop_flag.get("stop"):
            return True
        if cast_ok:
            llm_phase(cfg, [e], stop_flag)
        if (not stop_flag.get("stop") and _done_flag(cfg, slug, "cast")
                and not _done_flag(cfg, slug, "synth")
                and not _permanent_fail(cfg, slug, "synth")):
            audio_phase(cfg, [e], stop_flag)
        return True
    return False


def run_loop(cfg: SchedulerConfig) -> dict:
    """Main loop. Returns {done, failed}. Resumable; SIGTERM/SIGINT exits cleanly."""
    stop_flag: dict = {"stop": False}

    def _handler(signum, frame):
        stop_flag["stop"] = True

    old_term = signal.getsignal(signal.SIGTERM)
    old_int = signal.getsignal(signal.SIGINT)
    try:
        signal.signal(signal.SIGTERM, _handler)
    except (OSError, ValueError):
        pass
    try:
        signal.signal(signal.SIGINT, _handler)
    except (OSError, ValueError):
        pass
    try:
        if cfg.catalog:
            try:
                import_catalog(cfg.root, cfg.catalog)
            except Exception as e:
                log.warning("catalog import failed: %s", e)
        while True:
            if stop_flag.get("stop"):
                write_status(cfg, "idle", None, _entries(cfg), llm_up=False,
                             eta_hint="stopped")
                return {"stopped": True}
            refresh_settings(cfg)  # hot reload every tick; no-op without source
            entries = _entries(cfg)
            # 1. prefetch everything new/unfetched (CPU, any time)
            pending_fetch = _unfetched(cfg, entries)
            if pending_fetch:
                since = _now_iso(cfg)
                write_status(cfg, "prefetch", pending_fetch[0]["slug"], entries,
                             llm_up=False,
                             eta_hint=f"prefetch {len(pending_fetch)} book(s)",
                             since=since)
                for entry in pending_fetch:
                    if stop_flag.get("stop"):
                        break
                    write_status(cfg, "prefetch", entry["slug"], _entries(cfg),
                                 llm_up=False, since=since)
                    try:
                        prefetch_one(cfg, entry)
                    except Exception as e:
                        log.warning("prefetch %s failed (isolated): %s",
                                    entry["slug"], e)
                continue  # re-evaluate phases with fresh state
            # GPU gate: paused or outside the allowed quiet-hours window ->
            # status + sleep, no GPU work. Prefetch above (CPU only) runs on,
            # per the module contract.
            if gpu_blocked(cfg):
                reason = "paused" if getattr(cfg, "paused", False) else "quiet hours"
                write_status(cfg, "paused", None, _entries(cfg), llm_up=False,
                             eta_hint=reason)
                if cfg.once:
                    return {"paused": True}
                _sleep(cfg, cfg.poll_s)
                continue
            # 2. LLM first (sequential mode: one book end-to-end instead)
            entries = _entries(cfg)
            if getattr(cfg, "phase_mode", "batched") == "sequential":
                if _sequential_step(cfg, entries, stop_flag):
                    continue
            else:
                llm = _llm_pending(cfg, entries)
                cap = getattr(cfg, "max_books_per_llm_phase", None)
                if cap is not None:
                    llm = llm[:cap]
                if llm:
                    llm_phase(cfg, llm, stop_flag)
                    continue
            # 3. audio when no LLM work pending
            entries = _entries(cfg)
            if _llm_pending(cfg, entries):
                continue  # new arrivals during audio bookkeeping -> LLM first
            audio = _audio_pending(cfg, entries)
            if audio:
                audio_phase(cfg, audio, stop_flag)
                continue
            # 4. idle
            entries = _entries(cfg)
            write_status(cfg, "idle", None, entries, llm_up=False,
                         eta_hint=None)
            if cfg.once:
                return {"done": [e["slug"] for e in entries if _is_done(cfg, e["slug"])],
                        "failed": [e["slug"] for e in entries if _book_failed(cfg, e["slug"])]}
            _sleep(cfg, cfg.poll_s)
    finally:
        try:
            signal.signal(signal.SIGTERM, old_term)
        except (OSError, ValueError):
            pass
        try:
            signal.signal(signal.SIGINT, old_int)
        except (OSError, ValueError):
            pass


# ── CLI ─────────────────────────────────────────────────────────────

def _add_run_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--root", required=True)
    p.add_argument("--catalog", default=None)
    p.add_argument("--poll-s", type=float, default=20.0)
    p.add_argument("--once", action="store_true")
    p.add_argument("--llm-model", default="Qwen/Qwen3.5-9B")
    p.add_argument("--vllm-bin", default="vllm")
    p.add_argument("--port", type=int, default=8100)
    p.add_argument("--served-name", default="qwen3.5-9b")
    p.add_argument("--tts", choices=("qwen", "chatterbox"), default="qwen")
    p.add_argument("--tts-python", default=None)
    p.add_argument("--cast-python", default=None)
    p.add_argument("--max-retries", type=int, default=2)
    p.add_argument("--max-vram-util", type=float, default=0.90)
    p.add_argument("--max-model-len", type=int, default=8192)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(prog="firebrat_cast.scheduler")
    sub = p.add_subparsers(dest="cmd", required=True)
    pr = sub.add_parser("run")
    _add_run_args(pr)
    ps = sub.add_parser("submit")
    ps.add_argument("--root", required=True)
    ps.add_argument("--file", default=None)
    ps.add_argument("--entry-json", default=None)
    ps.add_argument("--slug", default=None)
    ps.add_argument("--gutenberg", default=None)
    ps.add_argument("--title", default=None)
    ps.add_argument("--author", default=None)
    ps.add_argument("--died", default=None)
    ps.add_argument("--category", default=None)
    ps.add_argument("--language", default=None)
    ps.add_argument("--description", default=None)
    ps.add_argument("--sourceUrl", default=None)
    pt = sub.add_parser("status")
    pt.add_argument("--root", required=True)
    return p.parse_args(argv)


def _entry_from_submit(a: argparse.Namespace) -> dict:
    import json as _json

    if a.entry_json:
        return _json.loads(a.entry_json)
    if a.file:
        from firebrat_cast.fetch import read_json

        obj = read_json(a.file)
        if isinstance(obj, list) and len(obj) == 1:
            return obj[0]
        return obj
    if a.slug and a.gutenberg:
        entry: dict = {"slug": a.slug, "gutenberg": a.gutenberg}
        for k in ("title", "author", "died", "category", "language",
                  "description", "sourceUrl"):
            v = getattr(a, k)
            if v is not None:
                entry[k] = v
        return entry
    raise ValueError("submit needs --entry-json JSON, --file PATH, or --slug + --gutenberg")


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(message)s")
    a = parse_args(argv)
    if a.cmd == "submit":
        try:
            path = submit_entry(os.path.expanduser(a.root), _entry_from_submit(a))
        except Exception as e:
            print(f"submit failed: {e}", file=sys.stderr, flush=True)
            return 1
        print(path, flush=True)
        return 0
    if a.cmd == "status":
        import json as _json

        root = os.path.expanduser(a.root)
        try:
            from firebrat_cast.fetch import read_json

            payload = read_json(status_path(root))
        except (OSError, ValueError):
            entries = list_inbox(root)
            payload = {"phase": "idle", "current_book": None,
                       "queue": {"waiting_cast": [], "waiting_audio": [],
                                 "done": [], "failed": []},
                       "since": None, "llm_server": {"up": False, "port": 8100},
                       "eta_hint": None,
                       "note": "no scheduler_status.json yet"}
            _ = entries
        print(_json.dumps(payload, indent=2), flush=True)
        return 0
    # run
    cfg = SchedulerConfig(
        root=os.path.expanduser(a.root), catalog=a.catalog,
        poll_s=a.poll_s, once=a.once, llm_model=a.llm_model,
        vllm_bin=a.vllm_bin, port=a.port, served_name=a.served_name,
        tts=a.tts, tts_python=a.tts_python, cast_python=a.cast_python,
        max_retries=a.max_retries, max_vram_util=a.max_vram_util,
        max_model_len=a.max_model_len)
    try:
        run_loop(cfg)
    except Exception as e:
        print(f"scheduler failed: {e}", file=sys.stderr, flush=True)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

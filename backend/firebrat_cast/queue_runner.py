"""Wave scheduler + per-book state machine: fetch -> segment -> cast -> synth -> package.

CLI: ``python -m firebrat_cast.queue_runner --catalog catalog.json --root ~/community-books
[--wave-size 2] [--llm-backend local|external] [--tts qwen|chatterbox] [--only slug] [--dry-run]``

Waves minimise model swaps: wave = next N pending books, shortest first
(by cleaned-text word estimate). The LLM loads once -> casts the whole wave
-> unloads (VRAM verified free) -> the TTS engine loads once -> synthesizes
one book at a time -> unloads -> each book zips. With an external LLM
backend, the next wave's casting runs in a thread while the current wave
synthesizes.

Per-book state ``jobs/<slug>/state.json`` (atomic writes, resumable, safe to
kill any time), logs ``jobs/<slug>/log.txt``, progress ``jobs/<slug>/
progress.json`` ``{stage, percent, eta_s}`` plus a ``<root>/progress.json``
aggregate. Package output lives in ``<root>/out/<slug>``.
"""
from __future__ import annotations

import argparse
import subprocess
import concurrent.futures
import datetime
import logging
import os
import sys
import time
from dataclasses import dataclass, field

log = logging.getLogger("firebrat_cast.queue")

STAGES = ("fetch", "segment", "cast", "synth", "package")


@dataclass
class RunnerConfig:
    catalog: str
    root: str
    wave_size: int = 2
    llm_backend: str = "local"  # local (in-process GPU) | external (API, overlappable)
    tts: str = "qwen"            # qwen | chatterbox
    only: str | None = None
    dry_run: bool = False
    min_vram_gb: float = 10.0
    llm_python: str | None = None  # interpreter for the cast stage (own venv); None = in-process
    tts_python: str | None = None  # interpreter for the synth stage (own venv); None = in-process
    hooks: dict = field(default_factory=dict)  # stage fakes / factories for tests


# ── paths / state ─────────────────────────────────────────────────────

def jobs_dir(root: str, slug: str) -> str:
    return os.path.join(root, "jobs", slug)


def work_dir(root: str, slug: str) -> str:
    return os.path.join(root, "out", slug)


def load_catalog(path: str) -> list[dict]:
    from firebrat_cast.fetch import read_json, validate_entry

    raw = read_json(path)
    if not isinstance(raw, list):
        raise ValueError(f"Catalog must be a list of entries: {path}")
    return [validate_entry(e) for e in raw]


def load_state(root: str, slug: str) -> dict:
    from firebrat_cast.fetch import read_json

    path = os.path.join(jobs_dir(root, slug), "state.json")
    try:
        state = read_json(path)
        return state if isinstance(state, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(root: str, slug: str, state: dict) -> None:
    from firebrat_cast.fetch import write_json_atomic

    state = {**state, "slug": slug, "updated_at": datetime.datetime.utcnow().isoformat() + "Z"}
    write_json_atomic(os.path.join(jobs_dir(root, slug), "state.json"), state)


def is_done(root: str, slug: str) -> bool:
    state = load_state(root, slug)
    if state.get("stage") == "package" and state.get("status") == "done":
        return os.path.isfile(os.path.join(work_dir(root, slug), "built.json"))
    return False


def log_job(root: str, slug: str, msg: str) -> None:
    os.makedirs(jobs_dir(root, slug), exist_ok=True)
    stamp = datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z"
    with open(os.path.join(jobs_dir(root, slug), "log.txt"), "a", encoding="utf-8") as f:
        f.write(f"{stamp} {msg}\n")
    log.info("[%s] %s", slug, msg)


def write_progress(root: str, slug: str, stage: str, percent: float, eta_s: float | None) -> None:
    from firebrat_cast.fetch import write_json_atomic

    write_json_atomic(os.path.join(jobs_dir(root, slug), "progress.json"),
                      {"stage": stage, "percent": round(percent, 1),
                       "eta_s": None if eta_s is None else round(eta_s, 1)})


def write_root_progress(root: str, books: list[dict]) -> None:
    from firebrat_cast.fetch import write_json_atomic

    done = sum(1 for b in books if b.get("status") == "done")
    write_json_atomic(os.path.join(root, "progress.json"),
                      {"total": len(books), "done": done, "books": books})


# ── ordering ──────────────────────────────────────────────────────────

def book_size_chars(entry: dict, root: str) -> int | None:
    """Cleaned-text length from raw_pages.json, or None when not yet fetched."""
    raw_path = os.path.join(work_dir(root, entry["slug"]), "raw", "raw_pages.json")
    if not os.path.isfile(raw_path):
        return None
    try:
        from firebrat_cast.fetch import read_json

        pages = read_json(raw_path).get("pages", [])
        return sum(len(p.get("text") or "") for p in pages)
    except (OSError, ValueError):
        return None


def order_pending(entries: list[dict], root: str) -> list[dict]:
    """Shortest first by cleaned-text chars; unfetched books last (catalog order)."""
    sized = [(book_size_chars(e, root), i, e) for i, e in enumerate(entries)]
    return [e for _, _, e in sorted(sized, key=lambda t: (t[0] is None, t[0] or 0, t[1]))]


def words_estimate(chars: int | None) -> str:
    return "?" if chars is None else f"~{round(chars / 5):,}"


# ── default stage implementations (lazy sibling imports) ──────────────

def _need(mod: str, what: str):
    try:
        return __import__(mod, fromlist=["*"])
    except ImportError as e:
        raise RuntimeError(f"Stage {what!r} needs firebrat_cast.{mod.split('.')[-1]} "
                           f"(owned by another worker, not landed yet): {e}")


def default_fetch(entry: dict, root: str) -> dict:
    from firebrat_cast.fetch import fetch_book

    return fetch_book(entry, root)


def default_segment(entry: dict, root: str) -> dict:
    """segment_pages(raw pages) -> work/segments.json (stable (page, idx) keys)."""
    from firebrat_cast.fetch import read_json, write_json_atomic

    mod = _need("firebrat_cast.segmenter", "segment")
    raw = read_json(os.path.join(work_dir(root, entry["slug"]), "raw", "raw_pages.json"))
    segs = mod.segment_pages(raw.get("pages", []))
    out = os.path.join(work_dir(root, entry["slug"]), "segments.json")
    write_json_atomic(out, {"book_id": entry["slug"], "segments": segs})
    return {"segments": len(segs), "path": out}


def make_llm_backend(kind: str):
    mod = _need("firebrat_cast.llm", "cast")
    if kind == "external":
        return mod.OpenAICompatBackend()
    return mod.LocalHFBackend()


def default_cast_one(entry: dict, root: str, backend) -> dict:
    """cast_book(raw_pages_path, out_path, backend, meta) -> cast.json (resumable)."""
    mod = _need("firebrat_cast.cast", "cast")
    slug = entry["slug"]
    out = os.path.join(work_dir(root, slug), "cast.json")
    meta = {"book_id": slug, "title": entry.get("title", slug), "author": entry.get("author", "")}
    return mod.cast_book(os.path.join(work_dir(root, slug), "raw", "raw_pages.json"), out, backend, meta)


def make_tts_engine(kind: str):
    if kind == "chatterbox":
        mod = _need("firebrat_cast.tts_chatterbox", "synth")
        return mod.ChatterboxVoiceEngine()
    mod = _need("firebrat_cast.tts_qwen", "synth")
    return mod.QwenVoiceEngine()


def default_synth_one(entry: dict, root: str, engine, on_progress=None) -> dict:
    """compile_cast -> compiled.json, then synthesize_book -> package audio."""
    from firebrat_cast.fetch import read_json, write_json_atomic

    slug = entry["slug"]
    work = work_dir(root, slug)
    raw_path = os.path.join(work, "raw", "raw_pages.json")
    cast_path = os.path.join(work, "cast.json")
    compiled_path = os.path.join(work, "compiled.json")
    if not os.path.isfile(compiled_path):
        mod = _need("firebrat_cast.compile_cast", "synth")
        mod.compile_cast_file(raw_path, cast_path, compiled_path)
        # keep a copy where convert.py/manifest tooling expects it
        write_json_atomic(os.path.join(work, "raw", "compiled.json"), read_json(compiled_path))
    from firebrat_cast.synth import synthesize_book

    return synthesize_book(compiled_path, work, engine, on_progress=on_progress)


def default_package(entry: dict, root: str) -> dict:
    from firebrat_cast.packager import zip_package

    return {"zip": zip_package(work_dir(root, entry["slug"]))}


# ── state machine ─────────────────────────────────────────────────────

def _stage_status(state: dict, stage: str) -> str:
    return (state.get("done") or {}).get(stage, "no")


def do_stage(cfg: RunnerConfig, entry: dict, stage: str, fn, t0: float) -> dict:
    """Run one stage unless state.json says it's done; record state+progress."""
    slug = entry["slug"]
    state = load_state(cfg.root, slug)
    if _stage_status(state, stage) == "done":
        return {"skipped": True}
    idx = STAGES.index(stage)
    write_progress(cfg.root, slug, stage, idx / len(STAGES) * 100, None)
    log_job(cfg.root, slug, f"stage {stage} started")
    try:
        result = fn() or {}
    except Exception as e:
        state = load_state(cfg.root, slug)
        state["stage"] = stage
        state["status"] = "failed"
        state["error"] = str(e)
        save_state(cfg.root, slug, state)
        log_job(cfg.root, slug, f"stage {stage} FAILED: {e}")
        raise
    state = load_state(cfg.root, slug)
    done = dict(state.get("done") or {})
    done[stage] = "done"
    state["done"] = done
    state["stage"] = stage
    state["status"] = "done" if stage == "package" else "running"
    save_state(cfg.root, slug, state)
    elapsed = time.monotonic() - t0
    frac = (idx + 1) / len(STAGES)
    eta = elapsed / frac * (1 - frac) if frac > 0 else None
    write_progress(cfg.root, slug, stage if stage != "package" else "done", frac * 100, eta)
    log_job(cfg.root, slug, f"stage {stage} done ({result if isinstance(result, dict) else 'ok'})")
    return {"skipped": False, "result": result}


def cast_wave(cfg: RunnerConfig, wave: list[dict], backend, failed: set | None = None) -> None:
    """Cast every book in the wave needing it, sharing one loaded LLM backend."""
    failed = failed if failed is not None else set()
    t0 = time.monotonic()
    for entry in wave:
        if entry["slug"] in failed:
            continue
        try:
            do_stage(cfg, entry, "cast",
                     lambda e=entry: cfg.hooks.get("cast_one", default_cast_one)(e, cfg.root, backend), t0)
        except Exception:
            failed.add(entry["slug"])  # recorded in state.json by do_stage


def synth_wave(cfg: RunnerConfig, wave: list[dict], engine, failed: set | None = None) -> None:
    """Synthesize the wave's books one at a time with one loaded TTS engine."""
    failed = failed if failed is not None else set()
    t0 = time.monotonic()
    for entry in wave:
        if entry["slug"] in failed:
            continue
        slug = entry["slug"]

        def run(e=entry, s=slug):
            fn = cfg.hooks.get("synth_one", default_synth_one)
            try:
                return fn(e, cfg.root, engine,
                          on_progress=lambda frac, sec: write_progress(
                              cfg.root, s, "synth",
                              (STAGES.index("synth") + frac) / len(STAGES) * 100, None))
            except TypeError:  # fake hooks without on_progress kwarg
                return fn(e, cfg.root, engine)

        try:
            do_stage(cfg, entry, "synth", run, t0)
        except Exception:
            failed.add(entry["slug"])  # recorded in state.json by do_stage


def run_stage_proc(cfg: RunnerConfig, python: str, command: str, wave: list[dict]) -> None:
    """Run a GPU stage as a fresh process in its own venv so VRAM is fully released afterwards."""
    cmd = [python, "-m", "firebrat_cast.stage_proc", command, "--catalog", cfg.catalog, "--root", cfg.root,
           "--slugs", ",".join(e["slug"] for e in wave), "--llm-backend", cfg.llm_backend, "--tts", cfg.tts]
    env = dict(os.environ, PYTHONPATH=os.pathsep.join(
        p for p in (os.path.dirname(os.path.dirname(os.path.abspath(__file__))), os.environ.get("PYTHONPATH", "")) if p))
    subprocess.run(cmd, check=True, env=env)


def run_wave(cfg: RunnerConfig, wave: list[dict]) -> set:
    """One wave: fetch+segment each, cast together, synthesize together, package each."""
    failed: set = set()
    t0 = time.monotonic()
    for entry in wave:
        for stage, key in (("fetch", "fetch"), ("segment", "segment")):
            try:
                fn = cfg.hooks.get(key, default_fetch if key == "fetch" else default_segment)
                do_stage(cfg, entry, stage, lambda e=entry, f=fn: f(e, cfg.root), t0)
            except Exception:
                failed.add(entry["slug"])
                break
    # — cast phase: one LLM load per wave —
    backend = cfg.hooks.get("backend")
    owned_backend = backend is None and not cfg.dry_run
    if owned_backend and cfg.llm_python:
        from firebrat_cast import gpu as _gpu

        with _gpu.gpu_stage("cast", cfg.min_vram_gb if cfg.llm_backend == "local" else 0.0):
            run_stage_proc(cfg, cfg.llm_python, "cast-wave", [e for e in wave if e["slug"] not in failed])
    elif owned_backend:
        from firebrat_cast import gpu as _gpu

        with _gpu.gpu_stage("cast", cfg.min_vram_gb if cfg.llm_backend == "local" else 0.0):
            backend = (cfg.hooks.get("llm_factory", make_llm_backend))(cfg.llm_backend)
            backend.load()
            try:
                cast_wave(cfg, wave, backend, failed)
            finally:
                backend.unload()
                free = _gpu.free_vram_gb()
                free_msg = f"{free:.1f} GiB" if free is not None else "unknown (no GPU visible)"
                log_job(cfg.root, wave[0]["slug"], f"LLM unloaded, free VRAM: {free_msg}")
    else:
        cast_wave(cfg, wave, backend, failed)
    # — synth phase: one TTS load per wave —
    engine = cfg.hooks.get("engine")
    owned_engine = engine is None and not cfg.dry_run
    if owned_engine and cfg.tts_python:
        from firebrat_cast import gpu as _gpu

        with _gpu.gpu_stage("synth", cfg.min_vram_gb):
            run_stage_proc(cfg, cfg.tts_python, "synth-wave", [e for e in wave if e["slug"] not in failed])
        failed |= {e["slug"] for e in wave if _stage_status(load_state(cfg.root, e["slug"]), "synth") == "failed"}
    elif owned_engine:
        from firebrat_cast import gpu as _gpu

        with _gpu.gpu_stage("synth", cfg.min_vram_gb):
            engine = (cfg.hooks.get("tts_factory", make_tts_engine))(cfg.tts)
            engine.load()
            try:
                synth_wave(cfg, wave, engine, failed)
            finally:
                engine.unload()
    else:
        synth_wave(cfg, wave, engine, failed)
    for entry in wave:
        if entry["slug"] in failed:
            continue
        try:
            do_stage(cfg, entry, "package",
                     lambda e=entry: cfg.hooks.get("package", default_package)(e, cfg.root), t0)
        except Exception:
            failed.add(entry["slug"])
    return failed


def plan_waves(entries: list[dict], wave_size: int) -> list[list[dict]]:
    return [entries[i:i + wave_size] for i in range(0, len(entries), wave_size)]


def prefetch_all(cfg: RunnerConfig, entries: list[dict]) -> set:
    """CPU-only fetch+segment for every pending book up front, so GPU stages never wait on downloads
    and the shortest-first ordering uses real text sizes."""
    bad: set = set()
    t0 = time.monotonic()
    for entry in entries:
        for stage, key, default in (("fetch", "fetch", default_fetch), ("segment", "segment", default_segment)):
            try:
                fn = cfg.hooks.get(key, default)
                do_stage(cfg, entry, stage, lambda e=entry, f=fn: f(e, cfg.root), t0)
            except Exception:
                bad.add(entry["slug"])
                break
    return bad


def run(cfg: RunnerConfig) -> dict:
    """Run all pending books in waves. Returns {waves, books, failed}."""
    entries = load_catalog(cfg.catalog)
    if cfg.only:
        entries = [e for e in entries if e["slug"] == cfg.only]
        if not entries:
            raise ValueError(f"--only {cfg.only!r} not in catalog")
    pending = [e for e in entries if not is_done(cfg.root, e["slug"])]
    prefetch_failed = set() if cfg.dry_run else prefetch_all(cfg, pending)
    pending = [e for e in pending if e["slug"] not in prefetch_failed]
    ordered = order_pending(pending, cfg.root)
    waves = plan_waves(ordered, max(1, cfg.wave_size))
    summary = [{"slug": e["slug"], "words": words_estimate(book_size_chars(e, cfg.root)),
                "gutenberg": e["gutenberg"]} for w in waves for e in w]
    print(f"Plan: {len(ordered)} pending in {len(waves)} wave(s) "
          f"(llm={cfg.llm_backend}, tts={cfg.tts}):", flush=True)
    for i, w in enumerate(waves):
        print(f"  wave {i + 1}: " + ", ".join(
            f"{e['slug']} ({words_estimate(book_size_chars(e, cfg.root))} words)" for e in w), flush=True)
    if cfg.dry_run:
        return {"waves": len(waves), "books": summary, "failed": [], "dry_run": True}
    failed: set = set(prefetch_failed)
    overview: list[dict] = []
    if cfg.llm_backend == "external":
        # Overlap: cast wave k+1 in a thread while wave k synthesizes.
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            future = None
            for i, wave in enumerate(waves):
                if future is not None:
                    future.result()  # next wave's cast already done by the overlap thread
                    future = None
                # fetch+segment inline, then cast inline (cheap: external LLM)
                t0 = time.monotonic()
                for entry in wave:
                    try:
                        do_stage(cfg, entry, "fetch",
                                 lambda e=entry: cfg.hooks.get("fetch", default_fetch)(e, cfg.root), t0)
                        do_stage(cfg, entry, "segment",
                                 lambda e=entry: cfg.hooks.get("segment", default_segment)(e, cfg.root), t0)
                    except Exception:
                        failed.add(entry["slug"])
                backend = cfg.hooks.get("backend")
                if backend is None and not cfg.dry_run:
                    backend = (cfg.hooks.get("llm_factory", make_llm_backend))(cfg.llm_backend)
                cast_wave(cfg, wave, backend, failed)
                if i + 1 < len(waves):
                    nxt = waves[i + 1]
                    future = ex.submit(_cast_wave_thread, cfg, nxt, backend)
                try:
                    engine = cfg.hooks.get("engine")
                    if engine is None:
                        from firebrat_cast import gpu as _gpu

                        with _gpu.gpu_stage("synth", cfg.min_vram_gb):
                            engine = (cfg.hooks.get("tts_factory", make_tts_engine))(cfg.tts)
                            engine.load()
                            try:
                                synth_wave(cfg, wave, engine, failed)
                            finally:
                                engine.unload()
                    else:
                        synth_wave(cfg, wave, engine, failed)
                except Exception:
                    pass
                if future is not None and i + 1 == len(waves):
                    future.result()
                for entry in wave:
                    if entry["slug"] in failed:
                        continue
                    try:
                        do_stage(cfg, entry, "package",
                                 lambda e=entry: cfg.hooks.get("package", default_package)(e, cfg.root), t0)
                    except Exception:
                        failed.add(entry["slug"])
                for entry in wave:
                    st = load_state(cfg.root, entry["slug"])
                    overview.append({"slug": entry["slug"], "stage": st.get("stage"),
                                     "status": st.get("status")})
                    if st.get("status") == "failed":
                        failed.add(entry["slug"])
    else:
        for wave in waves:
            try:
                failed |= run_wave(cfg, wave)
            except Exception as e:
                log.error("Wave failed, stopping the queue (rerun resumes): %s", e)
                failed |= {x["slug"] for x in wave}
                overview.extend({"slug": x["slug"], "stage": "wave", "status": "failed"} for x in wave)
                break
            for entry in wave:
                st = load_state(cfg.root, entry["slug"])
                overview.append({"slug": entry["slug"], "stage": st.get("stage"),
                                 "status": st.get("status")})
                if st.get("status") == "failed":
                    failed.add(entry["slug"])
    write_root_progress(cfg.root, overview)
    failed |= {e["slug"] for e in ordered if not is_done(cfg.root, e["slug"])}
    failed_list = sorted(failed)
    ok = sum(1 for e in ordered if is_done(cfg.root, e["slug"]))
    print(f"Done: {ok}/{len(ordered)} books finished, not finished/failed={failed_list}", flush=True)
    return {"waves": len(waves), "books": overview, "failed": failed_list}


def _cast_wave_thread(cfg: RunnerConfig, wave: list[dict], backend) -> None:
    """External-backend overlap worker: fetch+segment+cast the next wave early."""
    failed: set = set()
    t0 = time.monotonic()
    for entry in wave:
        for stage, key in (("fetch", "fetch"), ("segment", "segment")):
            try:
                fn = cfg.hooks.get(key, default_fetch if key == "fetch" else default_segment)
                do_stage(cfg, entry, stage, lambda e=entry, f=fn: f(e, cfg.root), t0)
            except Exception:
                failed.add(entry["slug"])
                break
    cast_wave(cfg, wave, backend, failed)


# ── CLI ─────────────────────────────────────────────────────────────────

def parse_args(argv: list[str] | None = None) -> RunnerConfig:
    p = argparse.ArgumentParser(description="firebrat_cast batch queue runner")
    p.add_argument("--catalog", required=True, help="Catalog JSON (list of slug/gutenberg/... entries)")
    p.add_argument("--root", required=True, help="Work root (src/, out/, jobs/)")
    p.add_argument("--wave-size", type=int, default=2)
    p.add_argument("--llm-backend", choices=("local", "external"), default="local")
    p.add_argument("--tts", choices=("qwen", "chatterbox"), default="qwen")
    p.add_argument("--only", default=None, help="Run a single catalog slug")
    p.add_argument("--dry-run", action="store_true", help="Print the wave plan, run nothing")
    p.add_argument("--min-vram-gb", type=float, default=10.0)
    p.add_argument("--llm-python", default=None, help="Python of the venv for the LLM (cast) stage")
    p.add_argument("--tts-python", default=None, help="Python of the venv for the TTS (synth) stage")
    a = p.parse_args(argv)
    if a.wave_size < 1:
        p.error("--wave-size must be >= 1")
    return RunnerConfig(catalog=a.catalog, root=os.path.expanduser(a.root), wave_size=a.wave_size,
                        llm_backend=a.llm_backend, tts=a.tts, only=a.only,
                        dry_run=a.dry_run, min_vram_gb=a.min_vram_gb,
                        llm_python=a.llm_python, tts_python=a.tts_python)


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        result = run(parse_args(argv))
    except Exception as e:
        print(f"queue_runner failed: {e}", file=sys.stderr, flush=True)
        return 1
    return 1 if result.get("failed") else 0


if __name__ == "__main__":
    sys.exit(main())

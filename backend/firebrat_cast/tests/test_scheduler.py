"""Scheduler tests: pure fakes, no GPU/network/subprocess."""
import json
import os

import pytest

from firebrat_cast import queue_runner as qr
from firebrat_cast import scheduler as sch


def _entry(slug, gid):
    return {"slug": slug, "gutenberg": gid, "title": slug, "author": "Anon",
            "died": 1900, "category": "fiction", "language": "en",
            "description": "d", "sourceUrl": f"https://www.gutenberg.org/ebooks/{gid}"}


def _mark(root, slug, **done_stages):
    st = qr.load_state(root, slug)
    done = dict(st.get("done") or {})
    for k, v in done_stages.items():
        done[k] = v
    st["done"] = done
    if "status" not in st:
        st["status"] = "running"
    qr.save_state(root, slug, st)


def _write_built(root, slug):
    d = os.path.join(root, "out", slug)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "built.json"), "w") as f:
        json.dump({"slug": slug}, f)


def _mkroot(tmp_path):
    return str(tmp_path)


def _base_cfg(root, **kw):
    hooks: dict = {}
    cfg = sch.SchedulerConfig(root=root, once=True, max_retries=2, hooks=hooks)
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg, hooks


def test_a_cast_then_synth_order():
    """A,B queued -> cast(A),cast(B) then synth(A),synth(B)."""
    import tempfile
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    events = []
    cfg, hooks = _base_cfg(root)

    def prefetch(entry, r):
        events.append(("prefetch", entry["slug"]))
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        events.append(("cast", entry["slug"]))
        _mark(r, entry["slug"], cast="done")

    def run_synth(entry, r):
        events.append(("synth", entry["slug"]))
        _mark(r, entry["slug"], synth="done", package="done")
        _write_built(r, entry["slug"])

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": run_synth,
                  "package": lambda e, r: None,
                  "start_llm": lambda: events.append(("llm_up",)),
                  "stop_llm": lambda: events.append(("llm_down",)),
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    sch.run_loop(cfg)
    kinds = [t for t in events if t[0] in ("cast", "synth")]
    assert kinds == [("cast", "a"), ("cast", "b"), ("synth", "a"), ("synth", "b")]


def test_b_submit_during_audio_never_casts_mid_snapshot():
    """C submitted while synth(A) runs -> synth A,B finish, then cast+synth C."""
    import tempfile
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    # seed A,B fully prefetched + cast so the first phase is audio
    for slug in ("a", "b"):
        _mark(root, slug, fetch="done", segment="done", cast="done")
    events = []
    cfg, hooks = _base_cfg(root)
    c_added = {"done": False}

    def run_synth(entry, r):
        events.append(("synth", entry["slug"]))
        if entry["slug"] == "a" and not c_added["done"]:
            c_added["done"] = True
            sch.submit_entry(r, _entry("c", 3))
        _mark(r, entry["slug"], synth="done", package="done")
        _write_built(r, entry["slug"])

    def prefetch(entry, r):
        events.append(("prefetch", entry["slug"]))
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        events.append(("cast", entry["slug"]))
        _mark(r, entry["slug"], cast="done")

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": run_synth,
                  "package": lambda e, r: None,
                  "start_llm": lambda: events.append(("llm_up",)),
                  "stop_llm": lambda: events.append(("llm_down",)),
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    sch.run_loop(cfg)
    kinds = [t for t in events if len(t) == 2 and t[0] in ("cast", "synth")]
    # synth A,B (snapshot) complete before cast C; then synth C
    assert kinds.index(("synth", "a")) < kinds.index(("synth", "b"))
    assert kinds.index(("synth", "b")) < kinds.index(("cast", "c"))
    assert kinds.index(("cast", "c")) < kinds.index(("synth", "c"))


def test_c_llm_snapshot_frozen():
    """Two books submitted during an LLM phase are NOT added to the running
    snapshot; they are handled in a second LLM phase before audio resumes."""
    import tempfile
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    events = []
    cfg, hooks = _base_cfg(root)
    injected = {"done": False}

    def prefetch(entry, r):
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        events.append(("cast", entry["slug"]))
        if entry["slug"] == "a" and not injected["done"]:
            injected["done"] = True
            sch.submit_entry(r, _entry("c", 3))
            sch.submit_entry(r, _entry("d", 4))
        _mark(r, entry["slug"], cast="done")

    def run_synth(entry, r):
        events.append(("synth", entry["slug"]))
        _mark(r, entry["slug"], synth="done", package="done")
        _write_built(r, entry["slug"])

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": run_synth,
                  "package": lambda e, r: None,
                  "start_llm": lambda: events.append(("llm_up",)),
                  "stop_llm": lambda: events.append(("llm_down",)),
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    sch.run_loop(cfg)
    casts = [t[1] for t in events if len(t) == 2 and t[0] == "cast"]
    synths = [t[1] for t in events if len(t) == 2 and t[0] == "synth"]
    # running snapshot was {a,b}: both cast before c,d
    assert casts[:2] == ["a", "b"]
    assert set(casts[2:]) == {"c", "d"}
    # no synth until all casts done (LLM priority, snapshot rule)
    assert events.index(("synth", synths[0])) > events.index(("cast", "d"))


def test_d_shortest_first_audio():
    """Audio snapshot sorted shortest-first regardless of inbox order."""
    import tempfile
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("c", 3))  # inbox order c,a
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    events = []

    def prefetch(entry, r):
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        _mark(r, entry["slug"], cast="done")

    def run_synth(entry, r):
        events.append(("synth", entry["slug"]))
        _mark(r, entry["slug"], synth="done", package="done")
        _write_built(r, entry["slug"])

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": run_synth,
                  "package": lambda e, r: None,
                  "start_llm": lambda: None, "stop_llm": lambda: None,
                  "gpu_lock": lambda: __import__("contextlib").nullcontext(),
                  # c is longer than a
                  "text_size": lambda e, r: 9000 if e["slug"] == "c" else 100})
    sch.run_loop(cfg)
    assert events == [("synth", "a"), ("synth", "c")]


def test_e_retry_limit_and_isolation():
    """Failing book retried max_retries then marked failed; good book completes."""
    import tempfile
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("bad", 11))
    sch.submit_entry(root, _entry("good", 12))
    cfg, hooks = _base_cfg(root, max_retries=2)
    events = []

    def prefetch(entry, r):
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        events.append(("cast", entry["slug"]))
        if entry["slug"] == "bad":
            raise RuntimeError("boom")
        _mark(r, entry["slug"], cast="done")

    def run_synth(entry, r):
        events.append(("synth", entry["slug"]))
        _mark(r, entry["slug"], synth="done", package="done")
        _write_built(r, entry["slug"])

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": run_synth,
                  "package": lambda e, r: None,
                  "start_llm": lambda: None, "stop_llm": lambda: None,
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    result = sch.run_loop(cfg)
    bad_casts = [t[1] for t in events if len(t) == 2 and t[0] == "cast" and t[1] == "bad"]
    assert bad_casts == ["bad", "bad"]  # exactly max_retries
    assert ("synth", "good") in events
    assert "bad" in result["failed"]
    st = qr.load_state(root, "bad")
    assert st["status"] == "failed"


def test_f_llm_server_always_stopped():
    """stop_llm runs even when cast raises; start/stop balanced."""
    import tempfile
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("x", 5))
    cfg, hooks = _base_cfg(root)
    calls = []

    def prefetch(entry, r):
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        raise RuntimeError("cast boom")

    hooks.update({"prefetch": prefetch, "run_cast": run_cast,
                  "run_synth": lambda e, r: None,
                  "package": lambda e, r: None,
                  "start_llm": lambda: calls.append("start"),
                  "stop_llm": lambda: calls.append("stop"),
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    cfg.max_retries = 1
    sch.run_loop(cfg)
    assert calls == ["start", "stop"]


def test_g_once_exits_when_idle(tmp_path):
    root = _mkroot(tmp_path)
    cfg, hooks = _base_cfg(root)
    hooks.update({"gpu_lock": lambda: __import__("contextlib").nullcontext()})
    # empty inbox, once -> returns promptly
    result = sch.run_loop(cfg)
    assert result is not None


def test_h_status_file_contents_and_atomic(tmp_path):
    root = _mkroot(tmp_path)
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    hooks.update({"prefetch": lambda e, r: _mark(r, e["slug"], fetch="done", segment="done"),
                  "run_cast": lambda e, r: (_mark(r, e["slug"], cast="done"), _write_built(r, e["slug"]) if False else None),
                  "run_synth": lambda e, r: (_mark(r, e["slug"], synth="done", package="done"), _write_built(r, e["slug"])),
                  "package": lambda e, r: None,
                  "start_llm": lambda: None, "stop_llm": lambda: None,
                  "gpu_lock": lambda: __import__("contextlib").nullcontext()})
    sch.run_loop(cfg)
    payload = json.load(open(os.path.join(root, "scheduler_status.json")))
    assert set(payload) >= {"phase", "current_book", "queue", "since", "llm_server", "eta_hint"}
    assert set(payload["queue"]) >= {"waiting_cast", "waiting_audio", "done", "failed"}
    assert set(payload["llm_server"]) >= {"up", "port"}
    leftovers = [f for f in os.listdir(root) if f.endswith(".tmp") or ".tmp-" in f]
    assert leftovers == []


def test_i_submit_validation_and_atomic(tmp_path):
    root = _mkroot(tmp_path)
    with pytest.raises(ValueError):
        sch.submit_entry(root, {"slug": "no-gid"})
    with pytest.raises(ValueError):
        sch.submit_entry(root, {"slug": "x", "gutenberg": -3})
    path = sch.submit_entry(root, _entry("ok", 7))
    assert os.path.isfile(path)
    assert json.load(open(path))["slug"] == "ok"
    inbox = os.path.join(root, "inbox")
    assert not [f for f in os.listdir(inbox) if ".tmp" in f]


def test_import_catalog_skips_existing(tmp_path):
    root = _mkroot(tmp_path)
    sch.submit_entry(root, _entry("a", 1))
    cat = str(tmp_path / "cat.json")
    with open(cat, "w") as f:
        json.dump([_entry("a", 1), _entry("b", 2)], f)
    res = sch.import_catalog(root, cat)
    assert res == {"imported": ["b"], "skipped": ["a"]}
    res2 = sch.import_catalog(root, cat)
    assert res2 == {"imported": [], "skipped": ["a", "b"]}

"""Scheduler settings hot-reload tests: pure fakes, no GPU/network/subprocess."""
import contextlib
import json
import os
import tempfile

from firebrat_cast import catalog as cat
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


def _base_cfg(root, **kw):
    hooks: dict = {}
    cfg = sch.SchedulerConfig(root=root, once=True, max_retries=2, hooks=hooks)
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg, hooks


def _fakes(root_events, box=None):
    """Standard fake hooks; records cast-time model config per slug."""
    events = root_events

    def prefetch(entry, r):
        events.append(("prefetch", entry["slug"]))
        _mark(r, entry["slug"], fetch="done", segment="done")

    def run_cast(entry, r):
        cfg = box["cfg"] if box and "cfg" in box else None
        events.append(("cast", entry["slug"],
                       cfg.llm_model if cfg else None,
                       cfg.served_name if cfg else None))
        _mark(r, entry["slug"], cast="done")

    def run_synth(entry, r):
        cfg = box["cfg"] if box and "cfg" in box else None
        events.append(("synth", entry["slug"], cfg.tts if cfg else None))
        _mark(r, entry["slug"], synth="done")
        _write_built(r, entry["slug"])

    return {"prefetch": prefetch, "run_cast": run_cast,
            "run_synth": run_synth,
            "package": lambda e, r: None,
            "start_llm": lambda: events.append(("llm_up",)),
            "stop_llm": lambda: events.append(("llm_down",)),
            "gpu_lock": lambda: contextlib.nullcontext()}


def test_llm_model_hot_reload_mid_run():
    """Model switch between LLM phases is reflected in vllm_cmd and casts."""
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    box = {"model": "qwen3.5-9b"}
    cfg, hooks = _base_cfg(root)
    box["cfg"] = cfg
    hooks.update(_fakes(events := [], box))
    started_cmds = []
    hooks["start_llm"] = lambda: (events.append(("llm_up",)),
                                  started_cmds.append(list(sch.vllm_cmd(cfg))))


    def run_cast(entry, r):
        events.append(("cast", entry["slug"], cfg.llm_model, cfg.served_name))
        if entry["slug"] == "a":
            # new arrivals + model switch land in the NEXT llm snapshot
            sch.submit_entry(r, _entry("c", 3))
            sch.submit_entry(r, _entry("d", 4))
            box["model"] = "qwen3.5-4b"
        _mark(r, entry["slug"], cast="done")

    hooks["run_cast"] = run_cast
    hooks["settings_provider"] = lambda: {"llm": {"model": box["model"]}}

    sch.run_loop(cfg)
    by_slug = {t[1]: (t[2], t[3]) for t in events if t[0] == "cast"}
    assert by_slug["a"] == ("Qwen/Qwen3.5-9B", "qwen3.5-9b")
    assert by_slug["b"] == ("Qwen/Qwen3.5-9B", "qwen3.5-9b")
    assert by_slug["c"] == ("Qwen/Qwen3.5-4B", "qwen3.5-4b")
    assert by_slug["d"] == ("Qwen/Qwen3.5-4B", "qwen3.5-4b")
    assert started_cmds[0][2] == "Qwen/Qwen3.5-9B"
    assert started_cmds[1][2] == "Qwen/Qwen3.5-4B"
    assert "--served-model-name" in started_cmds[1]
    assert started_cmds[1][started_cmds[1].index("--served-model-name") + 1] == "qwen3.5-4b"


def test_tts_switch_via_provider_field():
    """cfg.settings_provider (field form) switches the synth engine."""
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    box = {"cfg": cfg}
    hooks.update(_fakes(events := [], box))
    cfg.settings_provider = lambda cfg_or_root: {"tts": {"engine": "chatterbox"}}
    sch.run_loop(cfg)
    assert cfg.tts == "chatterbox"
    synths = [t for t in events if t[0] == "synth"]
    assert synths and all(t[2] == "chatterbox" for t in synths)


def test_phase_mode_sequential_runs_books_end_to_end():
    """Sequential: cast+synth each book before starting the next."""
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["settings_provider"] = lambda: {"run_pattern": {"phase_mode": "sequential"}}
    sch.run_loop(cfg)
    kinds = [(t[0], t[1]) for t in events if t[0] in ("cast", "synth")]
    assert kinds == [("cast", "a"), ("synth", "a"),
                     ("cast", "b"), ("synth", "b")]


def test_max_books_per_llm_phase_caps_snapshots():
    """Cap of 2 splits three queued books into 2+1 LLM phases."""
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2), ("c", 3)):
        sch.submit_entry(root, _entry(slug, gid))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["settings_provider"] = lambda: {"max_books_per_llm_phase": 2}
    phases = []
    hooks["start_llm"] = lambda: phases.append(len(phases))
    hooks["run_cast"] = lambda e, r: (events.append(("cast", e["slug"], len(phases) - 1)),
                                      _mark(r, e["slug"], cast="done"))
    sch.run_loop(cfg)
    assert len(phases) == 2
    by_phase = {}
    for t in events:
        if t[0] == "cast":
            by_phase.setdefault(t[2], []).append(t[1])
    assert by_phase == {0: ["a", "b"], 1: ["c"]}


def test_audio_order_fifo_keeps_inbox_order():
    """fifo audio ignores text size; default stays shortest-first."""
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("c", 3))  # inbox arrival order c, a
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["settings_provider"] = lambda: {"run_pattern": {"audio_order": "fifo"}}
    hooks["text_size"] = lambda e, r: 9000 if e["slug"] == "c" else 100
    sch.run_loop(cfg)
    assert [t[1] for t in events if t[0] == "synth"] == ["c", "a"]


def test_paused_skips_gpu_but_allows_prefetch():
    """Paused: status phase 'paused', CPU prefetch runs, no GPU work."""
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["settings_provider"] = lambda: {"run_pattern": {"paused": True}}
    result = sch.run_loop(cfg)
    assert result == {"paused": True}
    assert ("prefetch", "a") in events  # CPU work still allowed
    assert not [t for t in events if t[0] in ("cast", "synth", "llm_up")]
    payload = json.load(open(os.path.join(root, "scheduler_status.json")))
    assert payload["phase"] == "paused"


def test_quiet_hours_block_and_allow():
    """Inside the quiet window GPU waits; outside it work proceeds."""
    # blocked: 12:00 inside 00:00-23:59
    root = tempfile.mkdtemp()
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["settings_provider"] = lambda: {
        "run_pattern": {"quiet_hours": {"start": "00:00", "end": "23:59"}}}
    hooks["now_hm"] = lambda: "12:00"
    assert sch.run_loop(cfg) == {"paused": True}
    assert not [t for t in events if t[0] in ("cast", "synth", "llm_up")]
    # allowed: 12:00 outside 13:00-14:00 -> full run
    root2 = tempfile.mkdtemp()
    sch.submit_entry(root2, _entry("a", 1))
    cfg2, hooks2 = _base_cfg(root2)
    hooks2.update(_fakes(events2 := [], {"cfg": cfg2}))
    hooks2["settings_provider"] = lambda: {
        "run_pattern": {"quiet_hours": {"start": "13:00", "end": "14:00"}}}
    hooks2["now_hm"] = lambda: "12:00"
    sch.run_loop(cfg2)
    assert ("cast", "a", cfg2.llm_model, cfg2.served_name) in events2
    assert [t[1] for t in events2 if t[0] == "synth"] == ["a"]


def test_quiet_hours_overnight_window_unit():
    """22:00-06:00 blocks 23:30 and 05:59, allows 06:00 and 12:00."""
    cfg, _ = _base_cfg(tempfile.mkdtemp())
    cfg.quiet_hours = ("22:00", "06:00")
    for hm, want in (("23:30", True), ("05:59", True),
                     ("06:00", False), ("12:00", False), ("22:00", True)):
        cfg.hooks["now_hm"] = lambda hm=hm: hm
        assert sch._in_quiet_hours(cfg) is want, hm


def test_invalid_settings_file_falls_back_to_defaults():
    """Garbage file: warning + defaults, run still completes."""
    root = tempfile.mkdtemp()
    with open(os.path.join(root, "server_settings.json"), "w") as f:
        f.write("{not valid json")
    sch.submit_entry(root, _entry("a", 1))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    result = sch.run_loop(cfg)
    assert cfg.llm_model == "Qwen/Qwen3.5-9B"  # CLI default untouched
    assert cfg.served_name == "qwen3.5-9b"
    assert cfg.phase_mode == "batched" and cfg.paused is False
    assert result["done"] == ["a"]


def test_invalid_settings_values_fall_back_to_defaults():
    """Unknown ids / out-of-range values reset to defaults with a warning."""
    root = tempfile.mkdtemp()
    cfg, hooks = _base_cfg(root)
    hooks["settings_provider"] = lambda: {
        "llm": {"model": "bogus-99b"},
        "tts": {"engine": "bogus-tts"},
        "run_pattern": {"phase_mode": "bogus", "max_books_per_llm_phase": 99,
                        "audio_order": "bogus", "paused": "maybe",
                        "quiet_hours": {"start": "xx", "end": "yy"}}}
    view = sch.refresh_settings(cfg)
    assert cfg.llm_model == "Qwen/Qwen3.5-9B"
    assert cfg.served_name == "qwen3.5-9b"
    assert cfg.tts == "qwen"
    assert cfg.phase_mode == "batched"
    assert cfg.max_books_per_llm_phase == 4  # Decision 3 default
    assert cfg.audio_order == "shortest_first"
    assert cfg.paused is False and cfg.quiet_hours is None
    assert view["phase_mode"] == "batched"


def test_no_settings_source_leaves_cli_values_alone():
    """No provider + no file: CLI-passed model values survive refresh."""
    root = tempfile.mkdtemp()  # empty dir, no settings file anywhere near
    cfg, _ = _base_cfg(root, llm_model="Custom/Model",
                       served_name="custom", tts="chatterbox")
    sch.refresh_settings(cfg)
    assert (cfg.llm_model, cfg.served_name, cfg.tts) == (
        "Custom/Model", "custom", "chatterbox")


def test_catalog_lookups_and_availability():
    """Ids match INTEGRATION2; availability reads the HF hub cache only."""
    assert cat.get_llm("qwen3.5-9b")["served_name"] == "qwen3.5-9b"
    assert cat.get_llm("qwen3.5-4b")["hf_repo"] == "Qwen/Qwen3.5-4B"
    assert cat.get_llm("nope") is None
    assert cat.get_tts("qwen3-tts-1.7b") is not None
    assert cat.get_tts("chatterbox") is not None
    assert cat.get_tts("nope") is None
    assert cat.tts_kind("qwen3-tts-1.7b") == "qwen"
    assert cat.tts_kind("qwen3-tts-0.6b") == "qwen"
    assert cat.tts_kind("chatterbox") == "chatterbox"
    assert cat.tts_kind("bogus") is None
    home = tempfile.mkdtemp()
    snap = os.path.join(home, "hub", "models--Qwen--Qwen3.5-9B",
                        "snapshots", "abc123")
    os.makedirs(snap)
    avail = cat.availability(home)
    assert avail["llm"] == {"qwen3.5-9b": True, "qwen3.5-4b": False}
    assert avail["tts"] == {"qwen3-tts-1.7b": False,
                            "qwen3-tts-0.6b": False, "chatterbox": False}
    opts = cat.all_options(home)
    by_id = {m["id"]: m for m in opts["llm"]}
    assert by_id["qwen3.5-9b"]["available"] is True
    assert by_id["qwen3.5-9b"]["vram_gb"] > 0
    assert "description" in by_id["qwen3.5-4b"]
    assert cat.model_available("Qwen/Missing", home) is False
    assert cat.model_available("Qwen/Missing", "/nonexistent-dir-xyz") is False


def test_settings_file_env_overrides_root(tmp_path, monkeypatch):
    """Decision 2: FIREBRAT_SETTINGS_FILE wins, else <root>/server_settings.json."""
    root = tmp_path / "cast"
    root.mkdir()
    other = tmp_path / "data" / "server_settings.json"
    other.parent.mkdir()
    other.write_text(json.dumps({"llm": {"model": "qwen3.5-4b", "quantization": "fp8"},
                                 "tts": {"engine": "chatterbox"},
                                 "run_pattern": {"phase_mode": "sequential",
                                                 "max_books_per_llm_phase": 2,
                                                 "audio_order": "fifo", "paused": False,
                                                 "quiet_hours": None}}))
    monkeypatch.delenv("FIREBRAT_SETTINGS_FILE", raising=False)
    assert sch.settings_path(str(root)) == str(root / "server_settings.json")
    monkeypatch.setenv("FIREBRAT_SETTINGS_FILE", str(other))
    cfg, _ = _base_cfg(str(root))
    sch.refresh_settings(cfg)
    assert cfg.served_name == "qwen3.5-4b" and cfg.tts == "chatterbox"
    assert cfg.phase_mode == "sequential" and cfg.max_books_per_llm_phase == 2


def test_defaults_match_decisions():
    rp = sch.defaults()["run_pattern"]
    assert rp == {"phase_mode": "batched", "max_books_per_llm_phase": 4,
                  "audio_order": "shortest_first", "paused": False,
                  "quiet_hours": None}


def test_priority_file_reorders_llm_and_audio():
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2), ("c", 3)):
        sch.submit_entry(root, _entry(slug, gid))
    with open(os.path.join(root, "priority.json"), "w") as f:
        json.dump({"top": ["c"]}, f)
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    hooks["text_size"] = lambda e, r: {"a": 1, "b": 2, "c": 999}[e["slug"]]
    sch.run_loop(cfg)
    assert [t[1] for t in events if t[0] == "cast"][0] == "c"
    assert [t[1] for t in events if t[0] == "synth"] == ["c", "a", "b"]


def test_cancel_flag_skips_book():
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    os.makedirs(os.path.join(root, "cancel"))
    open(os.path.join(root, "cancel", "a"), "w").close()
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    sch.run_loop(cfg)
    assert [t[1] for t in events if t[0] in ("cast", "synth")] == ["b", "b"]
    assert ("prefetch", "a") not in events


def test_pause_mid_snapshot_stops_after_current_book():
    root = tempfile.mkdtemp()
    for slug, gid in (("a", 1), ("b", 2)):
        sch.submit_entry(root, _entry(slug, gid))
    cfg, hooks = _base_cfg(root)
    hooks.update(_fakes(events := [], {"cfg": cfg}))
    box = {"paused": False}
    hooks["settings_provider"] = lambda: {"run_pattern": {"paused": box["paused"]}}

    def run_cast(entry, r):
        events.append(("cast", entry["slug"]))
        box["paused"] = True
        _mark(r, entry["slug"], cast="done")

    hooks["run_cast"] = run_cast
    sch.run_loop(cfg)
    assert [t[1] for t in events if t[0] == "cast"] == ["a"]

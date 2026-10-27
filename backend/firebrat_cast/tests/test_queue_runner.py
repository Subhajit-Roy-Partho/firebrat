"""queue_runner tests: fake catalog + injected stage hooks, tiny fake books."""
import json
import os

import pytest

from firebrat_cast import queue_runner as qr


def _catalog(tmp_path, entries):
    p = str(tmp_path / "catalog.json")
    with open(p, "w") as f:
        json.dump(entries, f)
    return p


def _entry(slug, gid):
    return {"slug": slug, "gutenberg": gid, "title": slug, "author": "Anon",
            "died": 1900, "category": "fiction", "language": "en",
            "description": "d", "sourceUrl": f"https://www.gutenberg.org/ebooks/{gid}"}


def _raw(root, slug, text_len):
    d = os.path.join(root, "out", slug, "raw")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "raw_pages.json"), "w") as f:
        json.dump({"book_id": slug, "pages": [{"page_idx": 0, "text": "x" * text_len}]}, f)


@pytest.fixture
def hooks():
    calls = []

    def stage(name):
        def fn(entry, root, *a):
            calls.append((name, entry["slug"]))
            if name == "package":
                work = os.path.join(root, "out", entry["slug"])
                os.makedirs(os.path.join(work, "sections", "sec_0001"), exist_ok=True)
                with open(os.path.join(work, "sections", "sec_0001", "audio.m4a"), "wb") as f:
                    f.write(b"x")
                with open(os.path.join(work, "manifest.json"), "w") as f:
                    json.dump({"book_id": entry["slug"], "sections": [],
                               "total_duration_ms": 1000}, f)
                from firebrat_cast.packager import zip_package

                return {"zip": zip_package(work)}
            return {"ok": True}
        return fn

    return {"calls": calls,
            "fetch": stage("fetch"), "segment": stage("segment"),
            "cast_one": stage("cast"), "synth_one": stage("synth"),
            "package": stage("package"),
            "backend": object(), "engine": object()}


def test_order_pending_shortest_first_unknown_last(tmp_path):
    cat = _catalog(tmp_path, [_entry("a", 1), _entry("b", 2), _entry("c", 3)])
    _raw(str(tmp_path), "a", 5000)
    _raw(str(tmp_path), "b", 500)
    # c unfetched -> last despite catalog order
    entries = qr.load_catalog(cat)
    assert [e["slug"] for e in qr.order_pending(entries, str(tmp_path))] == ["b", "a", "c"]


def test_plan_waves_chunks():
    entries = [{"slug": f"s{i}"} for i in range(5)]
    assert [[e["slug"] for e in w] for w in qr.plan_waves(entries, 2)] == \
        [["s0", "s1"], ["s2", "s3"], ["s4"]]


def test_run_executes_stages_in_order(tmp_path, hooks):
    cat = _catalog(tmp_path, [_entry("b1", 11), _entry("b2", 12)])
    calls = hooks.pop("calls")
    cfg = qr.RunnerConfig(catalog=cat, root=str(tmp_path), wave_size=2, hooks=hooks)
    result = qr.run(cfg)
    assert result["failed"] == []
    per_book = {}
    for name, slug in calls:
        per_book.setdefault(slug, []).append(name)
    for slug, stages in per_book.items():
        assert stages == ["fetch", "segment", "cast", "synth", "package"], slug
    for slug in ("b1", "b2"):
        state = qr.load_state(str(tmp_path), slug)
        assert state["status"] == "done" and state["done"]["package"] == "done"
        assert os.path.isfile(os.path.join(str(tmp_path), "jobs", slug, "log.txt"))
        prog = json.load(open(os.path.join(str(tmp_path), "jobs", slug, "progress.json")))
        assert prog["percent"] == 100.0
    assert os.path.isfile(os.path.join(str(tmp_path), "progress.json"))


def test_run_resumes_and_skips_done(tmp_path, hooks):
    cat = _catalog(tmp_path, [_entry("b1", 11)])
    cfg = qr.RunnerConfig(catalog=cat, root=str(tmp_path), hooks=dict(hooks))
    qr.run(cfg)
    n_calls = len(hooks["calls"])
    cfg2 = qr.RunnerConfig(catalog=cat, root=str(tmp_path), hooks=dict(hooks))
    result = qr.run(cfg2)  # built.json exists -> not pending
    assert result["books"] == [] and len(hooks["calls"]) == n_calls


def test_run_only_and_dry_run(tmp_path, hooks):
    cat = _catalog(tmp_path, [_entry("b1", 11), _entry("b2", 12)])
    calls = hooks.pop("calls")
    cfg = qr.RunnerConfig(catalog=cat, root=str(tmp_path), only="b2",
                          dry_run=True, hooks=hooks)
    result = qr.run(cfg)
    assert result["dry_run"] is True and len(result["books"]) == 1
    assert calls == []  # dry run performs no stages
    assert not os.path.isdir(os.path.join(str(tmp_path), "jobs"))


def test_failure_in_one_book_does_not_stop_others(tmp_path, hooks):
    cat = _catalog(tmp_path, [_entry("bad", 11), _entry("good", 12)])
    calls = hooks.pop("calls")

    def boom(entry, root, *a):
        raise RuntimeError("nope")

    hooks["fetch"] = lambda e, r, *a: boom(e, r) if e["slug"] == "bad" else hooks_fetch(e, r)

    def hooks_fetch(e, r):
        calls.append(("fetch", e["slug"]))
        return {"ok": True}

    cfg = qr.RunnerConfig(catalog=cat, root=str(tmp_path), wave_size=2, hooks=hooks)
    # fetch for "bad" raises inside do_stage -> recorded; other stages skipped via failure
    result = qr.run(cfg)
    assert "bad" in result["failed"]
    assert ("package", "good") in calls
    state = qr.load_state(str(tmp_path), "bad")
    assert state["status"] == "failed" and "nope" in state["error"]


def test_is_done_requires_built_json(tmp_path):
    from firebrat_cast.fetch import write_json_atomic

    root = str(tmp_path)
    assert qr.is_done(root, "x") is False
    os.makedirs(os.path.join(root, "jobs", "x"), exist_ok=True)
    write_json_atomic(os.path.join(root, "jobs", "x", "state.json"),
                      {"stage": "package", "status": "done", "done": {"package": "done"}})
    assert qr.is_done(root, "x") is False  # built.json missing
    os.makedirs(os.path.join(root, "out", "x"), exist_ok=True)
    write_json_atomic(os.path.join(root, "out", "x", "built.json"), {"slug": "x"})
    assert qr.is_done(root, "x") is True


def test_cli_parse(tmp_path):
    cat = _catalog(tmp_path, [])
    cfg = qr.parse_args(["--catalog", cat, "--root", str(tmp_path),
                         "--wave-size", "3", "--llm-backend", "external",
                         "--tts", "chatterbox", "--dry-run"])
    assert cfg.wave_size == 3 and cfg.llm_backend == "external"
    assert cfg.tts == "chatterbox" and cfg.dry_run is True

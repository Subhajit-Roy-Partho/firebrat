"""Regression tests for the 2026-09 DDCA incident: duplicate section_ids in
compiled.json led Stage 3 to overwrite one sections/<sid>/ dir while the
manifest minted sec_9001+ replacements — 22 dangling audio_path refs, and
the app's completeness gate refused to list the book at all."""
import json
import os
import tempfile
import zipfile


def _sec(sid, title="T", segments=1):
    return {
        "section_id": sid, "title": title, "source_pages": [0],
        "segments": [
            {"segment_id": f"{sid}_seg_{i+1:03d}" if sid else "",
             "type": "prose", "text": f"word " * 10}
            for i in range(segments)
        ],
    }


def test_normalize_mints_unique_ids_and_retargets_segments():
    from firebrat.utils.ids import normalize_section_ids
    sections = [_sec("sec_0001"), _sec("sec_0001", "dup", 2), _sec("", "noid"), _sec("sec_0001", "dup2")]
    normalize_section_ids(sections)
    ids = [s["section_id"] for s in sections]
    assert ids[0] == "sec_0001"
    assert len(set(ids)) == 4
    assert ids[1] == "sec_9001" and ids[3] == "sec_9002"
    assert ids[2] == "sec_0003"  # order-based for the missing id
    # segment ids of reminted sections follow the new section id
    assert sections[1]["segments"][0]["segment_id"] == "sec_9001_seg_001"
    assert sections[3]["segments"][0]["segment_id"] == "sec_9002_seg_001"
    # idempotent: normalizing twice changes nothing further
    before = json.dumps(sections, sort_keys=True)
    normalize_section_ids(sections)
    assert json.dumps(sections, sort_keys=True) == before


def test_manifest_agrees_with_normalized_ids():
    """build_manifest must reference exactly the ids normalize produces —
    no stage may mint on its own."""
    from firebrat.utils.ids import normalize_section_ids
    from firebrat.pipeline.manifest import build_manifest
    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, "dupbook")
        os.makedirs(os.path.join(pkg, "sections", "sec_0001"))
        open(os.path.join(pkg, "sections", "sec_0001", "audio.m4a"), "wb").write(b"fake")
        compiled = {"sections": [_sec("sec_0001"), _sec("sec_0001", "dup")]}
        with open(os.path.join(pkg, "compiled.json"), "w") as f:
            json.dump(compiled, f)
        build_manifest(pkg, "dupbook", "Dup", "x.pdf")
        manifest = json.load(open(os.path.join(pkg, "manifest.json")))
        got = [s["section_id"] for s in manifest["sections"]]
        assert got == ["sec_0001", "sec_9001"]
        # the surviving audio resolves; the reminted one is an honest
        # placeholder ref (repair script materializes it before shipping)
        assert manifest["sections"][0]["audio_path"] == "sections/sec_0001/audio.m4a"


def test_download_zip_excludes_build_intermediates_and_stores_media():
    from fastapi.testclient import TestClient
    import server.config as cfg
    from server import storage
    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, "bigbook")
        os.makedirs(os.path.join(pkg, "sections", "sec_0001"))
        open(os.path.join(pkg, "sections", "sec_0001", "audio.m4a"), "wb").write(b"\x00" * 1000)
        open(os.path.join(pkg, "source.pdf"), "wb").write(b"%PDF" + b"\x00" * 1000)
        open(os.path.join(pkg, "manifest.json"), "w").write('{"book_id": "bigbook"}')
        # build intermediates that must NOT ship to readers
        os.makedirs(os.path.join(pkg, "_segment_wavs"))
        open(os.path.join(pkg, "_segment_wavs", "s.wav"), "wb").write(b"wav")
        os.makedirs(os.path.join(pkg, "raw"))
        open(os.path.join(pkg, "raw", "raw_pages.json"), "w").write("{}")
        open(os.path.join(pkg, "compiled.json"), "w").write("{}")
        orig = cfg.OUTPUT_DIR
        cfg.OUTPUT_DIR = tmp
        try:
            from server.main import app
            client = TestClient(app)
            z = client.get("/books/bigbook/download")
            assert z.status_code == 200
            names = zipfile.ZipFile(__import__("io").BytesIO(z.content)).namelist()
            assert "manifest.json" in names
            assert "source.pdf" in names  # reader's Source PDF screen needs it
            assert "sections/sec_0001/audio.m4a" in names
            assert not any(n.startswith(("_segment_wavs", "raw/")) or n == "compiled.json" for n in names)
            info = {i.filename: i for i in zipfile.ZipFile(__import__("io").BytesIO(z.content)).infolist()}
            assert info["sections/sec_0001/audio.m4a"].compress_type == zipfile.ZIP_STORED
        finally:
            cfg.OUTPUT_DIR = orig
            storage._zip_cache.pop("bigbook", None)


def test_package_tar_excludes_build_intermediates():
    from firebrat.pipeline.package import package_book
    import tarfile
    with tempfile.TemporaryDirectory() as tmp:
        pkg = os.path.join(tmp, "tb")
        os.makedirs(os.path.join(pkg, "_segment_wavs"))
        open(os.path.join(pkg, "_segment_wavs", "s.wav"), "wb").write(b"wav")
        open(os.path.join(pkg, "compiled.json"), "w").write("{}")
        open(os.path.join(pkg, "manifest.json"), "w").write("{}")
        open(os.path.join(pkg, "source.pdf"), "wb").write(b"%PDF")
        out = package_book(pkg)
        names = tarfile.open(out, "r:gz").getnames()
        assert "manifest.json" in names and "source.pdf" in names
        assert not any(n.startswith(("_segment_wavs", "raw")) or n == "compiled.json" for n in names)

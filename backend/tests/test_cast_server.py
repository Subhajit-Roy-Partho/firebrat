"""Expressive-cast ("cast") server integration — no GPU or network needed.

Covers the INTEGRATION.md contract: job creation (422/400 paths), the
/settings flag, the job_runner cast path against a fake scheduler dir with
state files, supervisor start/stop with a fake command, fetch source_path
for a tiny generated EPUB and a tiny text PDF, and Manifest tolerance of
the additive cast keys.
"""
import json
import os
import sys
import time
import zipfile

import pytest


def _wait_for(predicate, timeout=10.0, interval=0.05):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return False


@pytest.fixture()
def cast_dirs(tmp_path, monkeypatch):
    """Isolated server dirs + cast root wired through config call-time helpers."""
    import server.config as cfg
    import server.job_runner as job_runner_module

    out = tmp_path / "output"
    up = tmp_path / "uploads"
    out.mkdir()
    up.mkdir()
    monkeypatch.setattr(cfg, "OUTPUT_DIR", str(out))
    monkeypatch.setattr(cfg, "UPLOAD_DIR", str(up))
    monkeypatch.setattr(cfg, "JOBS_DB_PATH", str(tmp_path / "jobs.sqlite3"))
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(tmp_path / "cast"))
    monkeypatch.setattr(job_runner_module, "_CAST_POLL_S", 0.01)
    # Fresh worker state so this TestClient lifespan behaves like a restart.
    job_runner_module._workers_started = False
    job_runner_module._resumed_orphans = False
    yield tmp_path
    # Never leak a supervisor child process into other tests.
    from server import cast_bridge
    cast_bridge.shutdown_supervisor()


def _client():
    from fastapi.testclient import TestClient
    from server.main import app
    return TestClient(app)


def test_cast_upload_rejected_when_disabled(cast_dirs, monkeypatch):
    import server.config as cfg
    monkeypatch.setattr(cfg, "cast_available", lambda: False)
    with _client() as client:
        resp = client.post(
            "/books/upload",
            files={"file": ("tale.epub", b"PK\x03\x04fake", "application/epub+zip")},
            data={"content_mode": "cast"},
        )
        assert resp.status_code == 400
        assert "Expressive voices" in resp.json()["detail"]


def test_cast_upload_bad_mode_is_422(cast_dirs):
    with _client() as client:
        resp = client.post(
            "/books/upload",
            files={"file": ("t.pdf", b"%PDF-1.4 fake", "application/pdf")},
            data={"content_mode": "opera"},
        )
        assert resp.status_code == 422


def test_settings_cast_flag(cast_dirs, monkeypatch):
    import server.config as cfg
    monkeypatch.setattr(cfg, "cast_available", lambda: False)
    with _client() as client:
        assert client.get("/settings").json()["cast_available"] is False
    monkeypatch.setattr(cfg, "cast_available", lambda: True)
    with _client() as client:
        assert client.get("/settings").json()["cast_available"] is True


def test_cast_job_full_loop_with_fake_scheduler(cast_dirs, monkeypatch):
    """Upload with cast enabled: the worker writes the inbox entry and the
    fake scheduler's pre-written done state flips the job to done."""
    import server.config as cfg
    from server import cast_bridge

    monkeypatch.setattr(cfg, "cast_available", lambda: True)
    # Lifespan must not launch a real scheduler child in tests.
    monkeypatch.setattr(cast_bridge, "ensure_supervisor_started", lambda command=None: True)

    root = os.environ["FIREBRAT_CAST_ROOT"]
    slug = "castbook"
    os.makedirs(os.path.join(root, "jobs", slug), exist_ok=True)
    with open(os.path.join(root, "jobs", slug, "state.json"), "w") as f:
        json.dump({"slug": slug, "stage": "package", "status": "done"}, f)

    with _client() as client:
        resp = client.post(
            "/books/upload",
            files={"file": ("castbook.epub", _tiny_epub_bytes(), "application/epub+zip")},
            data={"content_mode": "cast"},
        )
        assert resp.status_code == 200, resp.text
        job = resp.json()
        assert job["content_mode"] == "cast"
        assert job["book_id"] == slug
        job_id = job["job_id"]

        assert _wait_for(lambda: client.get(f"/jobs/{job_id}").json()["state"] == "done")
        done = client.get(f"/jobs/{job_id}").json()
        assert done["stage"] == "done"

        inbox = os.path.join(root, "inbox", f"{slug}.json")
        assert os.path.isfile(inbox)
        entry = json.load(open(inbox))
        assert entry == {"slug": slug, "title": job["title"], "author": "",
                         "source_path": entry["source_path"], "category": "fiction",
                         "language": "en", "description": ""}
        assert entry["source_path"].endswith(".epub")

        # Delete removes the inbox entry while still queued: create the row
        # directly (never enqueued, so no worker race) with an inbox entry.
        from server import jobs as jobs_module
        pdf2 = os.path.join(str(cast_dirs / "uploads"), "castbook2.epub")
        with open(pdf2, "wb") as f:
            f.write(_tiny_epub_bytes())
        job_id2 = jobs_module.create_job(
            book_id="castbook2", filename="castbook2.epub",
            title="Castbook2", pdf_path=pdf2, content_mode="cast")
        cast_bridge.write_inbox_entry("castbook2", "Castbook2", pdf2)
        assert os.path.isfile(os.path.join(root, "inbox", "castbook2.json"))
        delete = client.delete(f"/jobs/{job_id2}")
        assert delete.status_code == 200, delete.text
        assert not os.path.isfile(os.path.join(root, "inbox", "castbook2.json"))


def test_cast_stage_text_mapping(cast_dirs):
    from server import cast_bridge

    root = os.environ["FIREBRAT_CAST_ROOT"]
    slug = "stages"
    job_dir = os.path.join(root, "jobs", slug)
    os.makedirs(job_dir, exist_ok=True)

    def view_for(stage, status="running"):
        with open(os.path.join(job_dir, "state.json"), "w") as f:
            json.dump({"slug": slug, "stage": stage, "status": status}, f)
        return cast_bridge.cast_job_view(slug)

    assert view_for("missing")["stage"] == "missing"  # unknown stages render
    assert view_for("fetch")["stage"] == "preparing text"
    assert view_for("segment")["stage"] == "preparing text"
    assert view_for("cast")["stage"] == "casting characters"
    assert view_for("synth")["stage"] == "recording voices"
    assert view_for("package")["stage"] == "packaging"
    assert view_for("package", "done")["terminal"] == "done"
    failed = view_for("synth", "failed")
    assert failed["terminal"] == "failed" and failed["error"]
    # No state file at all reads as queued, never terminal.
    assert cast_bridge.cast_job_view("never-seen")["stage"] == "queued"


def test_cast_supervisor_start_stop(monkeypatch):
    from server import cast_bridge

    # A long-lived fake command proves start/stop; a dying one with zero
    # allowed restarts proves the give-up path without waiting out retries.
    sup = cast_bridge.CastSupervisor(
        command=[sys.executable, "-c", "import time; time.sleep(60)"])
    assert sup.start() is True and sup.running
    sup.stop()
    assert not sup.running

    monkeypatch.setattr(cast_bridge, "MAX_RESTARTS", 0)
    dying = cast_bridge.CastSupervisor(command=[sys.executable, "-c", "pass"])
    assert dying.start() is True
    assert _wait_for(lambda: not dying.running, timeout=10.0)
    dying.stop()


def _tiny_epub_bytes() -> bytes:
    import io
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
        z.writestr("META-INF/container.xml",
                   '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                   '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>'
                   "</rootfiles></container>")
        z.writestr("OEBPS/content.opf",
                   '<package xmlns="http://www.idpf.org/2007/opf">'
                   '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                   '<dc:title>A Tiny Tale</dc:title></metadata>'
                   '<manifest><item id="a" href="text/one.xhtml" media-type="application/xhtml+xml"/></manifest>'
                   '<spine><itemref idref="a"/></spine></package>')
        z.writestr("OEBPS/text/one.xhtml",
                   "<html><body><p>“Come in,” Alice said.</p></body></html>")
    return buf.getvalue()


def test_fetch_source_path_epub(tmp_path):
    from firebrat_cast.fetch import fetch_book

    src = tmp_path / "tale.epub"
    src.write_bytes(_tiny_epub_bytes())
    root = tmp_path / "castroot"
    out = fetch_book({"slug": "tiny-tale", "source_path": str(src)}, str(root))
    assert out["cached"] is False
    raw = json.load(open(out["raw_path"]))
    assert raw["page_count"] >= 1
    assert "Alice" in " ".join(p.get("text", "") for p in raw["pages"])
    # Idempotent: second call reuses the raw file.
    assert fetch_book({"slug": "tiny-tale", "source_path": str(src)}, str(root))["cached"] is True


def _tiny_pdf_bytes(text: str = "Hello cast world") -> bytes:
    body = (f"BT /F1 12 Tf 10 100 Td ({text}) Tj ET").encode("latin-1")
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(body) + body + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objs, 1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + bytes(obj) + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF"
            % (len(objs) + 1, xref))
    return bytes(out)


def test_fetch_source_path_pdf(tmp_path):
    pymupdf = pytest.importorskip("pymupdf")
    assert pymupdf is not None
    from firebrat_cast.fetch import fetch_book

    src = tmp_path / "page.pdf"
    src.write_bytes(_tiny_pdf_bytes())
    out = fetch_book({"slug": "tiny-pdf", "source_path": str(src)}, str(tmp_path / "r"))
    raw = json.load(open(out["raw_path"]))
    assert len(raw["pages"]) == 1  # one raw page per PDF page
    assert "Hello cast world" in raw["pages"][0]["text"]


def test_fetch_source_path_scanned_pdf(tmp_path):
    pytest.importorskip("pymupdf")
    from firebrat_cast.fetch import fetch_book

    src = tmp_path / "blank.pdf"
    src.write_bytes(_tiny_pdf_bytes(text=""))
    with pytest.raises(ValueError, match="no embedded text"):
        fetch_book({"slug": "blank-pdf", "source_path": str(src)}, str(tmp_path / "r"))


def test_manifest_tolerates_cast_keys():
    from firebrat.pipeline.schema import Manifest

    m = Manifest.model_validate({
        "book_id": "cast1", "title": "Cast", "source_pdf": "t.epub",
        "generated_at": "2026-01-01T00:00:00Z", "content_mode": "cast",
        "narrator_voice": {"engine": "qwen3-tts"},
        "cast": {"engine": "qwen3-tts",
                 "characters": [{"id": "char_001", "name": "Alice"}]},
        "sections": [],
    })
    assert m.content_mode == "cast"
    assert m.cast["engine"] == "qwen3-tts"
    assert m.narrator_voice.engine == "qwen3-tts"
    # Old packages without the key still validate with an empty default.
    old = Manifest.model_validate({
        "book_id": "old", "title": "Old", "source_pdf": "o.pdf",
        "generated_at": "2026-01-01T00:00:00Z", "sections": [],
    })
    assert old.cast == {} and old.content_mode == "illustrated"

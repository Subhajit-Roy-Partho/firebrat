"""FastAPI TestClient tests — no GPU or network needed."""
import json
import os
import tempfile
import zipfile

def _make_package(tmpdir: str, book_id="testbook"):
    pkg = os.path.join(tmpdir, book_id)
    os.makedirs(pkg, exist_ok=True)
    manifest = {
        "schema_version": "1.0", "book_id": book_id, "title": "Test", "author": "",
        "source_pdf": "x.pdf", "generated_at": "2026-08-20T00:00:00Z",
        "pipeline_version": "0.1.0",
        "narrator_voice": {"engine": "chatterbox-tts", "model_class": "ChatterboxTTS", "sample_rate": 24000, "exaggeration": 0.4, "cfg_weight": 0.5},
        "audio_format": {"codec": "aac", "container": "m4a", "sample_rate": 24000, "channels": 1, "fallback_codec": "mp3"},
        "total_duration_ms": 0, "sections": [], "figures": [], "formulas": [], "tables": [],
    }
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(manifest, f)
    # dummy asset
    os.makedirs(os.path.join(pkg, "assets/figures"), exist_ok=True)
    with open(os.path.join(pkg, "assets/figures/fig_0001.png"), "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
    return pkg

def test_api_endpoints():
    import tempfile
    from fastapi.testclient import TestClient
    import server.config as cfg

    with tempfile.TemporaryDirectory() as tmpdir:
        _make_package(tmpdir)
        orig = cfg.OUTPUT_DIR
        cfg.OUTPUT_DIR = tmpdir
        try:
            from server.main import app
            client = TestClient(app)
            assert client.get("/health").json() == {"status": "ok"}
            books = client.get("/books").json()
            assert len(books) == 1 and books[0]["book_id"] == "testbook"
            m = client.get("/books/testbook/manifest").json()
            assert m["book_id"] == "testbook"
            z = client.get("/books/testbook/download")
            assert z.status_code == 200 and z.headers["content-type"] in ("application/zip", "application/x-zip-compressed")
            a = client.get("/books/testbook/assets/assets/figures/fig_0001.png")
            assert a.status_code == 200
            assert client.get("/books/missing/manifest").status_code == 404
            assert client.get("/books/testbook/assets/../../etc/passwd").status_code == 404

            # delete: 404 for unknown/path-traversal ids, real deletion for a real one
            assert client.delete("/books/missing").status_code == 404
            assert client.delete("/books/../../etc").status_code == 404
            assert os.path.isdir(os.path.join(tmpdir, "testbook"))
            d = client.delete("/books/testbook")
            assert d.status_code == 200 and d.json() == {"deleted": "testbook"}
            assert not os.path.isdir(os.path.join(tmpdir, "testbook"))
            assert client.get("/books").json() == []
            assert client.delete("/books/testbook").status_code == 404  # already gone
        finally:
            cfg.OUTPUT_DIR = orig

"""Tests for schema: ref validation, manifest shape."""

def test_llm_ref_validation_ok():
    from firebrat.pipeline.schema import LLMOutput
    raw = {
        "sections": [{
            "title": "Clocks",
            "source_pages": [0],
            "segments": [
                {"type": "prose", "text": "hi", "ref": None, "visually_essential": False},
                {"type": "figure_callout", "text": "see figure", "ref": "fig_0001", "visually_essential": True},
            ],
        }]
    }
    out = LLMOutput.model_validate(raw)
    assert out.validate_refs({"fig_0001"}) == []
    assert len(out.validate_refs(set())) == 1

def test_normalize_wrapper_schema_envelope():
    """Regression test for a real production failure: deepseek-v4-pro:thinking
    sometimes echoes a JSON-schema-style envelope instead of the content
    directly. Two of the first five chunks on the real full-book run failed
    this way before the fix."""
    from firebrat.pipeline.compile_llm import _normalize_wrapper
    envelope = {
        "type": "object",
        "data": {
            "sections": [{
                "title": "X", "source_pages": [1],
                "segments": [{"type": "prose", "text": "hi", "ref": None, "visually_essential": False}],
            }],
        },
    }
    result = _normalize_wrapper(envelope)
    assert "sections" in result
    assert result["sections"][0]["title"] == "X"

def test_normalize_wrapper_passthrough_and_singular():
    from firebrat.pipeline.compile_llm import _normalize_wrapper
    already_correct = {"sections": [{"title": "Y", "source_pages": [], "segments": []}]}
    assert _normalize_wrapper(already_correct) is already_correct

    singular = {"section": {"title": "Z", "source_pages": [], "segments": []}}
    result = _normalize_wrapper(singular)
    assert result["sections"] == [{"title": "Z", "source_pages": [], "segments": []}]

def test_fill_blank_titles():
    """Regression test: the Stage 2 prompt explicitly tells the model it may
    return an empty title for front-matter/bibliography chunks, but the
    schema requires a non-empty one — that contradiction failed real chunks
    (this book's "List of Figures"/"List of Tables" front matter, pages
    30-49) on the full-book run. An empty title must not reject the chunk."""
    from firebrat.pipeline.compile_llm import _fill_blank_titles
    parsed = {"sections": [
        {"title": "", "source_pages": [30, 31, 32], "segments": []},
        {"title": "   ", "source_pages": [], "segments": []},
        {"title": "Real Title", "source_pages": [5], "segments": []},
    ]}
    result = _fill_blank_titles(parsed)
    assert result["sections"][0]["title"] == "Pages 31–33"
    assert result["sections"][1]["title"] == "Untitled section"
    assert result["sections"][2]["title"] == "Real Title"

def test_manifest_roundtrip(tmp_path=None):
    import json, os, tempfile
    from firebrat.pipeline.manifest import build_manifest
    with tempfile.TemporaryDirectory() as pkg:
        os.makedirs(os.path.join(pkg, "raw"), exist_ok=True)
        with open(os.path.join(pkg, "raw", "raw_pages.json"), "w") as f:
            json.dump({"book_id": "test", "source_pdf": "x.pdf", "page_count": 1,
                       "pages": [{"page_idx": 0, "text": "hi", "markdown": "",
                                  "figures": [], "tables": [], "formulas": []}]}, f)
        with open(os.path.join(pkg, "compiled.json"), "w") as f:
            json.dump({"book_id": "test", "sections": [
                {"section_id": "sec_0001", "title": "S1", "source_pages": [0],
                 "segments": [{"type": "prose", "text": "hello", "ref": None, "visually_essential": False, "segment_id": "sec_0001_seg_001"}]}
            ]}, f)
        mpath = build_manifest(pkg, "test", "Test Book", "x.pdf")
        assert os.path.isfile(mpath)
        with open(mpath) as f:
            m = json.load(f)
        assert m["book_id"] == "test"
        assert len(m["sections"]) == 1

def test_manifest_source_pdf_shipped():
    """build_manifest copies the source PDF into the package and maps
    compiled.json source_pages onto each manifest section."""
    import json, os, tempfile
    from firebrat.pipeline.manifest import build_manifest
    from firebrat.pipeline.schema import Manifest
    with tempfile.TemporaryDirectory() as pkg:
        os.makedirs(os.path.join(pkg, "raw"), exist_ok=True)
        with open(os.path.join(pkg, "raw", "raw_pages.json"), "w") as f:
            json.dump({"book_id": "t", "source_pdf": "x.pdf", "page_count": 2,
                       "pages": [{"page_idx": i, "text": "hi", "markdown": "",
                                  "figures": [], "tables": [], "formulas": []} for i in range(2)]}, f)
        with open(os.path.join(pkg, "compiled.json"), "w") as f:
            json.dump({"book_id": "t", "sections": [
                {"section_id": "sec_0001", "title": "S1", "source_pages": [0, 1],
                 "segments": [{"type": "prose", "text": "hello", "ref": None, "visually_essential": False,
                               "segment_id": "sec_0001_seg_001"}]}
            ]}, f)
        with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as src:
            src.write(b"%PDF-1.4 fake")
            src_path = src.name
        mpath = build_manifest(pkg, "t", "T", "x.pdf", source_pdf_path=src_path)
        os.unlink(src_path)
        with open(mpath) as f:
            m = json.load(f)
        assert m["source_pdf_path"] == "source.pdf"
        assert os.path.isfile(os.path.join(pkg, "source.pdf"))
        assert m["sections"][0]["source_pages"] == [0, 1]
        Manifest.model_validate(m)  # new fields validate

def test_manifest_without_source_pdf_still_validates():
    """Old packages (no source_pdf_path / source_pages keys at all) must
    still parse — the fields are additive with defaults."""
    from firebrat.pipeline.schema import Manifest
    m = Manifest.model_validate({
        "book_id": "old", "title": "Old", "source_pdf": "old.pdf",
        "generated_at": "2026-01-01T00:00:00Z",
        "sections": [{
            "section_id": "sec_0001", "order": 1, "title": "S1",
            "audio_path": "sections/sec_0001/audio.m4a",
            "segments_path": "sections/sec_0001/segments.json",
            "duration_ms": 1000,
        }],
    })
    assert m.source_pdf_path is None
    assert m.sections[0].source_pages == []

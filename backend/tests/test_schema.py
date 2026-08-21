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

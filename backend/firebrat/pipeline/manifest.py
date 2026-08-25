"""Build final manifest.json from all stage outputs."""
import json
import logging
import os
import datetime

from firebrat.config import PIPELINE_VERSION, SCHEMA_VERSION, SAMPLE_RATE, TTS_EXAGGERATION, TTS_CFG_WEIGHT

log = logging.getLogger(__name__)


def build_manifest(
    package_dir: str,
    book_id: str,
    title: str,
    source_pdf: str,
    voice_ref: str | None = None,
) -> str:
    """Assemble manifest.json inside package_dir.

    Reads raw/raw_pages.json + compiled.json + sections/*/segments.json to compute
    durations, refs, counts.

    Returns path to written manifest.json.
    """
    raw_path = os.path.join(package_dir, "raw", "raw_pages.json")
    compiled_path = os.path.join(package_dir, "compiled.json")
    # compiled may also live at raw/compiled.json per compile_llm's dual write
    if not os.path.isfile(compiled_path):
        alt = os.path.join(package_dir, "raw", "compiled.json")
        if os.path.isfile(alt):
            compiled_path = alt

    raw = {}
    compiled = {"sections": []}
    if os.path.isfile(raw_path):
        with open(raw_path, "r", encoding="utf-8") as f:
            raw = json.load(f)
    if os.path.isfile(compiled_path):
        with open(compiled_path, "r", encoding="utf-8") as f:
            compiled = json.load(f)

    # Collect figures / formulas / tables from raw + any rendered formula bookkeeping
    figures: list[dict] = []
    formulas: list[dict] = []
    tables: list[dict] = []
    for p in (raw.get("pages") or []):
        for fig in p.get("figures", []):
            figures.append({
                "figure_id": fig["figure_id"],
                "caption": fig.get("caption", ""),
                "image_path": fig.get("image_path", ""),
                "page": fig.get("page", p.get("page_idx", 0)),
                "width": fig.get("width"), "height": fig.get("height"),
            })
        for t in p.get("tables", []):
            tables.append({
                "table_id": t["table_id"],
                "caption": t.get("caption", ""),
                "image_path": t.get("image_path", ""),
                "page": t.get("page", p.get("page_idx", 0)),
            })

    # Formulas are LLM-authored (Stage 2), not Stage-1 extracted — this book typesets
    # math as plain inline text (e.g. "tCK = 1/f"), so there's no LaTeX to scrape from the PDF.
    for fo in compiled.get("formulas", []):
        fid = fo["formula_id"]
        img_path = fo.get("image_path") or os.path.join("assets/formulas", f"{fid}.png")
        formulas.append({
            "formula_id": fid,
            "latex": fo.get("latex", ""),
            "image_path": img_path,
            "spoken_text": fo.get("spoken_text", ""),
            "visually_essential": fo.get("visually_essential", False),
            "page": fo.get("page", 0),
        })

    # Normalize compiled sections: ensure section_id + segment_ids present + deduplicate
    from firebrat.utils.ids import make_section_id, make_segment_id
    sections_out: list[dict] = []
    total_duration = 0
    seen_sids: set[str] = set()
    # For duplicates, mint from high range to avoid colliding with existing sequential ids
    next_dup = 9001
    for order, sec in enumerate(compiled.get("sections", [])):
        raw_sid = sec.get("section_id")
        if raw_sid and raw_sid not in seen_sids:
            sid = raw_sid
        else:
            if raw_sid:
                log.warning("Duplicate section_id %s at order %d — minting replacement", raw_sid, order + 1)
                # Mint a high-numbered id that is guaranteed free
                while make_section_id(next_dup) in seen_sids:
                    next_dup += 1
                sid = make_section_id(next_dup)
                next_dup += 1
            else:
                sid = make_section_id(order + 1)
                # Ensure not already seen (gap due to earlier duplicate mint)
                while sid in seen_sids:
                    sid = make_section_id(next_dup)
                    next_dup += 1
            # Retarget segment_ids that were derived from the old sid
            if raw_sid and raw_sid != sid:
                for s in sec.get("segments", []):
                    old_seg = s.get("segment_id", "")
                    if old_seg.startswith(raw_sid):
                        s["segment_id"] = old_seg.replace(raw_sid, sid, 1)
        seen_sids.add(sid)
        sec["section_id"] = sid
        # Load timing if assembly already ran
        seg_json_path = os.path.join(package_dir, "sections", sid, "segments.json")
        duration = 0
        seg_count = len(sec.get("segments", []) or [])
        # Assign segment ids where missing
        for idx2, s in enumerate(sec.get("segments", [])):
            s.setdefault("segment_id", make_segment_id(sid, idx2))
        if os.path.isfile(seg_json_path):
            try:
                with open(seg_json_path, "r", encoding="utf-8") as f:
                    sj = json.load(f)
                segs = sj.get("segments", [])
                if segs:
                    duration = segs[-1]["end_ms"]
                    seg_count = len(segs)
            except Exception as e:
                log.warning("Failed to read %s: %s", seg_json_path, e)

        # Decide audio_path — prefer existing file
        audio_path = ""
        for cand in (os.path.join("sections", sid, "audio.m4a"),
                     os.path.join("sections", sid, "audio.mp3"),
                     os.path.join("sections", sid, "audio.wav")):
            if os.path.isfile(os.path.join(package_dir, cand)):
                audio_path = cand
                break
        if not audio_path:
            audio_path = os.path.join("sections", sid, "audio.m4a")  # placeholder for not-yet-built

        # Collect refs from segments (ref may be missing or explicitly None)
        seg_refs = [s.get("ref") for s in sec.get("segments", []) if s.get("ref")]
        fig_refs = sorted({r for r in seg_refs if r.startswith("fig_")})
        formula_refs = sorted({r for r in seg_refs if r.startswith("formula_")})
        table_refs = sorted({r for r in seg_refs if r.startswith("tbl_")})

        # needs_review: explicit flag OR title heuristic (fallback sections have "needs review" title)
        needs_review_flag = bool(sec.get("needs_review", False))
        if not needs_review_flag and "needs review" in str(sec.get("title", "")).lower():
            needs_review_flag = True
        # Also treat placeholder text as needs_review
        if not needs_review_flag:
            for s in (sec.get("segments") or []):
                if "being prepared" in str(s.get("text", "")).lower():
                    needs_review_flag = True
                    break
        sections_out.append({
            "section_id": sid,
            "chapter": sec.get("chapter"),
            "order": order + 1,
            "title": sec.get("title", f"Section {order+1}"),
            "audio_path": audio_path,
            "segments_path": os.path.join("sections", sid, "segments.json"),
            "duration_ms": duration,
            "figure_refs": fig_refs,
            "formula_refs": formula_refs,
            "table_refs": table_refs,
            "needs_review": needs_review_flag,
        })
        total_duration += duration

    # Resolve calm female defaults if voice file exists but not explicitly passed
    _eff_voice_for_manifest = voice_ref
    if not _eff_voice_for_manifest:
        from firebrat.config import DEFAULT_VOICE_REF as _DVR
        if os.path.isfile(_DVR):
            _eff_voice_for_manifest = _DVR
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "book_id": book_id,
        "title": title or book_id,
        "author": "",
        "source_pdf": source_pdf or book_id,
        "generated_at": datetime.datetime.utcnow().isoformat() + "Z",
        "pipeline_version": PIPELINE_VERSION,
        "narrator_voice": {
            "engine": "chatterbox-tts",
            "model_class": "ChatterboxTTS",
            "reference_clip": _eff_voice_for_manifest,
            "exaggeration": TTS_EXAGGERATION,
            "cfg_weight": TTS_CFG_WEIGHT,
            "sample_rate": SAMPLE_RATE,
        },
        "audio_format": {
            "codec": "aac", "container": "m4a",
            "sample_rate": SAMPLE_RATE, "channels": 1, "fallback_codec": "mp3",
        },
        "total_duration_ms": total_duration,
        "sections": sections_out,
        "figures": figures,
        "formulas": formulas,
        "tables": tables,
    }

    # Validate shape
    from firebrat.pipeline.schema import Manifest
    Manifest.model_validate(manifest)

    out_path = os.path.join(package_dir, "manifest.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
    log.info("Manifest written: %s (%d sections, %d figures, %d formulas, %d ms total)",
             out_path, len(sections_out), len(figures), len(formulas), total_duration)
    return out_path

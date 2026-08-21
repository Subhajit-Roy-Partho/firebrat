#!/usr/bin/env python3
"""Firebrat pipeline CLI: pdf -> book package (offline-first).

Usage:
  python -m firebrat.convert book.pdf [--output DIR] [--pages N] [--skip-xxx]
  python backend/convert.py book.pdf ...

Envs: use the matching conda env per stage automatically by invoking
subprocesses with the right python binary when available; otherwise runs
inline (single env must have all deps).
"""
import argparse
import importlib.util
import logging
import os
import subprocess
import sys
import json

# Ensure backend/ is on path when run as `python backend/convert.py`
_BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

from firebrat.pipeline.notify import send_telegram
from firebrat.pipeline.manifest import build_manifest
from firebrat.utils.ids import sanitize_book_id

log = logging.getLogger("firebrat")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

EXTRACT_PY = "/scratch/sroy85/conda-envs/firebrat-extract/bin/python"
SERVE_PY = "/scratch/sroy85/conda-envs/firebrat-serve/bin/python"
TTS_PY = "/scratch/sroy85/conda-envs/firebrat-tts/bin/python"


def parse_args():
    p = argparse.ArgumentParser(description="Firebrat PDF -> audiobook package")
    p.add_argument("pdf", help="Path to source PDF")
    p.add_argument("--output", "-o", default=None,
                   help="Output directory (default: backend/output)")
    p.add_argument("--book-id", default=None, help="Override book id")
    p.add_argument("--title", default=None, help="Override book title")
    p.add_argument("--pages", type=int, default=None,
                   help="Only process N pages starting at --start-page (for testing)")
    p.add_argument("--start-page", type=int, default=0,
                   help="0-based page index to start from when --pages is set")
    p.add_argument("--skip-extraction", action="store_true", help="Reuse existing raw_pages.json")
    p.add_argument("--skip-compilation", action="store_true", help="Reuse existing compiled.json")
    p.add_argument("--skip-tts", action="store_true", help="Skip TTS/audio assembly stage")
    p.add_argument("--skip-formulas", action="store_true", help="Skip LaTeX->PNG rendering")
    p.add_argument("--skip-package", action="store_true", help="Skip building the portable .tar.gz")
    p.add_argument("--voice-ref", default=None, help="Path to narrator reference wav for Chatterbox")
    return p.parse_args()


def _output_dir(args) -> str:
    if args.output:
        return os.path.abspath(args.output)
    return os.path.join(_BACKEND_DIR, "output")


def main():
    args = parse_args()
    pdf_path = os.path.abspath(args.pdf)
    if not os.path.isfile(pdf_path):
        log.error("PDF not found: %s", pdf_path)
        sys.exit(2)

    book_id = args.book_id or sanitize_book_id(pdf_path)
    out_root = _output_dir(args)
    pkg_dir = os.path.join(out_root, book_id)
    os.makedirs(pkg_dir, exist_ok=True)
    title = args.title or book_id.replace("-", " ").title()

    log.info("Firebrat convert: pdf=%s book_id=%s pkg_dir=%s", pdf_path, book_id, pkg_dir)
    send_telegram(f"🎧 Firebrat starting: *{book_id}* ({os.path.basename(pdf_path)})", parse_mode="Markdown")

    raw_json = os.path.join(pkg_dir, "raw", "raw_pages.json")
    compiled_json = os.path.join(pkg_dir, "raw", "compiled.json")
    alt_compiled = os.path.join(pkg_dir, "compiled.json")

    # ── Stage 1: extraction (batched, one subprocess per page range) ─────
    # This session's SLURM allocation caps total RAM at 6GB, and marker
    # batch-processes every page it's given at once — so for anything but a
    # tiny test slice, extraction runs in EXTRACT_BATCH_PAGES-sized chunks,
    # each a fresh subprocess, so memory is fully released between batches.
    if not args.skip_extraction:
        log.info("Stage 1: extraction (batched)")
        try:
            import pymupdf
            from firebrat.pipeline.extract_batch_cli import __file__ as _batch_cli_file
            from firebrat.pipeline.schema import RawPagesFile
            from firebrat.config import EXTRACT_BATCH_PAGES

            total_pdf_pages = pymupdf.open(pdf_path).page_count
            range_start = max(0, args.start_page) if args.pages is not None else 0
            range_end = min(range_start + args.pages, total_pdf_pages) if args.pages is not None else total_pdf_pages
            log.info("Extracting pages [%d, %d) of %d total, batch size %d",
                     range_start, range_end, total_pdf_pages, EXTRACT_BATCH_PAGES)

            all_pages: list[dict] = []
            fig_ctr, tbl_ctr, formula_ctr = 1, 1, 1
            marker_chars_total = 0
            batch_starts = list(range(range_start, range_end, EXTRACT_BATCH_PAGES))
            for bi, bstart in enumerate(batch_starts):
                blen = min(EXTRACT_BATCH_PAGES, range_end - bstart)
                out_json = os.path.join(pkg_dir, "raw", f"_batch_{bstart}.json")
                os.makedirs(os.path.dirname(out_json), exist_ok=True)
                cmd = [EXTRACT_PY, _batch_cli_file, pdf_path, pkg_dir,
                       str(bstart), str(blen), str(fig_ctr), str(tbl_ctr), str(formula_ctr), out_json]
                log.info("Batch %d/%d: pages [%d, %d)", bi + 1, len(batch_starts), bstart, bstart + blen)
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    log.error("Batch %d failed (pages [%d,%d)):\n%s", bi + 1, bstart, bstart + blen, result.stderr[-3000:])
                    send_telegram(f"⚠️ Firebrat extraction batch pages {bstart}-{bstart+blen} failed for *{book_id}*, skipping", parse_mode="Markdown")
                    continue
                with open(out_json, "r", encoding="utf-8") as f:
                    batch_result = json.load(f)
                all_pages.extend(batch_result["pages"])
                fig_ctr = batch_result["next_fig"]
                tbl_ctr = batch_result["next_tbl"]
                formula_ctr = batch_result["next_formula"]
                marker_chars_total += batch_result["marker_chars"]
                os.remove(out_json)
                if (bi + 1) % 5 == 0:
                    send_telegram(f"Firebrat extraction: {bi+1}/{len(batch_starts)} batches "
                                  f"(pages {bstart+blen}/{range_end}) done for *{book_id}*", parse_mode="Markdown")

            raw_out = {
                "book_id": book_id,
                "source_pdf": os.path.basename(pdf_path),
                "page_count": len(all_pages),
                "pages": all_pages,
            }
            RawPagesFile.model_validate(raw_out)
            os.makedirs(os.path.dirname(raw_json), exist_ok=True)
            with open(raw_json, "w", encoding="utf-8") as f:
                json.dump(raw_out, f, ensure_ascii=False, indent=2)

            stats = {
                "book_id": book_id, "page_count": len(all_pages),
                "figure_count": fig_ctr - 1, "formula_count": formula_ctr - 1,
                "marker_chars": marker_chars_total,
            }
            log.info("Stage 1 done: %s", stats)
            send_telegram(f"✅ Stage 1 extraction done for *{book_id}*: {stats['page_count']} pages, "
                          f"{stats['figure_count']} figures, {stats['formula_count']} formulas",
                          parse_mode="Markdown")
        except Exception as e:
            log.exception("Stage 1 failed")
            send_telegram(f"❌ Stage 1 extraction failed for *{book_id}*: {e}", parse_mode="Markdown")
            sys.exit(1)
    else:
        log.info("Skipping Stage 1 (--skip-extraction), expecting %s", raw_json)

    # ── Stage 1b: LaTeX -> PNG for formulas ──────────────────────
    # ── Stage 2: LLM compilation ─────────────────────────────────
    if not args.skip_compilation:
        if not os.path.isfile(raw_json):
            log.error("Need %s for compilation. Run without --skip-extraction first.", raw_json)
            sys.exit(2)
        log.info("Stage 2: LLM compilation")
        try:
            from firebrat.pipeline.compile_llm import run_compilation
            cstats = run_compilation(raw_json, pkg_dir, book_id=book_id)
            log.info("Stage 2 done: %s", cstats)
            send_telegram(f"✅ Stage 2 compilation done for *{book_id}*: "
                          f"{cstats['section_count']} sections from {cstats['chunk_count']} chunks",
                          parse_mode="Markdown")
        except Exception as e:
            log.exception("Stage 2 failed")
            send_telegram(f"❌ Stage 2 compilation failed for *{book_id}*: {e}", parse_mode="Markdown")
            sys.exit(1)
    else:
        log.info("Skipping Stage 2 (--skip-compilation)")

    # Resolve compiled path for downstream stages
    if os.path.isfile(compiled_json):
        compiled_path = compiled_json
    elif os.path.isfile(alt_compiled):
        compiled_path = alt_compiled
    else:
        compiled_path = None  # type: ignore

    # ── Stage 2b: LaTeX -> PNG for LLM-authored formulas ─────────
    # Formulas are authored by the Stage 2 LLM (not Stage 1 extracted — this book
    # typesets math as plain inline text), so rendering happens after compilation.
    if not args.skip_formulas and compiled_path:
        try:
            from firebrat.pipeline.formulas import render_all_formulas
            with open(compiled_path, "r", encoding="utf-8") as f:
                compiled_for_formulas = json.load(f)
            formulas_list = compiled_for_formulas.get("formulas", [])
            if formulas_list:
                log.info("Rendering %d LLM-authored formulas to PNG", len(formulas_list))
                formulas_dir = os.path.join(pkg_dir, "assets", "formulas")
                render_all_formulas(formulas_list, formulas_dir)
        except Exception as e:
            log.warning("Formula rendering encountered errors (non-fatal): %s", e)

    # ── Pre-stage 3: build a minimal manifest early so we have section ids before TTS ──
    # If compiled exists but no manifest yet, create one (TTS will populate audio later)
    if compiled_path and not os.path.isfile(os.path.join(pkg_dir, "manifest.json")):
        try:
            build_manifest(pkg_dir, book_id, title, os.path.basename(pdf_path), voice_ref=args.voice_ref)
        except Exception as e:
            log.warning("Early manifest build failed (non-fatal): %s", e)

    # ── Stage 3: TTS + audio assembly ────────────────────────────
    # chatterbox-tts lives only in the firebrat-tts conda env (its torch/transformers
    # pins conflict with marker-pdf's). If this process doesn't have chatterbox,
    # delegate Stage 3 to the tts env's python as a subprocess instead of crashing.
    if not args.skip_tts and compiled_path and importlib.util.find_spec("chatterbox") is None:
        if os.path.realpath(sys.executable) == os.path.realpath(TTS_PY):
            log.error("Running under the tts env python but 'chatterbox' still not importable — env is broken.")
            sys.exit(1)
        if not os.path.isfile(TTS_PY):
            log.error("chatterbox not importable here and tts env python not found at %s", TTS_PY)
            sys.exit(1)
        log.info("Delegating Stage 3 (TTS) to %s", TTS_PY)
        delegate_args = [
            TTS_PY, os.path.abspath(__file__), pdf_path,
            "--output", out_root, "--book-id", book_id, "--title", title,
            "--skip-extraction", "--skip-compilation", "--skip-formulas",
        ]
        if args.voice_ref:
            delegate_args += ["--voice-ref", args.voice_ref]
        result = subprocess.run(delegate_args)
        sys.exit(result.returncode)

    if not args.skip_tts and compiled_path:
        log.info("Stage 3: TTS + audio assembly")
        # Need segment wavs dir
        seg_wavs_dir = os.path.join(pkg_dir, "_segment_wavs")
        os.makedirs(seg_wavs_dir, exist_ok=True)
        try:
            # TTS: synthesize each segment
            from firebrat.pipeline.tts import FirebratTTS
            from firebrat.utils.ids import make_segment_id
            with open(compiled_path, "r", encoding="utf-8") as f:
                compiled = json.load(f)

            # Ensure section/segment ids present before TTS
            from firebrat.utils.ids import make_section_id as _ms
            for oi, sec in enumerate(compiled.get("sections", [])):
                sec.setdefault("section_id", _ms(oi + 1))
                for si, seg in enumerate(sec.get("segments", [])):
                    seg.setdefault("segment_id", make_segment_id(sec["section_id"], si))

            # Persist normalized compiled back to disk so manifest stage agrees
            with open(compiled_path, "w", encoding="utf-8") as f:
                json.dump(compiled, f, ensure_ascii=False, indent=2)

            tts = FirebratTTS(voice_ref=args.voice_ref)
            # Synthesize section by section so failures are isolated
            from firebrat.pipeline.audio_assemble import assemble_section
            from firebrat.pipeline.notify import send_telegram as _notify

            total_sections = len(compiled.get("sections", []))
            for idx, sec in enumerate(compiled.get("sections", [])):
                sid = sec["section_id"]
                segs = sec.get("segments", [])
                log.info("TTS section %d/%d %s (%d segments)", idx+1, total_sections, sid, len(segs))
                # synthesize this section's segments
                seg_wavs: dict[str, str] = {}
                for seg in segs:
                    wav_path = os.path.join(seg_wavs_dir, f"{seg['segment_id']}.wav")
                    ok = tts.synthesize(seg.get("text", ""), wav_path)
                    if ok:
                        seg_wavs[seg["segment_id"]] = wav_path
                    else:
                        # placeholder silence already handled inside synthesize
                        if os.path.isfile(wav_path):
                            seg_wavs[seg["segment_id"]] = wav_path
                assemble_section(sec, segs, seg_wavs, pkg_dir)
                if (idx + 1) % 3 == 0:
                    _notify(f"Firebrat TTS: {idx+1}/{total_sections} sections done for *{book_id}*",
                            parse_mode="Markdown")

            log.info("Stage 3 TTS+assembly done for %s", book_id)
            send_telegram(f"✅ Stage 3 audio done for *{book_id}*", parse_mode="Markdown")
        except Exception as e:
            log.exception("Stage 3 failed")
            send_telegram(f"❌ Stage 3 audio failed for *{book_id}*: {e}", parse_mode="Markdown")
            sys.exit(1)
    elif args.skip_tts:
        log.info("Skipping Stage 3 (--skip-tts)")

    # ── Final manifest ───────────────────────────────────────────
    try:
        mpath = build_manifest(pkg_dir, book_id, title, os.path.basename(pdf_path), voice_ref=args.voice_ref)
        log.info("Manifest: %s", mpath)
        # Brief summary
        with open(mpath, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        secs = len(manifest.get("sections", []))
        figs = len(manifest.get("figures", []))
        forms = len(manifest.get("formulas", []))
        dur = manifest.get("total_duration_ms", 0)
        log.info("Done: %s — %d sections, %d figures, %d formulas, %.1f min audio",
                 book_id, secs, figs, forms, dur / 60000 if dur else 0)
        send_telegram(
            f"🎉 Firebrat done: *{book_id}* — {secs} sections, {figs} figures, {forms} formulas, "
            f"{dur//60000} min {dur%60000//1000:02d}s audio\n`{mpath}`",
            parse_mode="Markdown",
        )
    except Exception as e:
        log.exception("Manifest build failed")
        send_telegram(f"❌ Manifest failed for *{book_id}*: {e}", parse_mode="Markdown")
        sys.exit(1)

    # ── Portable package (.tar.gz) ───────────────────────────────
    # A single file the Flutter app can import directly (no backend server
    # needed) — copy it to a device via USB/sideload/messaging and use the
    # app's "Import from file" picker.
    if not args.skip_package:
        try:
            from firebrat.pipeline.package import package_book
            archive_path = package_book(pkg_dir)
            archive_mb = os.path.getsize(archive_path) / (1024 * 1024)
            log.info("Packaged: %s (%.1f MB)", archive_path, archive_mb)
            send_telegram(f"📦 Firebrat packaged *{book_id}*: `{archive_path}` ({archive_mb:.0f} MB)",
                          parse_mode="Markdown")
        except Exception as e:
            log.exception("Packaging failed (non-fatal — book package on disk is still complete)")
            send_telegram(f"⚠️ Firebrat packaging failed for *{book_id}* (book itself is fine): {e}",
                          parse_mode="Markdown")

if __name__ == "__main__":
    main()

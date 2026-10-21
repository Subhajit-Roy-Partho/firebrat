#!/usr/bin/env python3
"""One-off backfill: embed source PDFs + source_pages into live packages.

For each (book_id, input PDF): copies the PDF to <pkg>/source.pdf, then
patches manifest.json with `source_pdf_path: "source.pdf"` and per-section
`source_pages` taken from compiled.json (matched by section_id, falling
back to order), re-validating with the pydantic Manifest model.

Usage (serve env has everything needed — pydantic comes with fastapi):
    PYTHONPATH=backend /scratch/sroy85/conda-envs/firebrat-serve/bin/python \
        backend/scripts/backfill_source_pdf.py
"""
import json
import os
import shutil
import sys

_BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

from firebrat.pipeline.schema import Manifest  # noqa: E402

BOOKS = [
    ("arm-fundamentals-soc", "input/arm-fundamentals-soc.pdf"),
    ("digital-design-and-computer-architecture",
     "input/digital-design-and-computer-architecture.pdf"),
]


def main() -> None:
    repo_root = os.path.dirname(_BACKEND_DIR)
    for book_id, input_rel in BOOKS:
        pkg_dir = os.path.join(repo_root, "backend", "output", book_id)
        src_pdf = os.path.join(repo_root, input_rel)
        assert os.path.isfile(src_pdf), f"missing input PDF: {src_pdf}"
        assert os.path.isdir(pkg_dir), f"missing package: {pkg_dir}"

        dest = os.path.join(pkg_dir, "source.pdf")
        if not (os.path.isfile(dest) and os.path.getsize(dest) == os.path.getsize(src_pdf)):
            shutil.copyfile(src_pdf, dest)
            print(f"[{book_id}] copied {os.path.getsize(dest)} bytes -> source.pdf")
        else:
            print(f"[{book_id}] source.pdf already present, skipping copy")

        compiled_path = os.path.join(pkg_dir, "compiled.json")
        with open(compiled_path, "r", encoding="utf-8") as f:
            compiled = json.load(f)
        by_id = {s.get("section_id"): s for s in compiled.get("sections", [])}

        manifest_path = os.path.join(pkg_dir, "manifest.json")
        with open(manifest_path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
        manifest["source_pdf_path"] = "source.pdf"
        for i, sec in enumerate(manifest.get("sections", [])):
            csec = by_id.get(sec.get("section_id"))
            if csec is None and i < len(compiled.get("sections", [])):
                csec = compiled["sections"][i]  # order fallback
            sec["source_pages"] = list((csec or {}).get("source_pages") or [])

        Manifest.model_validate(manifest)  # fail loudly if shape is wrong
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2)
        n_with = sum(1 for s in manifest["sections"] if s.get("source_pages"))
        print(f"[{book_id}] manifest patched: source_pdf_path=source.pdf, "
              f"{n_with}/{len(manifest['sections'])} sections have source_pages")


if __name__ == "__main__":
    main()

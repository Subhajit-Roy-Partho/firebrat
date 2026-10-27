"""Packaging: zip a finished package (stored audio) + write built.json.

Mirrors ``build_book.py``: the zip uses ZIP_STORED (section audio is already
compressed AAC/MP3), keeps ``manifest.json`` + ``sections/`` + ``assets/``
plus ``character_roster.json``/cover when present, and records ``built.json``
``{slug, zip, bytes, sections, durationMs}`` next to the package.
"""
from __future__ import annotations

import glob
import logging
import os
import zipfile

log = logging.getLogger(__name__)


def validate_package(pkg_dir: str) -> dict:
    """Raise unless the package has a manifest and at least one audio file."""
    manifest_path = os.path.join(pkg_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise FileNotFoundError(f"No manifest.json in {pkg_dir}; synthesize first")
    audios: list[str] = []
    for ext in ("audio.m4a", "audio.mp3", "audio.wav"):
        audios.extend(glob.glob(os.path.join(pkg_dir, "sections", "*", ext)))
    if not audios:
        raise FileNotFoundError(f"No section audio in {pkg_dir}/sections; synthesize first")
    return {"manifest": manifest_path, "audio_files": sorted(audios)}


def zip_package(pkg_dir: str, out_zip: str | None = None) -> str:
    """Zip the finished package. Returns the zip path."""
    from firebrat_cast.fetch import read_json, write_json_atomic

    validate_package(pkg_dir)
    manifest = read_json(os.path.join(pkg_dir, "manifest.json"))
    slug = manifest.get("book_id") or os.path.basename(os.path.abspath(pkg_dir))
    out_zip = out_zip or os.path.join(os.path.dirname(os.path.abspath(pkg_dir)), f"{slug}.zip")
    names: list[str] = ["manifest.json"]
    for extra in ("character_roster.json", "compiled.json"):
        if os.path.isfile(os.path.join(pkg_dir, extra)):
            names.append(extra)
    for top in ("sections", "assets"):
        if os.path.isdir(os.path.join(pkg_dir, top)):
            for r, _, fs in os.walk(os.path.join(pkg_dir, top)):
                for f in sorted(fs):
                    names.append(os.path.relpath(os.path.join(r, f), pkg_dir))
    for cover in glob.glob(os.path.join(pkg_dir, "cover.*")):
        names.append(os.path.basename(cover))
    os.makedirs(os.path.dirname(os.path.abspath(out_zip)), exist_ok=True)
    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_STORED) as z:
        for name in names:
            full = os.path.join(pkg_dir, name)
            if os.path.isfile(full):
                z.write(full, name)
    size = os.path.getsize(out_zip)
    sections = manifest.get("sections", []) or []
    built = {"slug": slug, "zip": out_zip, "bytes": size,
             "sections": len(sections), "durationMs": manifest.get("total_duration_ms", 0)}
    write_json_atomic(os.path.join(pkg_dir, "built.json"), built)
    log.info("ZIP %s (%d bytes, %d sections)", out_zip, size, len(sections))
    return out_zip

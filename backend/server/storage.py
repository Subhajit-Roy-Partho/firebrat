"""Locates book packages under OUTPUT_DIR, builds zips, guards paths."""
import os
import json
import time
import hashlib
import zipfile
import tempfile
from pathlib import Path

from server.config import OUTPUT_DIR

def list_book_ids() -> list[str]:
    if not os.path.isdir(OUTPUT_DIR):
        return []
    return sorted(d for d in os.listdir(OUTPUT_DIR)
                  if os.path.isdir(os.path.join(OUTPUT_DIR, d))
                  and os.path.isfile(os.path.join(OUTPUT_DIR, d, "manifest.json")))

def package_dir(book_id: str) -> str:
    return os.path.join(OUTPUT_DIR, book_id)

def manifest_path(book_id: str) -> str:
    return os.path.join(package_dir(book_id), "manifest.json")

def read_manifest(book_id: str) -> dict | None:
    path = manifest_path(book_id)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def _safe_join(base: str, rel: str) -> str | None:
    """Return absolute path if rel stays inside base, else None."""
    base = os.path.realpath(base)
    target = os.path.realpath(os.path.join(base, rel))
    # Allow exactly base, or inside base/
    if target == base or target.startswith(base + os.sep):
        return target
    return None

def resolve_asset(book_id: str, asset_path: str) -> str | None:
    base = package_dir(book_id)
    full = _safe_join(base, asset_path)
    if full is None or not os.path.isfile(full):
        return None
    return full

def _dir_size(path: str) -> int:
    total = 0
    for dirpath, _, filenames in os.walk(path):
        for fn in filenames:
            try:
                total += os.path.getsize(os.path.join(dirpath, fn))
            except OSError:
                pass
    return total

def book_summary(book_id: str) -> dict | None:
    manifest = read_manifest(book_id)
    if manifest is None:
        return None
    pkg = package_dir(book_id)
    return {
        "book_id": book_id,
        "title": manifest.get("title", book_id),
        "author": manifest.get("author", ""),
        "total_duration_ms": manifest.get("total_duration_ms", 0),
        "section_count": len(manifest.get("sections", [])),
        "size_bytes": _dir_size(pkg),
        "updated_at": manifest.get("generated_at", ""),
    }

# Simple zip cache: {book_id: (mtime, zip_path)}
_zip_cache: dict[str, tuple[float, str]] = {}

def get_or_build_zip(book_id: str) -> str | None:
    """Return path to zip for book_id, building/caching as needed. Caller should not delete."""
    manifest = manifest_path(book_id)
    if not os.path.isfile(manifest):
        return None
    mtime = os.path.getmtime(manifest)
    cached = _zip_cache.get(book_id)
    if cached and cached[0] == mtime and os.path.isfile(cached[1]):
        return cached[1]

    pkg = package_dir(book_id)
    tmpdir = tempfile.gettempdir()
    zpath = os.path.join(tmpdir, f"firebrat_{book_id}.zip")
    # build
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, _, filenames in os.walk(pkg):
            for fn in filenames:
                full = os.path.join(dirpath, fn)
                arc = os.path.relpath(full, pkg)
                z.write(full, arc)
    _zip_cache[book_id] = (mtime, zpath)
    return zpath

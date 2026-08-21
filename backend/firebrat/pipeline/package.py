"""Packages a finished book directory into a single portable .tar.gz.

This is what makes a book shareable/movable outside the client-server
download flow — copy one file to a phone's storage (sideload, USB, a
messaging app, whatever) and the Flutter app can import it directly via
its "Import from file" picker, no backend server reachable required.
"""
import logging
import os
import tarfile

log = logging.getLogger(__name__)


def package_book(pkg_dir: str, out_path: str | None = None) -> str:
    """Tar+gzip pkg_dir's contents (not the directory itself) into out_path.

    pkg_dir: e.g. backend/output/<book_id>/ (must contain manifest.json)
    out_path: defaults to <pkg_dir>.tar.gz alongside pkg_dir

    The archive's top-level entries are the package's files directly
    (manifest.json, sections/, assets/, ...) — extracting it into a fresh
    directory reproduces pkg_dir's layout with no extra nesting, matching
    what the FastAPI /download zip already does.
    """
    manifest_path = os.path.join(pkg_dir, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise FileNotFoundError(f"{pkg_dir} has no manifest.json — not a finished book package")

    if out_path is None:
        out_path = pkg_dir.rstrip("/\\") + ".tar.gz"

    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    tmp_path = out_path + ".tmp"

    with tarfile.open(tmp_path, "w:gz") as tar:
        for entry in sorted(os.listdir(pkg_dir)):
            full = os.path.join(pkg_dir, entry)
            tar.add(full, arcname=entry)

    os.replace(tmp_path, out_path)
    size_mb = os.path.getsize(out_path) / (1024 * 1024)
    log.info("Packaged %s -> %s (%.1f MB)", pkg_dir, out_path, size_mb)
    return out_path

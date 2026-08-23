"""Machine-readable progress for one conversion run, written into the book's
own package directory as status.json. This is what lets the server report
live progress (and the app/web UI poll it) without parsing log output —
convert.py calls write_status() at each stage transition; the server's job
endpoints just read the file back.
"""
import json
import os
import time

STATUS_FILENAME = "status.json"


def status_path(pkg_dir: str) -> str:
    return os.path.join(pkg_dir, STATUS_FILENAME)


def write_status(pkg_dir: str, **fields) -> None:
    """Merge [fields] into pkg_dir/status.json, atomically.

    Merging (not overwriting) lets each stage set only what changed — e.g.
    Stage 3 keeps updating `detail`/`progress` without clobbering
    `needs_review_count` that Stage 2 set earlier.
    """
    path = status_path(pkg_dir)
    data: dict = {}
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            data = {}
    data.update(fields)
    data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    os.makedirs(pkg_dir, exist_ok=True)
    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp_path, path)


def read_status(pkg_dir: str) -> dict | None:
    path = status_path(pkg_dir)
    if not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None

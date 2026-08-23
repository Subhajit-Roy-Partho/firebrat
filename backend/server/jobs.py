"""Conversion job bookkeeping — a tiny SQLite table tracking one row per
upload. The live per-run progress (stage/detail/progress/needs_review_count)
comes from firebrat.pipeline.status.read_status() reading each job's
pkg_dir/status.json directly, not from this table — this table exists only
for what status.json can't know: the queued-but-not-yet-started state, the
original upload filename, and retry bookkeeping.

Connections are opened per call rather than once at import time — sqlite is
cheap for this volume, and it means server.config.JOBS_DB_PATH can be
monkeypatched (e.g. in tests) any time before a call, not just before this
module is first imported.
"""
import os
import sqlite3
import time
import uuid

from server import config

_SCHEMA = """
CREATE TABLE IF NOT EXISTS jobs (
    job_id TEXT PRIMARY KEY,
    book_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    title TEXT NOT NULL,
    pdf_path TEXT NOT NULL,
    state TEXT NOT NULL,        -- queued | running | done | failed
    error TEXT,
    retry_count INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
)
"""


def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(config.JOBS_DB_PATH), exist_ok=True)
    conn = sqlite3.connect(config.JOBS_DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(_SCHEMA)
    return conn


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def create_job(book_id: str, filename: str, title: str, pdf_path: str) -> str:
    job_id = uuid.uuid4().hex[:16]
    now = _now()
    conn = _connect()
    try:
        conn.execute(
            "INSERT INTO jobs (job_id, book_id, filename, title, pdf_path, state, retry_count, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, 'queued', 0, ?, ?)",
            (job_id, book_id, filename, title, pdf_path, now, now),
        )
        conn.commit()
    finally:
        conn.close()
    return job_id


def set_state(job_id: str, state: str, error: str | None = None) -> None:
    conn = _connect()
    try:
        conn.execute(
            "UPDATE jobs SET state = ?, error = ?, updated_at = ? WHERE job_id = ?",
            (state, error, _now(), job_id),
        )
        conn.commit()
    finally:
        conn.close()


def increment_retry(job_id: str) -> None:
    conn = _connect()
    try:
        conn.execute(
            "UPDATE jobs SET state = 'queued', error = NULL, retry_count = retry_count + 1, updated_at = ? WHERE job_id = ?",
            (_now(), job_id),
        )
        conn.commit()
    finally:
        conn.close()


def get_job(job_id: str) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM jobs WHERE job_id = ?", (job_id,)).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None


def list_jobs() -> list[dict]:
    conn = _connect()
    try:
        rows = conn.execute("SELECT * FROM jobs ORDER BY created_at DESC").fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def latest_job_for_book(book_id: str) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT * FROM jobs WHERE book_id = ? ORDER BY created_at DESC LIMIT 1", (book_id,)
        ).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None

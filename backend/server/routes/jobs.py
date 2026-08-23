"""Upload a PDF, watch it convert, retry the parts that didn't come out
clean. See docs/API.md for the full contract.
"""
import os

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from server import config, job_runner, jobs
from firebrat.pipeline.status import read_status
from firebrat.utils.ids import sanitize_book_id

router = APIRouter()


def _job_view(job: dict) -> dict:
    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    status = read_status(pkg_dir) or {}
    return {
        "job_id": job["job_id"],
        "book_id": job["book_id"],
        "filename": job["filename"],
        "title": job["title"],
        "state": job["state"],  # queued | running | done | failed
        "stage": status.get("stage"),
        "detail": status.get("detail"),
        "progress": status.get("progress"),
        "needs_review_count": status.get("needs_review_count", 0),
        # status.json's error (the pipeline's own reason) is more specific
        # than the generic "process exited N" job_runner falls back to when
        # the subprocess died before ever writing a status.json at all.
        "error": status.get("error") or job["error"],
        "retry_count": job["retry_count"],
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }


@router.post("/books/upload")
async def upload_book(file: UploadFile = File(...), title: str | None = Form(None)):
    if not file.filename or not file.filename.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="only .pdf uploads are accepted")

    os.makedirs(config.UPLOAD_DIR, exist_ok=True)
    book_id = sanitize_book_id(file.filename)
    # Disambiguate a repeat filename so re-uploading the same book creates a
    # fresh conversion rather than colliding with (or silently overwriting)
    # a previous run's package directory.
    if os.path.isdir(os.path.join(config.OUTPUT_DIR, book_id)):
        n = 2
        while os.path.isdir(os.path.join(config.OUTPUT_DIR, f"{book_id}-{n}")):
            n += 1
        book_id = f"{book_id}-{n}"

    dest_path = os.path.join(config.UPLOAD_DIR, f"{book_id}.pdf")
    size = 0
    max_bytes = config.MAX_UPLOAD_MB * 1024 * 1024
    with open(dest_path, "wb") as out:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > max_bytes:
                out.close()
                os.remove(dest_path)
                raise HTTPException(status_code=413, detail=f"file exceeds {config.MAX_UPLOAD_MB} MB limit")
            out.write(chunk)

    book_title = title or book_id.replace("-", " ").title()
    job_id = jobs.create_job(book_id=book_id, filename=file.filename, title=book_title, pdf_path=dest_path)
    job_runner.enqueue(job_id)
    return _job_view(jobs.get_job(job_id))


@router.get("/jobs")
def list_jobs():
    return [_job_view(j) for j in jobs.list_jobs()]


@router.get("/jobs/{job_id}")
def get_job(job_id: str):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return _job_view(job)


@router.post("/jobs/{job_id}/retry")
def retry_job(job_id: str):
    """Re-run a failed (or needs_review) job, reusing whatever already
    succeeded on disk rather than starting over. Which stages get skipped
    depends on how far the previous attempt got — see docs/API.md.
    """
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    if job["state"] not in ("failed", "done"):
        raise HTTPException(status_code=409, detail=f"job is {job['state']}, not retryable yet")
    if not os.path.isfile(job["pdf_path"]):
        raise HTTPException(status_code=410, detail="original upload no longer on disk, re-upload to retry")

    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    status = read_status(pkg_dir) or {}
    stage = status.get("stage")

    extra_args: list[str] = ["--retry-failed"]
    if stage in ("compiling", "rendering_formulas", "synthesizing", "packaging", "manifest", "done"):
        # Extraction already produced raw_pages.json — never redo it.
        extra_args.append("--skip-extraction")
    # A "done" job being retried means the caller wants needs_review chunks
    # re-attempted (e.g. after switching FIREBRAT_SPARK_MODEL to the strong
    # tier) — compilation, formulas, and TTS all stay resumable so this is
    # cheap: --retry-failed only redoes flagged chunks/sections, everything
    # else already on disk is reused as-is (see convert.py Stage 2/3).

    jobs.increment_retry(job_id)
    job_runner.enqueue(job_id, extra_args)
    return _job_view(jobs.get_job(job_id))


@router.get("/jobs/{job_id}/log")
def get_job_log(job_id: str, tail_lines: int = 200):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    log_path = os.path.join(config.OUTPUT_DIR, job["book_id"], "convert_stdout.log")
    if not os.path.isfile(log_path):
        return JSONResponse(content={"lines": []})
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    return JSONResponse(content={"lines": [ln.rstrip("\n") for ln in lines[-tail_lines:]]})

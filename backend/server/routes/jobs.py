"""Upload a PDF (or a .zip of PDFs, merged in archive order), watch it
convert, retry the parts that didn't come out clean. See docs/API.md
for the full contract.
"""
import os
import tempfile

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from firebrat.pipeline import character_traits as character_traits_mod
from server import auth, config, job_runner, jobs, storage
from server.pdf_merge import merge_zip_pdfs_to_pdf
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
        "state": job["state"],  # queued | running | done | failed | cancelled
        "stage": status.get("stage"),
        "detail": status.get("detail"),
        "progress": status.get("progress"),
        "needs_review_count": status.get("needs_review_count", 0),
        # status.json's error (the pipeline's own reason) is more specific
        # than the generic "process exited N" job_runner falls back to when
        # the subprocess died before ever writing a status.json at all.
        "error": status.get("error") or job["error"],
        "retry_count": job["retry_count"],
        "content_mode": job.get("content_mode") or "illustrated",
        "research_characters": bool(job.get("research_characters")),
        "character_traits": job.get("character_traits") or "",
        "provider": job.get("provider") or "nanogpt",
        "model": job.get("model") or "",
        "chunk_pages": job.get("chunk_pages") or 0,
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }


@router.post("/books/upload")
async def upload_book(
    file: UploadFile = File(...),
    title: str | None = Form(None),
    provider: str = Form(""),
    model: str = Form(""),
    chunk_pages: int = Form(0),
    content_mode: str = Form("illustrated"),
    research_characters: bool = Form(False),
    character_traits: str = Form(""),
    _user: dict = Depends(auth.require_user),
):
    if content_mode not in ("illustrated", "novel"):
        raise HTTPException(status_code=422, detail="content_mode must be illustrated or novel")
    # Novel casting options: one "Name=traits" per line (ages/temperaments/
    # genders only; validated so a typo is a 422, not a silently ignored line).
    traits_lines = []
    for line in (character_traits or "").splitlines():
        if not line.strip():
            continue
        name, sep, spec = line.partition("=")
        _voice, parsed = character_traits_mod.parse_spec(spec)
        if not sep or not name.strip() or parsed is None:
            raise HTTPException(status_code=422, detail=f"character_traits line must look like 'Name=elder gruff': {line.strip()[:80]!r}")
        traits_lines.append(f"{name.strip()}={spec.strip()}")
    lname = (file.filename or "").lower()
    is_pdf = lname.endswith(".pdf")
    is_zip = lname.endswith(".zip")
    if not file.filename or (not is_pdf and not is_zip):
        raise HTTPException(status_code=400, detail="only .pdf or .zip (of PDFs) uploads are accepted")

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
    if is_zip:
        # Stream the zip to a temp file first (size-capped like a plain PDF
        # upload), then normalize it to a single source PDF so the rest of
        # the pipeline — convert.py, retry, resume — stays single-PDF.
        fd, tmp_zip = tempfile.mkstemp(prefix=f"{book_id}_", suffix=".zip",
                                       dir=config.UPLOAD_DIR)
        try:
            with os.fdopen(fd, "wb") as out:
                while chunk := await file.read(1024 * 1024):
                    size += len(chunk)
                    if size > max_bytes:
                        raise HTTPException(status_code=413, detail=f"file exceeds {config.MAX_UPLOAD_MB} MB limit")
                    out.write(chunk)
            try:
                merge_zip_pdfs_to_pdf(tmp_zip, dest_path)
            except ValueError as e:
                raise HTTPException(status_code=400, detail=str(e))
            except RuntimeError as e:
                raise HTTPException(status_code=500, detail=str(e))
        finally:
            try:
                os.remove(tmp_zip)
            except OSError:
                pass
            # A 413 raised mid-stream leaves the fd-managed file behind only
            # if mkstemp's file was never renamed — it wasn't, so remove any
            # partial dest too when the zip path failed before merging.
            if size > max_bytes and os.path.isfile(dest_path):
                try:
                    os.remove(dest_path)
                except OSError:
                    pass
    else:
        with open(dest_path, "wb") as out:
            while chunk := await file.read(1024 * 1024):
                size += len(chunk)
                if size > max_bytes:
                    out.close()
                    os.remove(dest_path)
                    raise HTTPException(status_code=413, detail=f"file exceeds {config.MAX_UPLOAD_MB} MB limit")
                out.write(chunk)

    book_title = title or book_id.replace("-", " ").title()
    # Empty provider/chunk (the mobile app sends neither) inherits the
    # server defaults from /settings.
    from server.routes.settings import read_settings as _read_settings
    _defaults = _read_settings()
    eff_provider = (provider or _defaults.get("default_provider") or "nanogpt")
    # Optional cloud-model override for this job only; empty preserves the
    # FIREBRAT_SPARK/DEEPSEEK_MODEL env defaults. Stripped, length-capped,
    # never validated against a live list (ids change; a bad id fails
    # honestly in the pipeline, not here). Ignored for local-provider jobs.
    eff_model = ((model or "").strip())[:200]
    try:
        eff_chunk = int(chunk_pages or 0)
    except (TypeError, ValueError):
        eff_chunk = 0
    if eff_chunk <= 0:
        try:
            eff_chunk = int(_defaults.get("default_chunk_pages") or 0)
        except (TypeError, ValueError):
            eff_chunk = 0
    job_id = jobs.create_job(book_id=book_id, filename=file.filename, title=book_title, pdf_path=dest_path,
                             provider=eff_provider, chunk_pages=eff_chunk, model=eff_model,
                             content_mode=content_mode,
                             research_characters=bool(research_characters) and content_mode == "novel",
                             character_traits="\n".join(traits_lines) if content_mode == "novel" else "")
    job_runner.enqueue(job_id)
    return _job_view(jobs.get_job(job_id))


@router.get("/jobs")
def list_jobs(_user: dict = Depends(auth.require_user)):
    return [_job_view(j) for j in jobs.list_jobs()]


@router.get("/jobs/{job_id}")
def get_job(job_id: str, _user: dict = Depends(auth.require_user)):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return _job_view(job)


@router.post("/jobs/{job_id}/retry")
def retry_job(job_id: str, _user: dict = Depends(auth.require_user)):
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
    # A "done" job being retried means the caller wants needs_review chunks
    # re-attempted (e.g. after switching FIREBRAT_SPARK_MODEL to the strong
    # tier) — compilation, formulas, and TTS all stay resumable so this is
    # cheap: --retry-failed only redoes flagged chunks/sections, everything
    # else already on disk is reused as-is (see convert.py Stage 2/3).
    extra_args = ["--retry-failed"] + job_runner.skip_extraction_arg_for_stage(status.get("stage"))

    jobs.increment_retry(job_id)
    job_runner.enqueue(job_id, extra_args)
    return _job_view(jobs.get_job(job_id))


@router.post("/jobs/{job_id}/resume")
def resume_job(job_id: str, _user: dict = Depends(auth.require_user)):
    """Puts a stuck job back on the queue, unchanged — for a job left in
    `queued` or `running` state by something that isn't the pipeline's own
    logic (a server restart while it was mid-flight is the common case: the
    in-memory work queue is empty again after restart, but the job's row
    still says "running" since nothing told it otherwise). The server
    already does this automatically on startup for every such job (see
    job_runner.resume_orphaned_jobs) — this endpoint exists for the rarer
    case a job still looks stuck for some other reason and the user just
    wants to nudge it. Unlike retry, this does NOT pass --retry-failed —
    it only continues from checkpoint, it doesn't redo flagged content.
    """
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    if job["state"] not in ("queued", "running"):
        raise HTTPException(status_code=409, detail=f"job is {job['state']}, nothing to resume")
    if not os.path.isfile(job["pdf_path"]):
        raise HTTPException(status_code=410, detail="original upload no longer on disk, cannot resume")

    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    status = read_status(pkg_dir) or {}
    extra_args = job_runner.skip_extraction_arg_for_stage(status.get("stage"))

    jobs.set_state(job_id, "queued")
    job_runner.enqueue(job_id, extra_args)
    return _job_view(jobs.get_job(job_id))


@router.post("/jobs/{job_id}/convert-now")
def convert_now_job(job_id: str, _user: dict = Depends(auth.require_user)):
    """Jump a queued job to the front: pause every running conversion (its
    partial output stays on disk for checkpoint resume) and run this job
    next. 404 on unknown ids, 409 unless the job is `queued`. Pausing never
    deletes uploads or packages.
    """
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    if job["state"] != "queued":
        raise HTTPException(status_code=409, detail=f"job is {job['state']}, only queued jobs can jump the queue")
    if not os.path.isfile(job["pdf_path"]):
        raise HTTPException(status_code=410, detail="original upload no longer on disk, cannot convert")
    job_runner.promote_now(job_id)
    return _job_view(jobs.get_job(job_id))


@router.delete("/jobs/{job_id}")
def delete_job(job_id: str, remove_files: bool = True, _user: dict = Depends(auth.require_user)):
    """Cancel a queued/running job, or forget a finished one.

    - `running`: flags the row `cancelled` (terminal) and terminates its
      convert.py subprocess; the row is KEPT so the client can see the
      cancelled state. Files are kept too (partial output may aid retry).
    - `queued` / `done` / `failed` / `cancelled`: deletes the row. A queued
      job is flagged cancelled first so a worker that already dequeued it
      skips convert.py instead of running it (a worker that hasn't dequeued
      it yet finds no row and skips the same way).
    - `remove_files` (default true): also deletes this job's own upload PDF
      and its partial/final package directory — never any other job's.
    - Unknown ids 404, never 500.
    """
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    if job["state"] == "running":
        jobs.request_cancel(job_id)
        job_runner.cancel_running(job_id)
        return _job_view(jobs.get_job(job_id))
    jobs.request_cancel(job_id)  # no-op unless queued; marks skip-flag
    deleted = jobs.delete_job(job_id)
    assert deleted is not None  # fetched above; no concurrent deleter exists
    removed_files = _remove_job_files(deleted) if remove_files else False
    return {"job_id": job_id, "deleted": True, "removed_files": removed_files}


def _remove_job_files(job: dict) -> bool:
    """Delete only this job's upload PDF and package dir. Returns True if
    anything was removed."""
    removed = False
    pdf_path = job.get("pdf_path") or ""
    try:
        up = os.path.realpath(config.UPLOAD_DIR)
        pp = os.path.realpath(pdf_path)
        if pp.startswith(up + os.sep) and os.path.isfile(pp):
            os.remove(pp)
            removed = True
    except OSError:
        pass
    try:
        if storage.delete_book(job["book_id"]):
            removed = True
    except OSError:
        pass
    return removed


@router.get("/jobs/{job_id}/log")
def get_job_log(job_id: str, tail_lines: int = 200, _user: dict = Depends(auth.require_user)):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    log_path = os.path.join(config.OUTPUT_DIR, job["book_id"], "convert_stdout.log")
    if not os.path.isfile(log_path):
        return JSONResponse(content={"lines": []})
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    return JSONResponse(content={"lines": [ln.rstrip("\n") for ln in lines[-tail_lines:]]})

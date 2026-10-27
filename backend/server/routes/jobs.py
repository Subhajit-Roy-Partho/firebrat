"""Upload a PDF (or a .zip of PDFs, merged in archive order), watch it
convert, retry the parts that didn't come out clean. See docs/API.md
for the full contract.
"""
import os
import tempfile
import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

from firebrat.pipeline import character_traits as character_traits_mod
from firebrat.pipeline import ebook as ebook_mod
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
        "owner_uid": job.get("owner_uid") or "",
        "created_at": job["created_at"],
        "updated_at": job["updated_at"],
    }


def _role(user: dict) -> str | None:
    """Caller's active IAM role; 403 for disabled / role-less accounts.
    Only called with IAM on."""
    from server import iam as _iam
    if _iam.is_disabled(user):
        raise HTTPException(status_code=403, detail="account is disabled")
    role = _iam.get_role(user)
    if role is None:
        raise HTTPException(status_code=403, detail="no role on this server: ask an admin")
    return role


def _require_uploader(user: dict) -> str | None:
    """Upload needs role user or admin when IAM is on; viewers 403.
    Returns the caller's role (None with IAM off)."""
    if not config.iam_enabled():
        return None
    role = _role(user)
    if role not in ("admin", "user"):
        raise HTTPException(
            status_code=403,
            detail="Your account can only listen — uploading needs a user role; "
                   "ask your server admin.",
        )
    return role


def _audit_admin_job(user: dict, action: str, job: dict) -> None:
    """Audit an admin acting on somebody else's job (IAM on only). Called
    after the action succeeded; audit failures are logged, never raised."""
    if not config.iam_enabled():
        return
    from server import iam as _iam
    if (job.get("owner_uid") or "") != user["uid"] and _iam.get_role(user) == "admin":
        _iam.safe_audit(user["uid"], action, job["job_id"],
                        f"book={job['book_id']} owner={job.get('owner_uid') or ''}")


def _book_id_taken(book_id: str, cast: bool) -> bool:
    """True when `book_id` is already used by a package dir OR any job row
    (queued/running jobs have no package dir yet), and for cast uploads when
    its cast slug is already claimed by another job."""
    if os.path.isdir(os.path.join(config.OUTPUT_DIR, book_id)):
        return True
    if jobs.latest_job_for_book(book_id) is not None:
        return True
    if cast:
        from server import cast_bridge
        slug = cast_bridge.normalize_slug(book_id)
        if any(cast_bridge.normalize_slug(j["book_id"]) == slug for j in jobs.list_jobs()):
            return True
    return False


def _job_visible(job: dict, user: dict) -> bool:
    """IAM on: admins see everything; others only jobs they own. Rows from
    before IAM (empty owner_uid) are admin-only: their owner is unknown, so
    no ordinary account may be assumed to be entitled to them."""
    if not config.iam_enabled():
        return True
    from server import iam as _iam
    if _iam.get_role(user) == "admin":
        return True
    owner = (job.get("owner_uid") or "")
    return bool(owner) and owner == user["uid"]


def _require_job_access(job: dict, user: dict, mutate: bool = False) -> None:
    """Owner-or-admin for a single job row when IAM is on (404 hides other
    users' jobs instead of confirming they exist). `mutate` (retry, resume,
    convert-now) additionally needs the user or admin role: viewers listen."""
    if not config.iam_enabled():
        return
    role = _role(user)
    if not _job_visible(job, user):
        raise HTTPException(status_code=404, detail="job not found")
    if mutate and role not in ("admin", "user"):
        raise HTTPException(status_code=403, detail="Your account can only listen.")


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
    role = _require_uploader(_user)
    if content_mode not in ("illustrated", "novel", "cast"):
        raise HTTPException(status_code=422, detail="content_mode must be illustrated, novel or cast")
    if content_mode == "cast" and not config.cast_available():
        raise HTTPException(status_code=400, detail="Expressive voices are not enabled on this server")
    if (content_mode == "novel" and (research_characters or character_traits.strip())
            and not config.CONVERTER_SUPPORTS_CHARACTER_TRAITS):
        raise HTTPException(status_code=501, detail=(
            "This server's conversion engine has not been upgraded for character research or traits. "
            "Turn off research and custom traits, or update the server converter."))
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
    is_ebook_upload = ebook_mod.is_ebook(lname)
    if not file.filename or (not is_pdf and not is_zip and not is_ebook_upload):
        raise HTTPException(status_code=400, detail="only .pdf, .zip (of PDFs), .epub, .mobi, .azw or .azw3 uploads are accepted")
    if content_mode == "cast" and is_zip:
        raise HTTPException(status_code=400, detail="cast mode needs an ebook (.epub/.mobi/.azw/.azw3) or a text-based PDF, not a zip")
    if is_ebook_upload and not config.CONVERTER_SUPPORTS_EBOOKS:
        raise HTTPException(status_code=501, detail=(
            "This server's conversion engine has not been upgraded for ebooks. "
            "Upload a PDF or ZIP of PDFs, or update the server converter."))

    os.makedirs(config.UPLOAD_DIR, exist_ok=True)
    book_id = sanitize_book_id(file.filename)
    cast = content_mode == "cast"
    if cast:
        # Normalise BEFORE the uniqueness check: my_book and my-book map to
        # the same cast slug (inbox entry, state, cancel flag) and must not
        # be treated as two different books.
        from server import cast_bridge
        book_id = cast_bridge.normalize_slug(book_id)
    # Disambiguate a repeat filename so re-uploading the same book creates a
    # fresh conversion rather than colliding with (or silently overwriting)
    # a previous run's package directory. Queued/running jobs count too (they
    # have no package dir yet), so two users uploading the same filename get
    # distinct ids.
    if _book_id_taken(book_id, cast):
        n = 2
        while _book_id_taken(f"{book_id}-{n}", cast):
            n += 1
        book_id = f"{book_id}-{n}"

    # Ebooks keep their own extension: convert.py picks the text reader from it.
    dest_ext = os.path.splitext(lname)[1] if is_ebook_upload else ".pdf"
    # Stored under a fresh job id, never the (user-controlled, repeatable)
    # book id: uploads can never overwrite or share a file.
    job_id = uuid.uuid4().hex[:16]
    dest_path = os.path.join(config.UPLOAD_DIR, f"{job_id}{dest_ext}")
    size = 0
    max_mb = config.MAX_UPLOAD_MB
    if config.iam_enabled():  # admin-controlled limit (server_settings.json)
        try:
            from server import server_settings as _ss
            max_mb = _ss.read_server_settings()["limits"]["max_upload_mb"]
        except Exception:
            pass
    max_bytes = max_mb * 1024 * 1024
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
                        raise HTTPException(status_code=413, detail=f"file exceeds {max_mb} MB limit")
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
                    raise HTTPException(status_code=413, detail=f"file exceeds {max_mb} MB limit")
                out.write(chunk)

    if is_ebook_upload:
        # Fail now, with a readable reason (DRM, damaged file), instead of
        # queueing a job that can only fail later.
        try:
            ebook_mod.read_ebook(dest_path)
        except ebook_mod.EbookError as e:
            os.remove(dest_path)
            raise HTTPException(status_code=400, detail=str(e))

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
    if eff_model and config.iam_enabled() and role != "admin":
        # Plain users may only pick from the server's model catalog; free
        # text model ids are an admin privilege (they select what the
        # server's API key is spent on).
        from server.routes.settings import _cloud_models
        if eff_model not in _cloud_models()[2]:
            raise HTTPException(status_code=422, detail="model is not in this server's model list")
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
                             character_traits="\n".join(traits_lines) if content_mode == "novel" else "",
                             owner_uid=_user["uid"] if config.iam_enabled() else "",
                             job_id=job_id)
    job_runner.enqueue(job_id)
    return _job_view(jobs.get_job(job_id))


@router.get("/jobs")
def list_jobs(_user: dict = Depends(auth.require_user)):
    if config.iam_enabled():
        _role(_user)
    return [_job_view(j) for j in jobs.list_jobs() if _job_visible(j, _user)]


@router.get("/jobs/{job_id}")
def get_job(job_id: str, _user: dict = Depends(auth.require_user)):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    _require_job_access(job, _user)
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
    _require_job_access(job, _user, mutate=True)
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
    _audit_admin_job(_user, "job.retry", job)
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
    _require_job_access(job, _user, mutate=True)
    if job["state"] not in ("queued", "running"):
        raise HTTPException(status_code=409, detail=f"job is {job['state']}, nothing to resume")
    if not os.path.isfile(job["pdf_path"]):
        raise HTTPException(status_code=410, detail="original upload no longer on disk, cannot resume")

    pkg_dir = os.path.join(config.OUTPUT_DIR, job["book_id"])
    status = read_status(pkg_dir) or {}
    extra_args = job_runner.skip_extraction_arg_for_stage(status.get("stage"))

    jobs.set_state(job_id, "queued")
    job_runner.enqueue(job_id, extra_args)
    _audit_admin_job(_user, "job.resume", job)
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
    _require_job_access(job, _user, mutate=True)
    if job["state"] != "queued":
        raise HTTPException(status_code=409, detail=f"job is {job['state']}, only queued jobs can jump the queue")
    if not os.path.isfile(job["pdf_path"]):
        raise HTTPException(status_code=410, detail="original upload no longer on disk, cannot convert")
    job_runner.promote_now(job_id)
    _audit_admin_job(_user, "job.convert_now", job)
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
    _require_job_access(job, _user)
    if (job.get("content_mode") or "") == "cast" and job["state"] in ("queued", "running"):
        try:
            from server import cast_bridge
            cast_bridge.request_cancel(job["book_id"])
        except Exception:
            pass
    if job["state"] == "running":
        jobs.request_cancel(job_id)
        job_runner.cancel_running(job_id)
        _audit_admin_job(_user, "job.delete", job)
        return _job_view(jobs.get_job(job_id))
    jobs.request_cancel(job_id)  # no-op unless queued; marks skip-flag
    # A cast job deleted before the scheduler picked it up must not convert
    # later: drop its inbox entry while it can still be queued.
    if (job.get("content_mode") or "") == "cast":
        try:
            from server import cast_bridge
            cast_bridge.remove_inbox_entry(job["book_id"])
        except Exception:
            pass
    deleted = jobs.delete_job(job_id)
    assert deleted is not None  # fetched above; no concurrent deleter exists
    removed_files = _remove_job_files(deleted) if remove_files else False
    _audit_admin_job(_user, "job.delete", job)
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
    _require_job_access(job, _user)
    tail_lines = max(1, min(2000, tail_lines))  # <=0 would return the whole log
    log_path = os.path.join(config.OUTPUT_DIR, job["book_id"], "convert_stdout.log")
    if not os.path.isfile(log_path):
        return JSONResponse(content={"lines": []})
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    return JSONResponse(content={"lines": [ln.rstrip("\n") for ln in lines[-tail_lines:]]})

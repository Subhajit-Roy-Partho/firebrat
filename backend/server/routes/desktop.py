"""Private launcher bridge into the shared job queue; disabled by default.

A random per-launch token is supplied only to the desktop manager and its API
child. Loopback alone is insufficient: reverse proxies also connect locally.
"""
import os
from pathlib import Path
import secrets
from typing import Literal
import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from server import config, jobs, job_runner
from server.routes.jobs import _job_view

router = APIRouter()


def require_desktop(request: Request):
    token = os.environ.get("FIREBRAT_DESKTOP_TOKEN", "")
    if not token:
        raise HTTPException(404, "Desktop management is disabled")
    supplied = request.headers.get("X-Firebrat-Desktop-Token", "")
    if not request.client or request.client.host not in {"127.0.0.1", "::1"} or not secrets.compare_digest(token, supplied):
        raise HTTPException(403, "Desktop launcher authorization required")


class DesktopBook(BaseModel):
    path: str
    title: str = Field(min_length=1, max_length=180)
    content_mode: Literal["illustrated", "novel"] = "illustrated"
    provider: Literal["local", "nanogpt"] = "local"


@router.post("/desktop/jobs", dependencies=[Depends(require_desktop)])
def enqueue_book(book: DesktopBook):
    path = Path(book.path).resolve()
    uploads = Path(config.UPLOAD_DIR).resolve()
    if not path.is_relative_to(uploads) or path.suffix.lower() != ".pdf" or not path.is_file():
        raise HTTPException(400, "Choose a PDF from the launcher's upload folder")
    with path.open("rb") as file:
        if b"%PDF-" not in file.read(1024):
            raise HTTPException(400, "This file is not a PDF")
    job_id = jobs.create_job(book_id="desktop-" + uuid.uuid4().hex, filename=path.name,
                             title=book.title, pdf_path=str(path), provider=book.provider,
                             chunk_pages=2, content_mode=book.content_mode)
    job_runner.enqueue(job_id)
    return _job_view(jobs.get_job(job_id))


@router.get("/desktop/jobs/{job_id}", dependencies=[Depends(require_desktop)])
def get_job(job_id: str):
    job = jobs.get_job(job_id)
    if job is None:
        raise HTTPException(404, "Job not found")
    return _job_view(job)

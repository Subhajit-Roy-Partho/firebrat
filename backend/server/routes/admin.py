"""Server administration (IAM): first-run bootstrap, users, settings, queue.

All endpoints 404 unless FIREBRAT_IAM=1, 401 without a signed-in user, and
403 unless the caller is an active admin. Every mutation is audit-logged
(see server/iam.py). Additive: untouched when IAM is off.
"""

import os
import re

from fastapi import APIRouter, Depends, HTTPException, Query

from server import auth, config
from server import iam as _iam

router = APIRouter(prefix="/admin")


_require_admin_role = auth.require_role("admin")


def _admin(user: dict = Depends(auth.require_user)) -> dict:
    """404 when IAM is off, 401 signed out, 403 unless an active admin."""
    if not config.iam_enabled():
        raise HTTPException(status_code=404, detail="server administration is disabled")
    return _require_admin_role(user)


def _user_view(row: dict) -> dict:
    return {k: row.get(k) for k in (
        "uid", "email", "name", "role", "status",
        "created_at", "invited_by", "last_seen")}


@router.post("/bootstrap")
def bootstrap(body: dict | None = None, user: dict = Depends(auth.require_user)):
    """First-admin setup. 410 once an admin exists. Accepts the one-time
    setup code, or (no code) a verified FIREBRAT_ADMIN_EMAILS email.
    Wrong codes 403; 5 wrong tries start a 10-minute lockout (429)."""
    if not config.iam_enabled():
        raise HTTPException(status_code=404, detail="server administration is disabled")
    if not _iam.needs_setup():
        raise HTTPException(status_code=410, detail="server already has an admin")
    body = body if isinstance(body, dict) else {}
    row = _iam.try_email_bootstrap(user)
    if row is not None:
        return _user_view(row)
    code = body.get("code")
    if not isinstance(code, str) or not code.strip() or len(code) > 64:
        raise HTTPException(status_code=422, detail="code must be the setup code string")
    ok, reason = _iam.verify_bootstrap(code, user["uid"])
    if reason == "locked":
        # Never put the submitted code in the audit detail.
        _iam.safe_audit(user["uid"], "bootstrap.locked", user["uid"], "too many wrong codes")
        raise HTTPException(status_code=429, detail="too many wrong codes, try again in 10 minutes")
    if not ok:
        _iam.safe_audit(user["uid"], "bootstrap.failed", user["uid"], "wrong setup code")
        raise HTTPException(status_code=403, detail="invalid setup code")
    try:
        return _user_view(_iam.bootstrap_admin(user))
    except PermissionError:
        raise HTTPException(status_code=410, detail="server already has an admin")


@router.get("/users")
def list_users(_user: dict = Depends(_admin)):
    return {"users": [_user_view(u) for u in _iam.list_users()],
            "invites": _iam.list_invites()}


@router.post("/users")
def invite_user(body: dict, user: dict = Depends(_admin)):
    """Pre-authorize email + role; the invite is claimed on first sign-in."""
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="body must be an object")
    try:
        inv = _iam.create_invite(str(body.get("email") or ""),
                                 str(body.get("role") or ""), user["uid"])
    except ValueError as e:
        msg = str(e)
        raise HTTPException(status_code=409 if msg.startswith("already") else 422, detail=msg)
    return inv


@router.patch("/users/{key}")
def update_user(key: str, body: dict, user: dict = Depends(_admin)):
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="body must be an object")
    role = body.get("role")
    status = body.get("status")
    if role is None and status is None:
        raise HTTPException(status_code=422, detail="nothing to change (role?, status?)")
    if _iam.find_for_admin(key) is None and _iam.find_invite(key) is not None:
        if role is None or status is not None:
            raise HTTPException(status_code=422, detail="a pending invite only has a role")
        try:
            return _iam.update_invite(user["uid"], key, str(role))
        except ValueError as e:
            raise HTTPException(status_code=422, detail=str(e))
    try:
        return _user_view(_iam.update_user(user["uid"], key,
                                           role=str(role) if role is not None else None,
                                           status=str(status) if status is not None else None))
    except KeyError:
        raise HTTPException(status_code=404, detail="user not found")
    except ValueError as e:
        msg = str(e)
        raise HTTPException(status_code=409 if msg.startswith("cannot ") else 422, detail=msg)


@router.delete("/users/{key}")
def remove_user(key: str, user: dict = Depends(_admin)):
    # Self-delete is allowed when another active admin remains; iam's
    # last-admin guard rejects it otherwise.
    if _iam.find_for_admin(key) is None and _iam.find_invite(key) is not None:
        inv = _iam.delete_invite(user["uid"], key)
        return {"deleted": inv["email"]}
    try:
        deleted = _iam.delete_user(user["uid"], key)
    except KeyError:
        raise HTTPException(status_code=404, detail="user not found")
    except ValueError as e:
        raise HTTPException(status_code=409, detail=str(e))
    return {"deleted": deleted["uid"]}


@router.get("/audit")
def read_audit(limit: int = Query(100, ge=1, le=500), _user: dict = Depends(_admin)):
    return {"audit": _iam.list_audit(limit)}


@router.get("/settings")
def read_settings(_user: dict = Depends(_admin)):
    from server import server_settings as _ss
    return _ss.settings_view()


@router.put("/settings")
def write_settings(body: dict, user: dict = Depends(_admin)):
    from server import server_settings as _ss
    if not isinstance(body, dict):
        raise HTTPException(status_code=422, detail="body must be an object")
    values = body.get("values", body)
    try:
        return {"values": _ss.write_server_settings(values, actor_uid=user["uid"])}
    except ValueError as e:
        raise HTTPException(status_code=422, detail=str(e))


def _scheduler_snapshot() -> dict:
    """Scheduler status + per-book stages. Tolerates a missing scheduler
    (never installed / never started): reports unavailable, never 500s."""
    from server import cast_bridge
    snap: dict = {"available": False, "running": False,
                  "detail": "cast scheduler not running", "books": []}
    try:
        root = cast_bridge.cast_root()
    except Exception:
        return snap
    try:
        seen: dict[str, dict] = {}
        inbox = os.path.join(root, "inbox")
        jobs_dir = os.path.join(root, "jobs")
        slugs: set[str] = set()
        try:
            slugs.update(f[:-5] for f in os.listdir(inbox) if f.endswith(".json"))
        except OSError:
            pass
        try:
            slugs.update(d for d in os.listdir(jobs_dir)
                         if os.path.isdir(os.path.join(jobs_dir, d)))
        except OSError:
            pass
        for slug in sorted(slugs):
            try:
                seen[slug] = cast_bridge.cast_job_view(slug, root)
            except Exception:
                continue
        status_file = cast_bridge.read_cast_state("__none__", root)["scheduler_status"]
        sup = getattr(cast_bridge, "_supervisor", None)
        running = bool(sup is not None and sup.running)
        snap = {"available": True, "running": running,
                "detail": status_file.get("detail") or ("running" if running else "idle"),
                "status": status_file,
                "books": [{"slug": s, **v} for s, v in seen.items()]}
    except Exception:
        pass
    return snap


def _job_for_slug(slug: str) -> dict | None:
    """Latest server job backing a cast slug (book_id matches, or
    normalizes to the slug)."""
    from server import cast_bridge, jobs as _jobs
    try:
        rows = _jobs.list_jobs()
    except Exception:
        return None
    for job in rows:
        try:
            if job["book_id"] == slug or cast_bridge.normalize_slug(job["book_id"]) == slug:
                return job
        except Exception:
            continue
    return None


@router.get("/queue")
def read_queue(_user: dict = Depends(_admin)):
    from server import server_settings as _ss
    return {"scheduler": _scheduler_snapshot(),
            "paused": bool(_ss.read_server_settings()["run_pattern"]["paused"])}


@router.post("/queue/pause")
def pause_queue(user: dict = Depends(_admin)):
    from server import server_settings as _ss
    values = _ss.read_server_settings()
    values["run_pattern"]["paused"] = True
    _ss.write_server_settings(values, actor_uid=user["uid"])
    return {"paused": True}


@router.post("/queue/resume")
def resume_queue(user: dict = Depends(_admin)):
    from server import server_settings as _ss
    values = _ss.read_server_settings()
    values["run_pattern"]["paused"] = False
    _ss.write_server_settings(values, actor_uid=user["uid"])
    return {"paused": False}


_SLUG_CHARS_RE = re.compile(r"^[A-Za-z0-9_-]{1,100}$")


def _slug_or_422(slug: str) -> str:
    """Validate a slug taken from the URL and return its canonical
    (normalized) form. Anything with characters outside [A-Za-z0-9_-]
    (".." included) is rejected before it can reach a filesystem path;
    the returned slug always matches ^[a-z0-9][a-z0-9-]{2,99}$."""
    from server import cast_bridge
    if not _SLUG_CHARS_RE.match(slug or ""):
        raise HTTPException(status_code=404, detail="unknown book slug")
    out = cast_bridge.normalize_slug(slug)
    if not cast_bridge.SLUG_RE.match(out):
        raise HTTPException(status_code=404, detail="unknown book slug")
    return out


@router.post("/queue/{slug}/cancel")
def cancel_book(slug: str, user: dict = Depends(_admin)):
    """Cancel a queued/running book: flag its server job (if any), drop its
    still-queued scheduler inbox entry and raise the scheduler's cancel flag
    (honoured between stages). 404 when nothing is known about the slug."""
    from server import cast_bridge, jobs as _jobs
    slug = _slug_or_422(slug)
    job = _job_for_slug(slug)
    known = job is not None or bool(cast_bridge.read_cast_state(slug)["state"]) \
        or os.path.isfile(cast_bridge.inbox_path(cast_bridge.normalize_slug(slug)))
    if not known:
        raise HTTPException(status_code=404, detail="unknown book slug")
    removed_inbox = bool(cast_bridge.remove_inbox_entry(slug))
    cast_bridge.request_cancel(slug)
    cancelled_job = None
    if job is not None and job.get("state") in ("queued", "running"):
        _jobs.request_cancel(job["job_id"])
        cancelled_job = job["job_id"]
    _iam.safe_audit(user["uid"], "queue_cancel", slug,
               f"job={cancelled_job} inbox_removed={removed_inbox}")
    return {"slug": slug, "cancelled_job": cancelled_job,
            "removed_inbox": removed_inbox}


@router.post("/queue/{slug}/priority")
def prioritize_book(slug: str, body: dict, user: dict = Depends(_admin)):
    """Move a book to the front. Body must be {"top": true}. Cast books go
    to the front of the scheduler's priority file (next LLM/audio pick);
    ordinary queued conversions jump the worker queue (running ones pause
    and resume from checkpoint)."""
    from server import cast_bridge, job_runner as _runner, jobs as _jobs
    from server.routes.jobs import _job_view
    if not isinstance(body, dict) or body.get("top") is not True:
        raise HTTPException(status_code=422, detail='body must be {"top": true}')
    slug = _slug_or_422(slug)
    job = _job_for_slug(slug)
    if job is None:
        raise HTTPException(status_code=404, detail="unknown book slug")
    if job.get("state") not in ("queued", "running") or (
            job.get("content_mode") != "cast" and job.get("state") != "queued"):
        raise HTTPException(status_code=409,
                            detail=f"job is {job.get('state')}, only queued jobs jump the queue")
    paused: list = []
    if job.get("content_mode") == "cast":
        cast_bridge.set_priority_top(slug)
    else:
        paused = _runner.promote_now(job["job_id"])
    _iam.safe_audit(user["uid"], "queue_priority", slug, f"job={job['job_id']}")
    return {**_job_view(_jobs.get_job(job["job_id"])), "paused_jobs": paused}

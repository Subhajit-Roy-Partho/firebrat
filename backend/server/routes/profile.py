"""Signed-in user's profile: the avatar shown in the app's drawer.

Avatars are private to their owner, so every endpoint requires a valid
Firebase user. Files are stored under config.AVATAR_DIR named by the SHA-256
of the uid (never the uid itself), so no user-supplied string ever reaches
the filesystem path. One avatar per user; uploading replaces it.
"""
import hashlib
import logging
import os
import tempfile

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from fastapi.responses import FileResponse, Response

from server import config
from server.auth import require_role, require_user

log = logging.getLogger("firebrat.server.profile")
router = APIRouter()

# With IAM on, avatar storage needs an active account with a role (disabled or
# role-less Google accounts must not get free storage); identical to
# require_user when IAM is off.
_active_role = require_role("admin", "user", "viewer")

_EXTS = (".png", ".jpg", ".webp")
_MEDIA = {".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp"}


def _sniff(data: bytes) -> str | None:
    """Image extension from magic bytes — never trust the client's
    filename or Content-Type."""
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    return None


def _stem(uid: str) -> str:
    return hashlib.sha256(uid.encode("utf-8")).hexdigest()


def _find(uid: str) -> str | None:
    base = os.path.join(config.AVATAR_DIR, _stem(uid))
    for ext in _EXTS:
        if os.path.isfile(base + ext):
            return base + ext
    return None


@router.get("/me")
def me(user: dict = Depends(require_user)):
    path = _find(user["uid"])
    base = {
        "uid": user["uid"],
        "email": user.get("email"),
        "name": user.get("name") or "",
        "role": None,
        "has_avatar": path is not None,
        "avatar_updated_at": int(os.path.getmtime(path)) if path else None,
    }
    if not config.iam_enabled():
        return {**base, "iam_enabled": False, "needs_setup": False}
    # First sign-in with a verified invited email links the uid and
    # activates the user; existing users just get last_seen refreshed.
    from server import iam as _iam
    _iam.claim_invite(user)
    _iam.try_email_bootstrap(user)  # FIREBRAT_ADMIN_EMAILS, verified emails only
    needs = _iam.needs_setup()
    if needs:
        _iam.ensure_setup_code()
    row = _iam.get_user(user["uid"]) or {}
    return {
        **base,
        "name": user.get("name") or row.get("name") or "",
        "role": _iam.get_role(user),
        "status": row.get("status"),
        "iam_enabled": True,
        "needs_setup": needs,
    }


@router.put("/me/avatar")
async def put_avatar(file: UploadFile, user: dict = Depends(_active_role)):
    limit = config.MAX_AVATAR_KB * 1024
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise HTTPException(status_code=413, detail=f"avatar larger than {config.MAX_AVATAR_KB} KB")
    ext = _sniff(data)
    if ext is None:
        raise HTTPException(status_code=400, detail="avatar must be a PNG, JPEG or WebP image")
    os.makedirs(config.AVATAR_DIR, exist_ok=True)
    base = os.path.join(config.AVATAR_DIR, _stem(user["uid"]))
    fd, tmp = tempfile.mkstemp(dir=config.AVATAR_DIR, suffix=".part")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        for old in _EXTS:  # a replacement may change format
            if old != ext and os.path.isfile(base + old):
                os.remove(base + old)
        os.replace(tmp, base + ext)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return {"has_avatar": True, "bytes": len(data)}


@router.get("/me/avatar")
def get_avatar(user: dict = Depends(_active_role)):
    path = _find(user["uid"])
    if path is None:
        raise HTTPException(status_code=404, detail="no avatar set")
    return FileResponse(path, media_type=_MEDIA[os.path.splitext(path)[1]],
                        headers={"Cache-Control": "private, no-cache"})


@router.delete("/me/avatar", status_code=204)
def delete_avatar(user: dict = Depends(_active_role)):
    path = _find(user["uid"])
    if path is not None:
        os.remove(path)
    return Response(status_code=204)

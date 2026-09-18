"""Firebase Authentication + Cloud Messaging for the Firebrat server.

Auth model (v1, deliberately simple for a wider audience):
- READS stay open: /books, /manifest, /assets, /download, /checksum,
  /health. Anyone with the server URL can read and download the shelf.
- MUTATIONS require a valid Firebase ID token: upload, job retry/resume/
  listing, book delete. The Flutter app attaches the token automatically
  (ApiClient interceptor) after Google sign-in.
- Any signed-in user may mutate (no per-user libraries yet — job rows
  carry no owner; see the note on `require_user`). Reader clients never
  needed accounts at all, and still don't for reading.

FCM: the app subscribes to topic `job-<job_id>` while tracking an upload
and to `new-books` for shelf broadcasts; this module publishes to those
topics. Sending needs a service-account key
(GOOGLE_APPLICATION_CREDENTIALS=/path/key.json); without it, publish
calls log and no-op so the server runs fine keyless (all reads + polled
job status keep working, and the app raises its own local notification
from the status it already polls).
"""
import logging
import os

from fastapi import Header, HTTPException

log = logging.getLogger("firebrat.auth")

_firebase_inited = False


def _ensure_init() -> bool:
    """Initialize firebase_admin for ID-token verification.

    Verification uses Google's public certs and works with NO credentials
    file. Returns False only if the package itself isn't installed.
    """
    global _firebase_inited
    if _firebase_inited:
        return True
    try:
        import firebase_admin
        from firebase_admin import credentials
    except ImportError:
        log.warning("firebase_admin not installed — auth endpoints will 503");
        return False
    try:
        if not firebase_admin._apps:
            # No explicit credential: fine for verify_id_token (public
            # certs); FCM *sending* additionally needs
            # GOOGLE_APPLICATION_CREDENTIALS, handled in notify_* below.
            firebase_admin.initialize_app()
        _firebase_inited = True
        return True
    except Exception:
        log.exception("firebase_admin init failed")
        return False


def get_current_user(authorization: str | None = None) -> dict | None:
    """Verify `Authorization: Bearer <ID token>`; None if absent/invalid.

    Never raises — callers decide whether anonymous is acceptable.
    Returned dict has at least uid, and email when the provider supplies it.
    """
    if not authorization or not authorization.startswith("Bearer "):
        return None
    token = authorization[len("Bearer "):].strip()
    if not token or not _ensure_init():
        return None
    try:
        from firebase_admin import auth as fb_auth
        decoded = fb_auth.verify_id_token(token)
        return {"uid": decoded.get("uid"), "email": decoded.get("email")}
    except Exception:
        return None


def require_user(authorization: str | None = Header(default=None)) -> dict:
    """FastAPI dependency: 401 unless a valid Firebase user is present."""
    user = get_current_user(authorization)
    if user is None or not user.get("uid"):
        raise HTTPException(status_code=401, detail="sign-in required")
    return user


def _messaging():
    """firebase.messaging, or None (no creds / not installed). Sending —
    unlike verification — needs a service-account key, so this is None on
    a keyless server and every notify_* call below becomes a log line."""
    if not _ensure_init():
        return None
    try:
        from firebase_admin import messaging
        # Touch credentials: raises here (not at send time) when running
        # keyless, so callers get a clean None instead of a late 500.
        import firebase_admin
        app = firebase_admin.get_app()
        if app.credential is None:
            return None
        # ADC without a service account (e.g. no GOOGLE_APPLICATION_CREDENTIALS
        # and no GCE metadata) can't mint push tokens — probe cheaply.
        cred = app.credential
        get_token = getattr(cred, "get_access_token", None)
        if get_token is None:
            return None
        return messaging
    except Exception:
        return None


def notify_topic(topic: str, title: str, body: str) -> bool:
    """Publish a data+notification message to an FCM topic. Returns False
    (and logs) when the server has no push credentials — never raises."""
    messaging = _messaging()
    if messaging is None:
        log.info("FCM keyless, skipping push to %s: %s", topic, title)
        return False
    try:
        messaging.send(messaging.Message(
            topic=topic,
            notification=messaging.Notification(title=title, body=body),
            data={"title": title, "body": body},
        ))
        return True
    except Exception:
        log.exception("FCM publish to %s failed", topic)
        return False


def job_topic(job_id: str) -> str:
    return f"job-{job_id}"

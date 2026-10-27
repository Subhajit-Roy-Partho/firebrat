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

from fastapi import Depends, Header, HTTPException

log = logging.getLogger("firebrat.auth")

_firebase_inited = False


def _verify_keyless_token(token: str, project: str) -> dict:
    """Verify public signing keys without loading Admin SDK credentials.

    google-auth checks signature, audience, expiry and issued-at. Firebase's
    issuer, subject and authentication-time requirements are checked here.
    """
    import time
    from google.auth.transport.requests import Request
    from google.oauth2 import id_token
    decoded = id_token.verify_firebase_token(token, Request(), audience=project)
    subject = decoded.get("sub")
    auth_time = decoded.get("auth_time")
    if (decoded.get("iss") != f"https://securetoken.google.com/{project}"
            or not isinstance(subject, str) or not 1 <= len(subject) <= 128
            or not isinstance(auth_time, (int, float)) or isinstance(auth_time, bool)
            or auth_time > time.time()):
        raise ValueError("invalid Firebase claims")
    return {**decoded, "uid": subject}


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
        project = os.environ.get("GOOGLE_CLOUD_PROJECT") or os.environ.get("FIREBASE_PROJECT_ID")
        if project and not os.environ.get("GOOGLE_APPLICATION_CREDENTIALS"):
            decoded = _verify_keyless_token(token, project)
        else:
            from firebase_admin import auth as fb_auth
            decoded = fb_auth.verify_id_token(token)
        user = {"uid": decoded.get("uid"), "email": decoded.get("email")}
        # Passed through for IAM matching (iam.py only trusts email when
        # email_verified is truthy) and the /me display name. Absent in
        # older tokens — callers must treat both as optional.
        for key in ("email_verified", "name"):
            if decoded.get(key) is not None:
                user[key] = decoded.get(key)
        return user
    except Exception:
        return None


def require_user(authorization: str | None = Header(default=None)) -> dict:
    """FastAPI dependency: 401 unless a valid Firebase user is present."""
    user = get_current_user(authorization)
    if user is None or not user.get("uid"):
        raise HTTPException(status_code=401, detail="sign-in required")
    # Optional deployment boundary for a private/reviewer server. An empty
    # allowlist preserves the shared-server behaviour used by existing installs.
    # With FIREBRAT_IAM=1 roles replace the allowlist (legacy uids become
    # admins, see iam.materialize_legacy_admins), so it is not enforced twice.
    if os.environ.get("FIREBRAT_IAM", "").strip() != "1":
        allowed = {uid.strip() for uid in os.environ.get(
            "FIREBRAT_ALLOWED_USER_IDS", "").split(",") if uid.strip()}
        if allowed and user["uid"] not in allowed:
            raise HTTPException(status_code=403, detail="account not authorized for this server")
    return user


def require_role(*roles: str):
    """Dependency factory: signed in AND (when FIREBRAT_IAM=1) an active
    account whose role is one of `roles`. With IAM off it behaves exactly
    like require_user (fully backward compatible).

    Tests override `require_user` via app.dependency_overrides; this
    dependency calls it through Depends so such overrides still apply.
    """
    allowed = set(roles)

    def _dep(user: dict = Depends(require_user)) -> dict:
        if os.environ.get("FIREBRAT_IAM", "").strip() != "1":
            return user
        from server import iam
        if iam.is_disabled(user):
            raise HTTPException(status_code=403, detail="account is disabled")
        role = iam.get_role(user)
        if role is None:
            raise HTTPException(status_code=403, detail="no role on this server: ask an admin")
        if allowed and role not in allowed:
            raise HTTPException(status_code=403, detail="insufficient role")
        return user

    return _dep


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
        # ApplicationDefault resolves lazily. Merely inspecting the wrapper
        # doesn't prove credentials exist; force resolution before publishing.
        cred.get_credential()
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

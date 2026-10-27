"""Accounts and roles (IAM) for the Firebrat server.

Additive and OFF by default: nothing here matters unless FIREBRAT_IAM=1
(see server.config.iam_enabled). When off, every helper below degrades to
"no opinion" (None / False) and the routes keep their existing shared-server
behaviour.

When on, identity is still Firebase Auth (verified ID tokens, with
`email_verified` required whenever an email is used for matching) and this
module adds the role layer on top, stored in sqlite next to the jobs DB:

- users(uid PK, email, name, role, status, created_at, invited_by, last_seen)
- invites(email PK, role, invited_by, created_at, claimed_uid)
- audit(id, at, actor_uid, action, target, detail)
- bootstrap(single row: one-time setup-code hash + rate-limit state)

Roles: admin (everything), user (upload incl. cast mode, own jobs, own
delete), viewer (listen only, no uploads). Not signed in = public read, as
today. Connections are opened per call (same pattern as server/jobs.py) so
server.config.JOBS_DB_PATH can be monkeypatched in tests at any time.
"""

import hashlib
import hmac
import logging
import os
import re
import secrets
import sqlite3
import time

from server import config

log = logging.getLogger("firebrat.server.iam")

ROLES = ("admin", "user", "viewer")
STATUSES = ("active", "disabled")
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    uid TEXT PRIMARY KEY,
    email TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    role TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    invited_by TEXT NOT NULL DEFAULT '',
    last_seen TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS invites (
    email TEXT PRIMARY KEY,
    role TEXT NOT NULL,
    invited_by TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    claimed_uid TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS audit (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at TEXT NOT NULL,
    actor_uid TEXT NOT NULL DEFAULT '',
    action TEXT NOT NULL,
    target TEXT NOT NULL DEFAULT '',
    detail TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS bootstrap (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    code_hash TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT '',
    attempts INTEGER NOT NULL DEFAULT 0,
    locked_until REAL NOT NULL DEFAULT 0
);
"""

# Bootstrap brute-force guard: 5 wrong tries, then a 10-minute lockout.
_MAX_TRIES = 5
_LOCKOUT_S = 600.0
# 10-char setup code from an unambiguous alphabet (no 0/O/1/I).
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def iam_enabled() -> bool:
    """True only when the operator opted in via FIREBRAT_IAM=1."""
    return os.environ.get("FIREBRAT_IAM", "").strip() == "1"


def _db_path() -> str:
    return os.path.join(os.path.dirname(config.JOBS_DB_PATH), "iam.sqlite3")


def _setup_code_path() -> str:
    return os.path.join(os.path.dirname(config.JOBS_DB_PATH), "SETUP_CODE.txt")


def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(config.JOBS_DB_PATH), exist_ok=True)
    conn = sqlite3.connect(_db_path())
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    conn.commit()
    return conn


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _hash_code(code: str) -> str:
    return hashlib.sha256(code.encode("utf-8")).hexdigest()


def legacy_admin_uids() -> set[str]:
    """FIREBRAT_ALLOWED_USER_IDS entries, treated as admins while the IAM
    table is still empty (upgrade path for private servers)."""
    return {u.strip() for u in os.environ.get(
        "FIREBRAT_ALLOWED_USER_IDS", "").split(",") if u.strip()}


def admin_bootstrap_emails() -> set[str]:
    """FIREBRAT_ADMIN_EMAILS (comma list, lowercased): verified-email
    alternative to the one-time setup code for first-admin bootstrap."""
    return {e.strip().lower() for e in os.environ.get(
        "FIREBRAT_ADMIN_EMAILS", "").split(",") if e.strip()}


# ── user / invite reads ──────────────────────────────────────────

def _user_count(conn: sqlite3.Connection) -> int:
    return conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]


def active_admin_count() -> int:
    conn = _connect()
    try:
        return conn.execute(
            "SELECT COUNT(*) FROM users WHERE role = 'admin' AND status = 'active'"
        ).fetchone()[0]
    finally:
        conn.close()


def materialize_legacy_admins() -> int:
    """Upgrade path: while no admin row exists, turn each legacy
    FIREBRAT_ALLOWED_USER_IDS uid into a real admin row (so it shows in the
    user list, is covered by last-admin protection, and keeps its rights
    after other accounts are added). No-op once any admin exists or when
    the env var is empty. Returns the number of rows created."""
    legacy = legacy_admin_uids()
    if not legacy:
        return 0
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        has_admin = conn.execute(
            "SELECT COUNT(*) FROM users WHERE role = 'admin' AND status = 'active'"
        ).fetchone()[0]
        if has_admin:
            conn.rollback()
            return 0
        now = _now()
        n = 0
        for uid in sorted(legacy):
            if len(uid) > 128:
                continue
            cur = conn.execute(
                "INSERT INTO users (uid, email, name, role, status, created_at, "
                "invited_by, last_seen) VALUES (?, '', '', 'admin', 'active', ?, "
                "'legacy-allowlist', '') ON CONFLICT(uid) DO UPDATE SET "
                "role = 'admin', status = 'active'", (uid, now))
            n += cur.rowcount
            conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                         "VALUES (?, 'system', 'legacy_admin', ?, "
                         "'FIREBRAT_ALLOWED_USER_IDS')", (now, uid))
        conn.commit()
        return n
    finally:
        conn.close()


def needs_setup() -> bool:
    """True only when IAM is on and no active admin exists yet. Legacy
    FIREBRAT_ALLOWED_USER_IDS entries count as admins (they are
    materialised here), so such servers never ask for a setup code."""
    if not iam_enabled():
        return False
    if active_admin_count() == 0 and legacy_admin_uids():
        materialize_legacy_admins()
    return active_admin_count() == 0


def get_user(uid: str) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM users WHERE uid = ?", (uid,)).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None


def get_user_by_email(email: str) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute(
            "SELECT * FROM users WHERE lower(email) = lower(?)", (email,)).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None


def list_users() -> list[dict]:
    conn = _connect()
    try:
        rows = conn.execute("SELECT * FROM users ORDER BY created_at").fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def list_invites() -> list[dict]:
    conn = _connect()
    try:
        rows = conn.execute("SELECT * FROM invites ORDER BY created_at").fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def get_role(user: dict) -> str | None:
    """The caller's IAM role, or None (no role / disabled / IAM off).

    Legacy FIREBRAT_ALLOWED_USER_IDS entries are admins while no admin
    exists yet (they are materialised into real rows on first use).
    """
    if not iam_enabled() or not user or not user.get("uid"):
        return None
    row = get_user(user["uid"])
    if row is None and legacy_admin_uids() and active_admin_count() == 0:
        materialize_legacy_admins()
        row = get_user(user["uid"])
    if row is not None and row["status"] == "active":
        return row["role"] if row["role"] in ROLES else None
    return None


def is_disabled(user: dict) -> bool:
    """True when the caller has a user row whose status is not active."""
    if not iam_enabled() or not user or not user.get("uid"):
        return False
    row = get_user(user["uid"])
    return row is not None and row["status"] != "active"


def _verified_email(user: dict) -> str:
    """Lowercased email only when the provider verified it — unverified
    emails must never match invites or the admin allowlist."""
    email = (user.get("email") or "").strip().lower()
    if email and user.get("email_verified"):
        return email
    return ""


# ── first-run setup code ─────────────────────────────────────────

def ensure_setup_code() -> str | None:
    """Create the one-time 10-char setup code when needed; else None.

    Only when IAM is on and no admin exists yet. Stores only the hash;
    the code itself goes once to the server log and to <data>/SETUP_CODE.txt
    (mode 0600). Idempotent: a pending code is never regenerated or re-logged
    (unless its txt file went missing, in which case a fresh code replaces
    the unrecoverable one).
    """
    if not needs_setup():
        return None
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM bootstrap WHERE id = 1").fetchone()
        pending = row and row["code_hash"]
        if pending and os.path.isfile(_setup_code_path()):
            return None
        code = "".join(secrets.choice(_CODE_ALPHABET) for _ in range(10))
        conn.execute(
            "INSERT INTO bootstrap (id, code_hash, created_at, attempts, locked_until) "
            "VALUES (1, ?, ?, 0, 0) ON CONFLICT(id) DO UPDATE SET "
            "code_hash = excluded.code_hash, created_at = excluded.created_at, "
            "attempts = 0, locked_until = 0",
            (_hash_code(code), _now()),
        )
        conn.commit()
    finally:
        conn.close()
    path = _setup_code_path()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(code + "\n")
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    # The one secret this module ever logs, as specified: the first-run
    # setup code goes to the server log exactly once, at creation time.
    log.info("FIREBRAT_IAM setup code: %s (also in %s; deleted after use)",
             code, path)
    return code


def verify_bootstrap(code: str) -> tuple[bool, str]:
    """Check a setup-code guess. Returns (ok, reason) with reason one of
    "ok" | "invalid" | "locked". Constant-time compare; 5 wrong tries start
    a 10-minute lockout during which every guess reports "locked"."""
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM bootstrap WHERE id = 1").fetchone()
        now = time.time()
        if row is None or not row["code_hash"]:
            return False, "invalid"
        if row["locked_until"] and now < row["locked_until"]:
            return False, "locked"
        if row["locked_until"] and now >= row["locked_until"]:
            conn.execute("UPDATE bootstrap SET attempts = 0, locked_until = 0 WHERE id = 1")
            conn.commit()
            attempts = 0
        else:
            attempts = row["attempts"]
        guess = (code or "").strip().upper()[:64]
        if guess and hmac.compare_digest(_hash_code(guess), row["code_hash"]):
            return True, "ok"
        attempts += 1
        if attempts >= _MAX_TRIES:
            conn.execute("UPDATE bootstrap SET attempts = ?, locked_until = ? WHERE id = 1",
                         (attempts, now + _LOCKOUT_S))
            conn.commit()
            log.warning("IAM bootstrap locked after %d wrong tries", attempts)
            return False, "locked"
        conn.execute("UPDATE bootstrap SET attempts = ? WHERE id = 1", (attempts,))
        conn.commit()
        return False, "invalid"
    finally:
        conn.close()


def _consume_bootstrap(conn: sqlite3.Connection) -> None:
    conn.execute("UPDATE bootstrap SET code_hash = '', attempts = 0, "
                 "locked_until = 0 WHERE id = 1")
    try:
        if os.path.isfile(_setup_code_path()):
            os.remove(_setup_code_path())
    except OSError:
        log.warning("Could not remove SETUP_CODE.txt")


def try_email_bootstrap(user: dict) -> dict | None:
    """FIREBRAT_ADMIN_EMAILS bootstrap: when no admin exists and the caller's
    VERIFIED email is on the list, make them the first admin. Returns the
    user row, or None when it does not apply."""
    if not iam_enabled() or not needs_setup():
        return None
    email = _verified_email(user)
    if not email or email not in admin_bootstrap_emails():
        return None
    try:
        return bootstrap_admin(user, via="admin-email")
    except PermissionError:
        return None


def bootstrap_admin(user: dict, via: str = "setup-code") -> dict:
    """Make the caller the first admin (setup code or admin-email already
    verified by the caller). Atomic: raises PermissionError when an admin
    already exists (routes map that to 410). Clears the one-time code and
    audit-logs."""
    conn = _connect()
    try:
        conn.execute("BEGIN IMMEDIATE")
        if conn.execute("SELECT COUNT(*) FROM users WHERE role = 'admin' "
                        "AND status = 'active'").fetchone()[0]:
            conn.rollback()
            raise PermissionError("an admin already exists")
        now = _now()
        email = (user.get("email") or "").strip()[:254]
        name = (user.get("name") or "").strip()[:200]
        row = conn.execute("SELECT * FROM users WHERE uid = ?", (user["uid"],)).fetchone()
        if row:
            conn.execute("UPDATE users SET role = 'admin', status = 'active', "
                         "email = ?, name = ?, last_seen = ? WHERE uid = ?",
                         (email, name, now, user["uid"]))
        else:
            conn.execute(
                "INSERT INTO users (uid, email, name, role, status, created_at, "
                "invited_by, last_seen) VALUES (?, ?, ?, 'admin', 'active', ?, "
                "'bootstrap', ?)", (user["uid"], email, name, now, now))
        _consume_bootstrap(conn)
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'bootstrap', ?, ?)",
                     (now, user["uid"], user["uid"], via))
        conn.commit()
    finally:
        conn.close()
    return get_user(user["uid"])


# ── invites + admin user management ──────────────────────────────

def create_invite(email: str, role: str, invited_by: str) -> dict:
    """Pre-authorize email + role. Upserts the invite row and audit-logs."""
    if role not in ROLES:
        raise ValueError("role must be admin, user or viewer")
    email = (email or "").strip().lower()
    if not _EMAIL_RE.match(email) or len(email) > 254:
        raise ValueError("email must look like a mailbox")
    if get_user_by_email(email) is not None:
        raise ValueError("already a user: change their role instead")
    conn = _connect()
    try:
        now = _now()
        conn.execute(
            "INSERT INTO invites (email, role, invited_by, created_at, claimed_uid) "
            "VALUES (?, ?, ?, ?, '') ON CONFLICT(email) DO UPDATE SET "
            "role = excluded.role, invited_by = excluded.invited_by",
            (email, role, invited_by, now),
        )
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'invite', ?, ?)",
                     (now, invited_by, email, role))
        conn.commit()
        row = conn.execute("SELECT * FROM invites WHERE email = ?", (email,)).fetchone()
    finally:
        conn.close()
    return dict(row)


def claim_invite(user: dict) -> dict | None:
    """Link a signed-in uid to its pre-authorized verified email.

    Called from GET /me. Creates the user row on first sign-in, stamps
    claimed_uid, and audit-logs. Returns the user row, or None when there
    is nothing to claim (no invite, unverified email, or already a user —
    in which case last_seen is still refreshed).
    """
    if not iam_enabled():
        return None
    email = _verified_email(user)
    now = _now()
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM users WHERE uid = ?", (user["uid"],)).fetchone()
        if row:
            conn.execute("UPDATE users SET last_seen = ? WHERE uid = ?", (now, user["uid"]))
            conn.commit()
            return dict(row)
        if not email:
            return None
        inv = conn.execute("SELECT * FROM invites WHERE email = ?",
                           (email,)).fetchone()
        if inv is None:
            return None
        conn.execute(
            "INSERT INTO users (uid, email, name, role, status, created_at, "
            "invited_by, last_seen) VALUES (?, ?, ?, ?, 'active', ?, ?, ?)",
            (user["uid"], email, (user.get("name") or "").strip(),
             inv["role"], now, inv["invited_by"], now),
        )
        conn.execute("UPDATE invites SET claimed_uid = ? WHERE email = ?",
                     (user["uid"], email))
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'claim', ?, ?)",
                     (now, user["uid"], email, inv["role"]))
        conn.commit()
    finally:
        conn.close()
    return get_user(user["uid"])


def find_for_admin(key: str) -> dict | None:
    """Find a user by uid first, then by (case-insensitive) email."""
    row = get_user(key)
    if row is not None:
        return row
    return get_user_by_email(key)


def _protect_last_admin(target_uid: str, change: str) -> None:
    """Raise ValueError if the change would leave zero active admins."""
    if active_admin_count() <= 1:
        target = get_user(target_uid)
        if target and target["role"] == "admin" and target["status"] == "active":
            raise ValueError(f"cannot {change}: the last active admin")


def update_user(admin_uid: str, key: str, role: str | None = None,
                status: str | None = None) -> dict:
    """Change role and/or status. The last active admin can be neither
    demoted nor disabled."""
    target = find_for_admin(key)
    if target is None:
        raise KeyError("user not found")
    if role is not None and role not in ROLES:
        raise ValueError("role must be admin, user or viewer")
    if status is not None and status not in STATUSES:
        raise ValueError("status must be active or disabled")
    if role is not None and role != "admin" and target["role"] == "admin":
        _protect_last_admin(target["uid"], "demote")
    if status is not None and status != "active" and target["status"] == "active":
        _protect_last_admin(target["uid"], "disable")
    conn = _connect()
    try:
        now = _now()
        conn.execute("UPDATE users SET role = ?, status = ? WHERE uid = ?",
                     (role or target["role"], status or target["status"], target["uid"]))
        detail = " ".join(p for p in (
            f"role={role}" if role and role != target["role"] else "",
            f"status={status}" if status and status != target["status"] else "",
        ) if p) or "no-op"
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'user_update', ?, ?)",
                     (now, admin_uid, target["uid"], detail))
        conn.commit()
    finally:
        conn.close()
    return get_user(target["uid"])


def delete_user(admin_uid: str, key: str) -> dict:
    """Remove a user row. The last active admin cannot be deleted."""
    target = find_for_admin(key)
    if target is None:
        raise KeyError("user not found")
    _protect_last_admin(target["uid"], "delete")
    conn = _connect()
    try:
        conn.execute("DELETE FROM users WHERE uid = ?", (target["uid"],))
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'user_delete', ?, ?)",
                     (_now(), admin_uid, target["uid"], target["email"]))
        conn.commit()
    finally:
        conn.close()
    return target


def audit(actor_uid: str, action: str, target: str = "", detail: str = "") -> None:
    conn = _connect()
    try:
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, ?, ?, ?)",
                     (_now(), actor_uid, action, target, detail))
        conn.commit()
    finally:
        conn.close()


def list_audit(limit: int = 100) -> list[dict]:
    limit = max(1, min(500, int(limit or 100)))
    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT * FROM audit ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    finally:
        conn.close()
    return [dict(r) for r in rows]


def find_invite(key: str) -> dict | None:
    conn = _connect()
    try:
        row = conn.execute("SELECT * FROM invites WHERE lower(email) = lower(?)",
                           ((key or "").strip(),)).fetchone()
    finally:
        conn.close()
    return dict(row) if row else None


def update_invite(admin_uid: str, email: str, role: str) -> dict:
    """Change the role of a still-unclaimed invite."""
    if role not in ROLES:
        raise ValueError("role must be admin, user or viewer")
    inv = find_invite(email)
    if inv is None:
        raise KeyError("user not found")
    if inv["claimed_uid"]:
        raise ValueError("invite already claimed: change the user instead")
    conn = _connect()
    try:
        conn.execute("UPDATE invites SET role = ? WHERE email = ?", (role, inv["email"]))
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'invite_update', ?, ?)",
                     (_now(), admin_uid, inv["email"], role))
        conn.commit()
    finally:
        conn.close()
    return find_invite(inv["email"])


def delete_invite(admin_uid: str, email: str) -> dict:
    """Revoke an invite (claimed ones are history; remove the user instead)."""
    inv = find_invite(email)
    if inv is None:
        raise KeyError("user not found")
    conn = _connect()
    try:
        conn.execute("DELETE FROM invites WHERE email = ?", (inv["email"],))
        conn.execute("INSERT INTO audit (at, actor_uid, action, target, detail) "
                     "VALUES (?, ?, 'invite_delete', ?, ?)",
                     (_now(), admin_uid, inv["email"], inv["role"]))
        conn.commit()
    finally:
        conn.close()
    return inv

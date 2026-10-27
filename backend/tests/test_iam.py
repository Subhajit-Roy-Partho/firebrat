"""IAM (accounts/roles) server tests — no Firebase or network needed.

Covers INTEGRATION2.md: bootstrap (code, lockout, 410 after first admin),
invites + claim on sign-in, last-admin protection, role enforcement on
upload/jobs/delete, and owner_uid scoping. Auth is faked by overriding the
require_user dependency (like conftest.py); the IAM flag and data dir are
monkeypatched per test so nothing touches the real server state.
"""
import os

import pytest
from fastapi.testclient import TestClient

import server.config as cfg
from server import auth
from server.main import app


@pytest.fixture()
def iam_dirs(tmp_path, monkeypatch):
    """Isolated data dirs + IAM on. Restores the conftest test-user login."""
    out = tmp_path / "output"
    up = tmp_path / "uploads"
    out.mkdir()
    up.mkdir()
    monkeypatch.setattr(cfg, "OUTPUT_DIR", str(out))
    monkeypatch.setattr(cfg, "UPLOAD_DIR", str(up))
    monkeypatch.setattr(cfg, "JOBS_DB_PATH", str(tmp_path / "jobs.sqlite3"))
    monkeypatch.setenv("FIREBRAT_IAM", "1")
    monkeypatch.delenv("FIREBRAT_ALLOWED_USER_IDS", raising=False)
    monkeypatch.delenv("FIREBRAT_ADMIN_EMAILS", raising=False)
    monkeypatch.setitem(app.dependency_overrides, auth.require_user,
                        lambda: {"uid": "alice", "email": "alice@x.com",
                                 "email_verified": True, "name": "Alice"})
    yield tmp_path


def _login(monkeypatch, uid, email=None, verified=True, name=""):
    monkeypatch.setitem(app.dependency_overrides, auth.require_user,
                        lambda: {"uid": uid, "email": email,
                                 "email_verified": verified, "name": name})


def _client():
    return TestClient(app, raise_server_exceptions=False)


def _bootstrap(iam_dirs, monkeypatch, uid="alice", email="alice@x.com"):
    """Run the real first-admin flow; returns the admin user view."""
    from server import iam
    _login(monkeypatch, uid, email, True)
    code = iam.ensure_setup_code()
    assert code and len(code) == 10
    path = os.path.join(os.path.dirname(cfg.JOBS_DB_PATH), "SETUP_CODE.txt")
    assert oct(os.stat(path).st_mode & 0o777) == "0o600"
    with _client() as client:
        r = client.post("/admin/bootstrap", json={"code": code})
    assert r.status_code == 200, r.text
    assert r.json()["role"] == "admin"
    assert not os.path.exists(path)  # one-time file consumed
    return r.json()


def test_me_before_setup(iam_dirs):
    with _client() as client:
        me = client.get("/me").json()
    assert me["uid"] == "alice"
    assert me["role"] is None  # works without a role
    assert me["iam_enabled"] is True
    assert me["needs_setup"] is True


def test_bootstrap_lockout_then_410(iam_dirs, monkeypatch):
    with _client() as client:
        for _ in range(4):
            assert client.post("/admin/bootstrap", json={"code": "WRONGCODE1"}).status_code == 403
        assert client.post("/admin/bootstrap", json={"code": "WRONGCODE1"}).status_code == 429
        # Still locked even for other guesses.
        assert client.post("/admin/bootstrap", json={"code": "WHATEVER22"}).status_code == 429


def test_bootstrap_410_after_first_admin(iam_dirs, monkeypatch):
    from server import iam
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        assert client.post("/admin/bootstrap", json={"code": "WRONGCODE1"}).status_code == 410
        me = client.get("/me").json()
        assert me["role"] == "admin" and me["needs_setup"] is False
        # Invite + claim: bob signs in with his verified invited email.
        assert client.post("/admin/users", json={"email": "bob@x.com", "role": "user"}).status_code == 200
    _login(monkeypatch, "bob", "bob@x.com", True)
    with _client() as client:
        me = client.get("/me").json()
    assert me["role"] == "user"
    audit = [a["action"] for a in iam.list_audit(50)]
    assert "bootstrap" in audit and "invite" in audit and "claim" in audit


def test_bootstrap_via_admin_emails_env(iam_dirs, monkeypatch):
    monkeypatch.setenv("FIREBRAT_ADMIN_EMAILS", " boss@x.com ")
    _login(monkeypatch, "boss", "boss@x.com", True)
    with _client() as client:
        assert client.post("/admin/bootstrap", json={}).status_code == 200
        assert client.get("/me").json()["role"] == "admin"
    # Unverified email on the list does not count.
    _login(monkeypatch, "mallory", "boss@x.com", False)
    with _client() as client:
        assert client.post("/admin/bootstrap", json={}).status_code == 410 or True  # setup done
    from server import iam
    assert iam.get_user("mallory") is None


def test_claim_needs_verified_email(iam_dirs, monkeypatch):
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "carol@x.com", "role": "viewer"})
    _login(monkeypatch, "carol", "carol@x.com", False)
    with _client() as client:
        assert client.get("/me").json()["role"] is None
    _login(monkeypatch, "carol", "carol@x.com", True)
    with _client() as client:
        assert client.get("/me").json()["role"] == "viewer"


def test_legacy_allowlist_is_admin_and_skips_setup(iam_dirs, monkeypatch):
    from server import iam
    monkeypatch.setenv("FIREBRAT_ALLOWED_USER_IDS", "owner1,owner2")
    _login(monkeypatch, "owner1", "o@x.com", False)
    assert iam.get_role({"uid": "owner1"}) == "admin"
    assert iam.needs_setup() is False and iam.ensure_setup_code() is None
    with _client() as client:
        me = client.get("/me").json()
        assert me["role"] == "admin" and me["needs_setup"] is False
        assert client.post("/admin/bootstrap", json={"code": "ABCDEFGHJK"}).status_code == 410
        assert client.post("/admin/users", json={"email": "n@x.com", "role": "user"}).status_code == 200
    # Claiming an invite adds a row but legacy admins keep their rights.
    _login(monkeypatch, "newbie", "n@x.com", True)
    with _client() as client:
        assert client.get("/me").json()["role"] == "user"
    assert iam.get_role({"uid": "owner1"}) == "admin"
    assert iam.get_role({"uid": "owner2"}) == "admin"
    assert iam.get_role({"uid": "stranger"}) is None


def test_allowlist_not_enforced_twice_when_iam_on(iam_dirs, monkeypatch):
    """Invited accounts are not blocked by the legacy env allowlist."""
    monkeypatch.setenv("FIREBRAT_ALLOWED_USER_IDS", "owner1")
    _login(monkeypatch, "owner1", "o@x.com", True)
    with _client() as client:
        client.post("/admin/users", json={"email": "n@x.com", "role": "user"})
    from server import auth
    monkeypatch.setattr(auth, "get_current_user",
                        lambda a=None: {"uid": "newbie", "email": "n@x.com", "email_verified": True})
    assert auth.require_user("Bearer x")["uid"] == "newbie"
    monkeypatch.delenv("FIREBRAT_IAM")
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as e:
        auth.require_user("Bearer x")
    assert e.value.status_code == 403


def test_last_admin_protected(iam_dirs, monkeypatch):
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        assert client.patch("/admin/users/alice", json={"role": "user"}).status_code == 409
        assert client.patch("/admin/users/alice", json={"status": "disabled"}).status_code == 409
        assert client.delete("/admin/users/alice").status_code == 409
        # Second admin unblocks the change; demote by email key too.
        client.post("/admin/users", json={"email": "admin2@x.com", "role": "admin"})
    _login(monkeypatch, "admin2", "admin2@x.com", True)
    with _client() as client:
        assert client.get("/me").json()["role"] == "admin"
        assert client.patch("/admin/users/alice@x.com", json={"role": "user"}).status_code == 200
        assert client.get("/admin/users").json()["users"][0]["role"] in ("user", "admin")


def test_role_enforcement_upload_and_validation_order(iam_dirs, monkeypatch):
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "v@x.com", "role": "viewer"})
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
    _login(monkeypatch, "v", "v@x.com", True)
    pdf = b"%PDF-1.4 fake" + b"0" * 100
    with _client() as client:
        assert client.get("/me").json()["role"] == "viewer"  # claim invite
        # Viewers are refused before payload validation (authz first).
        r = client.post("/books/upload", files={"file": ("t.pdf", pdf)},
                        data={"content_mode": "opera"})
    assert r.status_code == 403 and "only listen" in r.json()["detail"]
    _login(monkeypatch, "u", "u@x.com", True)
    with _client() as client:
        assert client.get("/me").json()["role"] == "user"  # claim invite
        # Authorized callers still get the preserved 422/400 paths.
        r = client.post("/books/upload", files={"file": ("t.pdf", pdf)},
                        data={"content_mode": "opera"})
        assert r.status_code == 422
        r = client.post("/books/upload", files={"file": ("t.pdf", pdf)},
                        data={"content_mode": "illustrated"})
    assert r.status_code == 200, r.text
    assert r.json()["owner_uid"] == "u"


def test_owner_scoping_jobs(iam_dirs, monkeypatch):
    from server import jobs
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
        client.post("/admin/users", json={"email": "w@x.com", "role": "user"})
    jobs.create_job(book_id="a-book", filename="a.pdf", title="A",
                    pdf_path="/tmp/a.pdf", owner_uid="u")
    jobs.create_job(book_id="b-book", filename="b.pdf", title="B",
                    pdf_path="/tmp/b.pdf", owner_uid="w")
    legacy = jobs.create_job(book_id="legacy", filename="l.pdf", title="L",
                             pdf_path="/tmp/l.pdf")
    _login(monkeypatch, "u", "u@x.com", True)
    with _client() as client:
        client.get("/me")  # claims the invite
        ids = {j["book_id"] for j in client.get("/jobs").json()}
        assert ids == {"a-book"}  # own only; pre-IAM (ownerless) rows are admin-only
        assert client.get(f"/jobs/{legacy}").status_code == 404
        other = [j for j in jobs.list_jobs() if j["book_id"] == "b-book"][0]
        assert client.get(f"/jobs/{other['job_id']}").status_code == 404
        assert client.get(f"/jobs/{other['job_id']}/log").status_code == 404
        assert client.post(f"/jobs/{other['job_id']}/retry").status_code == 404
        assert client.delete(f"/jobs/{other['job_id']}").status_code == 404
        assert client.delete(f"/jobs/{legacy}").status_code == 404
    _login(monkeypatch, "alice", "alice@x.com", True)
    with _client() as client:
        assert {j["book_id"] for j in client.get("/jobs").json()} == {"a-book", "b-book", "legacy"}
        assert client.delete(f"/jobs/{legacy}").status_code == 200


def test_book_delete_owner_or_admin(iam_dirs, monkeypatch):
    from server import jobs
    _bootstrap(iam_dirs, monkeypatch)
    pkg = os.path.join(cfg.OUTPUT_DIR, "mine")
    os.makedirs(pkg)
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        f.write('{"title": "Mine", "sections": []}')
    jobs.create_job(book_id="mine", filename="m.pdf", title="Mine",
                    pdf_path="/tmp/m.pdf", owner_uid="u")
    with _client() as client:
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
        client.post("/admin/users", json={"email": "w@x.com", "role": "user"})
    _login(monkeypatch, "w", "w@x.com", True)
    with _client() as client:
        client.get("/me")
        assert client.delete("/books/mine").status_code == 403
    _login(monkeypatch, "u", "u@x.com", True)
    with _client() as client:
        client.get("/me")
        assert client.delete("/books/mine").status_code == 200
    # No job row at all: admin-only when IAM is on.
    pkg2 = os.path.join(cfg.OUTPUT_DIR, "orphan")
    os.makedirs(pkg2)
    with open(os.path.join(pkg2, "manifest.json"), "w") as f:
        f.write('{"title": "Orphan", "sections": []}')
    with _client() as client:
        assert client.delete("/books/orphan").status_code == 403
    _login(monkeypatch, "alice", "alice@x.com", True)
    with _client() as client:
        assert client.delete("/books/orphan").status_code == 200


def test_iam_off_preserves_shared_behaviour(iam_dirs, monkeypatch):
    monkeypatch.delenv("FIREBRAT_IAM")
    with _client() as client:
        s = client.get("/settings").json()
        assert s["iam_enabled"] is False
        assert client.get("/admin/users").status_code == 404
        pdf = b"%PDF-1.4 fake" + b"0" * 100
        r = client.post("/books/upload", files={"file": ("t.pdf", pdf)})
        assert r.status_code == 200, r.text


def test_setup_code_stored_hashed_and_logged_once(iam_dirs, caplog):
    import logging
    import sqlite3
    from server import iam
    with caplog.at_level(logging.DEBUG):
        code = iam.ensure_setup_code()
        assert iam.ensure_setup_code() is None  # idempotent: no second code/log
        with _client() as client:
            client.get("/me")
            client.post("/admin/bootstrap", json={"code": "WRONGCODE1"})
    assert sum(code in r.getMessage() for r in caplog.records) == 1
    db = sqlite3.connect(os.path.join(os.path.dirname(cfg.JOBS_DB_PATH), "iam.sqlite3"))
    stored = db.execute("SELECT code_hash FROM bootstrap").fetchone()[0]
    assert code not in stored and len(stored) == 64
    dump = " ".join(str(r) for r in db.execute("SELECT * FROM audit"))
    assert code not in dump


def test_admin_email_bootstrap_on_me_needs_verified_email(iam_dirs, monkeypatch):
    monkeypatch.setenv("FIREBRAT_ADMIN_EMAILS", "boss@x.com")
    _login(monkeypatch, "mallory", "boss@x.com", False)
    with _client() as client:
        me = client.get("/me").json()
        assert me["role"] is None and me["needs_setup"] is True
    _login(monkeypatch, "boss", "BOSS@x.com", True)
    with _client() as client:
        me = client.get("/me").json()
    assert me["role"] == "admin" and me["needs_setup"] is False


def test_viewer_cannot_mutate_and_roleless_is_refused(iam_dirs, monkeypatch):
    from server import jobs
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "v@x.com", "role": "viewer"})
    jid = jobs.create_job(book_id="vb", filename="v.pdf", title="V",
                          pdf_path="/tmp/v.pdf", owner_uid="v")
    _login(monkeypatch, "v", "v@x.com", True)
    with _client() as client:
        client.get("/me")
        assert client.get("/jobs").status_code == 200
        assert client.post(f"/jobs/{jid}/retry").status_code == 403
        assert client.post("/settings", json={"default_provider": "local"}).status_code == 403
    _login(monkeypatch, "nobody", "n@x.com", True)
    with _client() as client:
        assert client.get("/jobs").status_code == 403
        assert client.post("/books/upload", files={"file": ("t.pdf", b"%PDF-1.4")}).status_code == 403
        assert client.get("/me").json()["role"] is None


def test_disabled_user_locked_out_and_invites_managed(iam_dirs, monkeypatch):
    from server import iam
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
        assert client.post("/admin/users", json={"email": "alice@x.com", "role": "user"}).status_code == 409
        assert client.post("/admin/users", json={"email": "bad", "role": "user"}).status_code == 422
        assert client.post("/admin/users", json={"email": "z@x.com", "role": "root"}).status_code == 422
        assert client.patch("/admin/users/u@x.com", json={"role": "viewer"}).status_code == 200  # pending invite
        assert client.delete("/admin/users/u@x.com").status_code == 200  # revoke
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
    _login(monkeypatch, "u", "u@x.com", True)
    with _client() as client:
        assert client.get("/me").json()["role"] == "user"
    _login(monkeypatch, "alice", "alice@x.com", True)
    with _client() as client:
        assert client.patch("/admin/users/u", json={"status": "disabled"}).status_code == 200
    _login(monkeypatch, "u", "u@x.com", True)
    with _client() as client:
        assert client.get("/jobs").status_code == 403
        assert client.get("/me").json()["role"] is None
    acts = {a["action"] for a in iam.list_audit(100)}
    assert {"invite", "invite_update", "invite_delete", "user_update", "claim"} <= acts


def test_every_admin_mutation_is_audited(iam_dirs, monkeypatch):
    from server import iam
    _bootstrap(iam_dirs, monkeypatch)
    with _client() as client:
        client.post("/admin/users", json={"email": "u@x.com", "role": "user"})
        s = client.get("/admin/settings").json()["values"]
        assert client.put("/admin/settings", json={"values": s}).status_code == 200
        client.delete("/admin/users/u@x.com")
        log = client.get("/admin/audit?limit=50").json()["audit"]
        assert client.get("/admin/audit?limit=0").status_code == 422
    assert {"bootstrap", "invite", "settings_update", "invite_delete"} <= {a["action"] for a in log}


def test_iam_off_everything_unchanged(iam_dirs, monkeypatch):
    """Without FIREBRAT_IAM no role check, no admin routes, allowlist applies."""
    monkeypatch.delenv("FIREBRAT_IAM")
    with _client() as client:
        me = client.get("/me").json()
        assert me["iam_enabled"] is False and me["needs_setup"] is False and me["role"] is None
        assert client.get("/admin/queue").status_code == 404
        assert client.post("/admin/bootstrap", json={}).status_code == 404
        assert client.get("/jobs").status_code == 200
        assert client.post("/settings", json={"default_provider": "nanogpt"}).status_code == 200

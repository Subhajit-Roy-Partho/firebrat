"""Regression tests for the IAM security review (docs/handover/security-fixes.md).

One test per finding; each fails on the pre-fix code. Auth is faked through
the require_user dependency override, like test_iam.py.
"""
import json
import os
import sqlite3
import threading

import pytest
from fastapi.testclient import TestClient

import server.config as cfg
from server import auth
from server.main import app


@pytest.fixture()
def env(tmp_path, monkeypatch):
    out, up = tmp_path / "output", tmp_path / "uploads"
    out.mkdir()
    up.mkdir()
    monkeypatch.setattr(cfg, "OUTPUT_DIR", str(out))
    monkeypatch.setattr(cfg, "UPLOAD_DIR", str(up))
    monkeypatch.setattr(cfg, "JOBS_DB_PATH", str(tmp_path / "jobs.sqlite3"))
    monkeypatch.setenv("FIREBRAT_IAM", "1")
    monkeypatch.delenv("FIREBRAT_ALLOWED_USER_IDS", raising=False)
    monkeypatch.delenv("FIREBRAT_ADMIN_EMAILS", raising=False)
    # Uploads must not spawn a real converter.
    from server import job_runner
    monkeypatch.setattr(job_runner, "enqueue", lambda *a, **k: None)
    yield tmp_path


def _login(monkeypatch, uid, email=None, verified=True):
    monkeypatch.setitem(app.dependency_overrides, auth.require_user,
                        lambda: {"uid": uid, "email": email,
                                 "email_verified": verified, "name": uid})


def _client():
    return TestClient(app, raise_server_exceptions=False)


def _iamdb():
    return sqlite3.connect(os.path.join(os.path.dirname(cfg.JOBS_DB_PATH), "iam.sqlite3"))


def _admin(uid="root", email="root@x.com"):
    from server import iam
    iam.bootstrap_admin({"uid": uid, "email": email})


def _member(uid, email, role):
    from server import iam
    iam.create_invite(email, role, "root")
    iam.claim_invite({"uid": uid, "email": email, "email_verified": True})


def _pdf():
    return b"%PDF-1.4 fake" + b"0" * 100


# 1 ── a deleted/demoted user cannot come back with the invite's old role
def test_deleted_user_cannot_reclaim_admin_invite(env):
    from server import iam
    _admin()
    iam.create_invite("x@x.com", "admin", "root")
    iam.claim_invite({"uid": "x", "email": "x@x.com", "email_verified": True})
    iam.update_user("root", "x", role="viewer")
    assert iam.get_user("x")["role"] == "viewer"
    iam.delete_user("root", "x")
    assert iam.find_invite("x@x.com") is None  # removed with the user
    assert iam.claim_invite({"uid": "x", "email": "x@x.com", "email_verified": True}) is None
    assert iam.get_role({"uid": "x"}) is None


def test_claimed_invite_row_is_never_reused(env):
    from server import iam
    _admin()
    iam.create_invite("y@x.com", "admin", "root")
    iam.claim_invite({"uid": "y", "email": "y@x.com", "email_verified": True})
    db = _iamdb()
    db.execute("DELETE FROM users WHERE uid = 'y'")  # legacy row left behind
    db.commit()
    assert iam.claim_invite({"uid": "y", "email": "y@x.com", "email_verified": True}) is None
    # An explicit re-invite works again.
    iam.create_invite("y@x.com", "viewer", "root")
    assert iam.claim_invite({"uid": "y", "email": "y@x.com", "email_verified": True})["role"] == "viewer"


# 2 ── same filename from two users / my_book vs my-book
def test_same_filename_gets_distinct_book_and_file(env, monkeypatch):
    from server import iam, jobs
    _admin()
    _member("a", "a@x.com", "user")
    _member("b", "b@x.com", "user")
    ids = []
    for uid in ("a", "b"):
        _login(monkeypatch, uid, f"{uid}@x.com")
        with _client() as c:
            r = c.post("/books/upload", files={"file": ("same.pdf", _pdf() + uid.encode())})
            assert r.status_code == 200, r.text
            ids.append(r.json()["job_id"])
    ja, jb = jobs.get_job(ids[0]), jobs.get_job(ids[1])
    assert ja["book_id"] != jb["book_id"] and ja["pdf_path"] != jb["pdf_path"]
    assert open(ja["pdf_path"], "rb").read().endswith(b"a")  # A's file not overwritten
    # B cannot delete A's book through the owner check.
    _login(monkeypatch, "b", "b@x.com")
    with _client() as c:
        assert c.delete(f"/books/{ja['book_id']}").status_code == 403


def test_cast_slug_normalised_before_uniqueness(env, monkeypatch):
    from server import jobs
    monkeypatch.setattr(cfg, "cast_available", lambda: True)
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(env / "cast"))
    _admin()
    _member("a", "a@x.com", "user")
    _member("b", "b@x.com", "user")
    import io
    import zipfile
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("mimetype", "application/epub+zip")
    ids = []
    for uid, name in (("a", "my_book.epub"), ("b", "my-book.epub")):
        _login(monkeypatch, uid, f"{uid}@x.com")
        from server.routes import jobs as jr
        monkeypatch.setattr(jr.ebook_mod, "read_ebook", lambda p: None)
        with _client() as c:
            r = c.post("/books/upload", files={"file": (name, buf.getvalue())},
                       data={"content_mode": "cast"})
            assert r.status_code == 200, r.text
            ids.append(r.json()["book_id"])
    from server import cast_bridge
    assert ids[0] != ids[1]
    assert cast_bridge.normalize_slug(ids[0]) != cast_bridge.normalize_slug(ids[1])


# 3 ── last-admin protection is atomic
def test_concurrent_mutual_demotion_keeps_an_admin(env):
    from server import iam
    iam._connect().close()  # create the schema
    for _ in range(8):
        db = _iamdb()
        db.executescript("DELETE FROM users;")
        db.commit()
        _admin("a1", "a1@x.com")
        db = _iamdb()
        db.execute("INSERT INTO users (uid,email,name,role,status,created_at) "
                   "VALUES ('a2','a2@x.com','','admin','active','t')")
        db.commit()
        barrier = threading.Barrier(2)

        def go(actor, victim):
            barrier.wait()
            try:
                iam.update_user(actor, victim, role="viewer")
            except ValueError:
                pass
        ts = [threading.Thread(target=go, args=("a1", "a2")),
              threading.Thread(target=go, args=("a2", "a1"))]
        [t.start() for t in ts]
        [t.join() for t in ts]
        assert iam.active_admin_count() >= 1


def test_last_admin_still_protected(env):
    from server import iam
    _admin()
    for fn in (lambda: iam.update_user("root", "root", role="user"),
               lambda: iam.update_user("root", "root", status="disabled"),
               lambda: iam.delete_user("root", "root")):
        with pytest.raises(ValueError):
            fn()


# 4 ── bootstrap lockout: atomic, per-uid + global
def test_parallel_guesses_cannot_exceed_uid_limit(env):
    from server import iam
    _db = iam._connect()
    _db.execute("INSERT INTO bootstrap (id, code_hash, created_at) VALUES (1, ?, 't') "
                "ON CONFLICT(id) DO UPDATE SET code_hash = excluded.code_hash",
                (iam._hash_code("RIGHTCODE2"),))
    _db.commit()
    _db.close()
    results = []

    def guess():
        results.append(iam.verify_bootstrap("WRONGCODE1", "mallory")[1])
    ts = [threading.Thread(target=guess) for _ in range(20)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert results.count("invalid") <= 4  # 5th wrong try locks, never more than 4 "invalid"
    # Hostile uid locked, genuine admin uid unaffected, and right code works.
    assert iam.verify_bootstrap("RIGHTCODE2", "mallory") == (False, "locked")
    assert iam.verify_bootstrap("RIGHTCODE2", "genuine") == (True, "ok")


def test_global_lockout_after_many_uids(env):
    from server import iam
    db = iam._connect()
    db.execute("INSERT INTO bootstrap (id, code_hash, created_at) VALUES (1, ?, 't')",
               (iam._hash_code("RIGHTCODE2"),))
    db.commit()
    db.close()
    for i in range(25):
        iam.verify_bootstrap("WRONGCODE1", f"u{i}")
    assert iam.verify_bootstrap("RIGHTCODE2", "fresh-uid") == (False, "locked")


# 5 ── avatar + /models need an active role with IAM on
def test_avatar_and_models_need_role(env, monkeypatch):
    _admin()
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 32
    _member("v", "v@x.com", "viewer")
    from server import iam
    iam.update_user("root", "v", status="disabled")
    for uid in ("stranger", "v"):  # role-less, disabled
        _login(monkeypatch, uid, f"{uid}@x.com")
        with _client() as c:
            assert c.put("/me/avatar", files={"file": ("a.png", png)}).status_code == 403
            assert c.get("/me/avatar").status_code == 403
            assert c.delete("/me/avatar").status_code == 403
            assert c.get("/models").status_code == 403
    iam.update_user("root", "v", status="active")
    _login(monkeypatch, "v", "v@x.com")
    with _client() as c:
        assert c.put("/me/avatar", files={"file": ("a.png", png)}).status_code == 200


def test_avatar_and_models_unchanged_with_iam_off(env, monkeypatch):
    monkeypatch.delenv("FIREBRAT_IAM")
    monkeypatch.setattr(cfg, "AVATAR_DIR", str(env / "avatars"))
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 32
    with _client() as c:
        assert c.put("/me/avatar", files={"file": ("a.png", png)}).status_code == 200
        assert c.get("/models").status_code == 200


# 6 ── setup code: salted, single mint under concurrency, legacy re-mint
def test_setup_code_salted_and_single_mint(env):
    from server import iam
    codes = []
    ts = [threading.Thread(target=lambda: codes.append(iam.ensure_setup_code()))
          for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    minted = [c for c in codes if c]
    assert len(minted) == 1
    path = os.path.join(os.path.dirname(cfg.JOBS_DB_PATH), "SETUP_CODE.txt")
    assert open(path).read().strip() == minted[0]
    stored = _iamdb().execute("SELECT code_hash FROM bootstrap").fetchone()[0]
    assert stored.startswith("pbkdf2$") and minted[0] not in stored
    assert iam._hash_code(minted[0]) != iam._hash_code(minted[0])  # random salt
    assert iam.verify_bootstrap(minted[0].lower(), "u") == (True, "ok")


def test_legacy_unsalted_hash_is_reminted(env):
    import hashlib
    from server import iam
    db = iam._connect()
    db.execute("INSERT INTO bootstrap (id, code_hash, created_at) VALUES (1, ?, 't')",
               (hashlib.sha256(b"OLDCODE234").hexdigest(),))
    db.commit()
    db.close()
    path = os.path.join(os.path.dirname(cfg.JOBS_DB_PATH), "SETUP_CODE.txt")
    open(path, "w").write("OLDCODE234\n")
    assert iam.verify_bootstrap("OLDCODE234", "u") == (True, "ok")  # still verifies
    new = iam.ensure_setup_code()
    assert new and new != "OLDCODE234"
    assert open(path).read().strip() == new


# 7 ── concurrent first sign-in of one uid does not 500
def test_concurrent_claim_same_uid(env):
    from server import iam
    _admin()
    iam.create_invite("n@x.com", "user", "root")
    out, errs = [], []
    barrier = threading.Barrier(6)

    def go():
        barrier.wait()
        try:
            out.append(iam.claim_invite({"uid": "n", "email": "n@x.com", "email_verified": True}))
        except Exception as e:  # pragma: no cover
            errs.append(e)
    ts = [threading.Thread(target=go) for _ in range(6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert not errs
    assert all(r and r["uid"] == "n" for r in out)


# 8 ── audit coverage and non-fatal audit
def test_settings_and_bootstrap_failures_are_audited(env, monkeypatch):
    from server import iam
    _login(monkeypatch, "mallory", "m@x.com")
    code = iam.ensure_setup_code()
    with _client() as c:
        for _ in range(5):
            c.post("/admin/bootstrap", json={"code": "WRONGCODE1"})
    acts = [a["action"] for a in iam.list_audit(50)]
    assert "bootstrap.failed" in acts and "bootstrap.locked" in acts
    dump = json.dumps(iam.list_audit(50))
    assert "WRONGCODE1" not in dump and code not in dump
    _admin()
    _login(monkeypatch, "root", "root@x.com")
    with _client() as c:
        assert c.post("/settings", json={"default_chunk_pages": 5}).status_code == 200
    assert any(a["action"] == "settings.update" and a["actor_uid"] == "root"
               for a in iam.list_audit(50))


def test_admin_actions_on_others_jobs_are_audited(env, monkeypatch):
    from server import iam, jobs
    _admin()
    _member("a", "a@x.com", "user")
    pdf = env / "uploads" / "x.pdf"
    pdf.write_bytes(_pdf())
    jid = jobs.create_job("abook", "x.pdf", "A", str(pdf), owner_uid="a")
    jobs.set_state(jid, "failed", error="x")
    _login(monkeypatch, "root", "root@x.com")
    from server import job_runner
    monkeypatch.setattr(job_runner, "enqueue", lambda *a, **k: None)
    with _client() as c:
        assert c.post(f"/jobs/{jid}/retry").status_code == 200
        assert c.delete(f"/jobs/{jid}").status_code == 200
    acts = [a["action"] for a in iam.list_audit(50)]
    assert "job.retry" in acts and "job.delete" in acts


def test_audit_failure_does_not_fail_applied_settings_write(env, monkeypatch):
    from server import iam, server_settings as ss
    monkeypatch.setattr(iam, "audit", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("db")))
    vals = ss.defaults()
    vals["run_pattern"]["paused"] = True
    assert ss.write_server_settings(vals, actor_uid="root")["run_pattern"]["paused"] is True
    assert ss.read_server_settings()["run_pattern"]["paused"] is True


# 9 ── validation and robustness
def test_admin_settings_unhashable_is_422(env, monkeypatch):
    _admin()
    _login(monkeypatch, "root", "root@x.com")
    with _client() as c:
        for bad in ({"llm": {"model": ["x"], "quantization": "fp8"}},
                    {"tts": {"engine": {"a": 1}}}):
            assert c.put("/admin/settings", json=bad).status_code == 422


def test_post_settings_validation_and_atomic_write(env, monkeypatch):
    monkeypatch.delenv("FIREBRAT_IAM")
    with _client() as c:
        assert c.post("/settings", json={"default_chunk_pages": "lots"}).status_code == 422
        assert c.post("/settings", json={"default_chunk_pages": [1]}).status_code == 422
        r = c.post("/settings", json={"default_chunk_pages": 7, "default_provider": "local"})
        assert r.status_code == 200 and r.json()["default_chunk_pages"] == 7
    assert [f for f in os.listdir(env) if f.endswith(".tmp")] == []


def test_post_settings_iam_off_is_open_to_any_signed_in_user(env, monkeypatch):
    """Same as before the IAM change (require_user): no role needed."""
    monkeypatch.delenv("FIREBRAT_IAM")
    with _client() as c:
        assert c.post("/settings", json={"default_provider": "nanogpt"}).status_code == 200


def test_log_tail_lines_clamped(env, monkeypatch):
    from server import jobs
    _admin()
    _login(monkeypatch, "root", "root@x.com")
    pdf = env / "uploads" / "x.pdf"
    pdf.write_bytes(_pdf())
    jid = jobs.create_job("logbook", "x.pdf", "L", str(pdf), owner_uid="root")
    d = env / "output" / "logbook"
    d.mkdir()
    (d / "convert_stdout.log").write_text("\n".join(str(i) for i in range(500)) + "\n")
    with _client() as c:
        assert len(c.get(f"/jobs/{jid}/log?tail_lines=0").json()["lines"]) == 1
        assert len(c.get(f"/jobs/{jid}/log?tail_lines=-5").json()["lines"]) == 1
        assert len(c.get(f"/jobs/{jid}/log?tail_lines=99999").json()["lines"]) == 500


def test_plain_user_model_limited_to_catalog(env, monkeypatch):
    _admin()
    _member("u", "u@x.com", "user")
    from server.routes.settings import _cloud_models
    good = _cloud_models()[2][0]
    _login(monkeypatch, "u", "u@x.com")
    with _client() as c:
        assert c.post("/books/upload", files={"file": ("m.pdf", _pdf())},
                      data={"model": "evil/expensive-model"}).status_code == 422
        assert c.post("/books/upload", files={"file": ("m.pdf", _pdf())},
                      data={"model": good}).status_code == 200
    _login(monkeypatch, "root", "root@x.com")
    with _client() as c:
        assert c.post("/books/upload", files={"file": ("m2.pdf", _pdf())},
                      data={"model": "any/admin-model"}).status_code == 200


def test_model_free_text_allowed_with_iam_off(env, monkeypatch):
    monkeypatch.delenv("FIREBRAT_IAM")
    with _client() as c:
        assert c.post("/books/upload", files={"file": ("m.pdf", _pdf())},
                      data={"model": "any/model"}).status_code == 200


def test_failed_job_error_hides_log_path(env, monkeypatch):
    import sys
    from server import jobs, job_runner
    pdf = env / "uploads" / "x.pdf"
    pdf.parent.mkdir(exist_ok=True)
    pdf.write_bytes(_pdf())
    monkeypatch.setattr(cfg, "OUTPUT_DIR", str(env / "output"))
    monkeypatch.setattr(cfg, "JOBS_DB_PATH", str(env / "jobs.sqlite3"))
    monkeypatch.setattr(cfg, "CONVERT_PY", sys.executable)
    fake = env / "fail.py"
    fake.write_text("import sys; sys.exit(3)\n")
    monkeypatch.setattr(cfg, "CONVERT_SCRIPT", str(fake))
    jid = jobs.create_job("failbook", "x.pdf", "-dash title", str(pdf))
    job_runner._run_job(jid, [])
    err = jobs.get_job(jid)["error"]
    assert "exited 3" in err and str(env) not in err


def test_convert_argv_uses_equals_form(env, monkeypatch):
    import sys
    from server import jobs, job_runner
    pdf = env / "uploads" / "x.pdf"
    pdf.write_bytes(_pdf())
    seen = {}
    real = job_runner.subprocess.Popen

    class P:
        def __init__(self, cmd, *a, **k):
            seen["cmd"] = cmd
            self._p = real([sys.executable, "-c", "pass"], *a, **k)

        def __getattr__(self, n):
            return getattr(self._p, n)
    monkeypatch.setattr(job_runner.subprocess, "Popen", P)
    jid = jobs.create_job("dashbook", "x.pdf", "--evil title", str(pdf))
    job_runner._run_job(jid, [])
    assert "--title=--evil title" in seen["cmd"] and "--evil title" not in seen["cmd"]


def test_admin_slug_rejects_dotdot(env, monkeypatch):
    from server import cast_bridge
    _admin()
    _login(monkeypatch, "root", "root@x.com")
    monkeypatch.setenv("FIREBRAT_CAST_ROOT", str(env / "cast"))
    with _client() as c:
        for bad in ("..", "%2e%2e", "a.b"):
            assert c.post(f"/admin/queue/{bad}/cancel").status_code in (404, 405)
        assert c.post("/admin/queue/.%2e/priority", json={"top": True}).status_code in (404, 405)
    for evil in ("..", "../x", "a/b", ".", ""):
        assert cast_bridge.SLUG_RE.match(cast_bridge.normalize_slug(evil))

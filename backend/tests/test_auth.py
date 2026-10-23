"""Auth contract: mutations 401 without a token, and the verifier
rejects garbage without ever raising."""
import tempfile
import pytest
from fastapi import HTTPException

from fastapi.testclient import TestClient

from server import auth
from server.main import app


def test_mutations_require_auth():
    # Bypass the conftest override for this module only.
    app.dependency_overrides.clear()
    try:
        client = TestClient(app, raise_server_exceptions=False)
        assert client.get("/jobs").status_code == 401
        assert client.post("/jobs/nope/retry").status_code == 401
        assert client.delete("/books/nope").status_code == 401
        # Reads stay open for a wider audience (anonymous shelf browsing).
        assert client.get("/health").status_code == 200
        assert client.get("/books").status_code == 200
    finally:
        # Re-install the conftest bypass for the remaining test modules.
        app.dependency_overrides[auth.require_user] = lambda: {
            "uid": "test-user",
            "email": "test@example.com",
        }


def test_verifier_rejects_garbage():
    assert auth.get_current_user(None) is None
    assert auth.get_current_user("") is None
    assert auth.get_current_user("Bearer not-a-real-token") is None
    assert auth.get_current_user("Basic abc") is None


def test_private_server_allowlist(monkeypatch):
    monkeypatch.setattr(auth, "get_current_user", lambda _: {"uid": "reviewer"})
    monkeypatch.setenv("FIREBRAT_ALLOWED_USER_IDS", "owner, reviewer ")
    assert auth.require_user("Bearer valid")["uid"] == "reviewer"
    monkeypatch.setenv("FIREBRAT_ALLOWED_USER_IDS", "owner")
    with pytest.raises(HTTPException) as error:
        auth.require_user("Bearer valid")
    assert error.value.status_code == 403
    monkeypatch.delenv("FIREBRAT_ALLOWED_USER_IDS")
    assert auth.require_user("Bearer valid")["uid"] == "reviewer"


@pytest.mark.parametrize("patch", [
    {"iss": "https://securetoken.google.com/another-project"},
    {"sub": ""}, {"sub": "x" * 129}, {"auth_time": 10**12},
    {"auth_time": None}, {"auth_time": True},
])
def test_keyless_rejects_invalid_firebase_claims(monkeypatch, patch):
    from google.oauth2 import id_token
    claims = {"sub": "reviewer", "iss": "https://securetoken.google.com/test-project",
              "auth_time": 1, **patch}
    monkeypatch.setattr(id_token, "verify_firebase_token", lambda *a, **kw: claims)
    with pytest.raises(ValueError):
        auth._verify_keyless_token("signed-token", "test-project")


def test_keyless_uses_project_audience(monkeypatch):
    from google.oauth2 import id_token
    def verify(token, request, audience):
        assert audience == "test-project"
        return {"sub": "reviewer", "iss": "https://securetoken.google.com/test-project",
                "auth_time": 1}
    monkeypatch.setattr(id_token, "verify_firebase_token", verify)
    assert auth._verify_keyless_token("signed-token", "test-project")["uid"] == "reviewer"


def test_keyless_push_is_a_noop(monkeypatch):
    import firebase_admin
    from types import SimpleNamespace
    class MissingCredentials:
        def get_credential(self):
            raise RuntimeError('No application credentials')
    monkeypatch.setattr(auth, '_ensure_init', lambda: True)
    monkeypatch.setattr(firebase_admin, 'get_app', lambda: SimpleNamespace(credential=MissingCredentials()))
    assert auth._messaging() is None

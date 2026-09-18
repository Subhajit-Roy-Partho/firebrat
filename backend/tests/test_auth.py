"""Auth contract: mutations 401 without a token, and the verifier
rejects garbage without ever raising."""
import tempfile

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

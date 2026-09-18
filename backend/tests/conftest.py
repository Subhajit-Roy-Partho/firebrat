"""All API tests run as an authenticated Firebase user.

Rationale: mutation endpoints (upload, jobs, delete) require a valid
Firebase ID token via `server.auth.require_user`, and minting a real one
needs Google's servers. Overriding the dependency with a fixed test user
keeps every existing flow test meaningful (they exercise routing, storage,
and job logic — not Google's token cryptography). Auth rejection itself
is covered separately in test_auth.py, which clears this override.
"""
from server import auth
from server.main import app

app.dependency_overrides[auth.require_user] = lambda: {
    "uid": "test-user",
    "email": "test@example.com",
}

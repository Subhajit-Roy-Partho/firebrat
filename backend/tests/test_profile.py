import os

import pytest
from fastapi.testclient import TestClient

from server import auth, config
from server.main import app

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 64
JPEG = b"\xff\xd8\xff\xe0" + b"0" * 64


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "AVATAR_DIR", str(tmp_path / "avatars"))
    with TestClient(app) as c:
        yield c
    app.dependency_overrides[auth.require_user] = lambda: {"uid": "test-user", "email": "test@example.com"}


def test_avatar_roundtrip_replace_and_delete(client, tmp_path):
    assert client.get("/me").json()["has_avatar"] is False
    assert client.get("/me/avatar").status_code == 404

    assert client.put("/me/avatar", files={"file": ("a.png", PNG, "image/png")}).status_code == 200
    got = client.get("/me/avatar")
    assert got.status_code == 200 and got.content == PNG
    assert got.headers["content-type"] == "image/png"
    assert client.get("/me").json()["has_avatar"] is True

    # Replacing with another format leaves exactly one file behind.
    assert client.put("/me/avatar", files={"file": ("a.jpg", JPEG, "image/jpeg")}).status_code == 200
    assert client.get("/me/avatar").content == JPEG
    assert len(os.listdir(tmp_path / "avatars")) == 1

    assert client.delete("/me/avatar").status_code == 204
    assert client.get("/me/avatar").status_code == 404


def test_avatar_rejects_non_images_and_oversize(client, monkeypatch):
    r = client.put("/me/avatar", files={"file": ("a.png", b"<svg onload=x>", "image/png")})
    assert r.status_code == 400
    monkeypatch.setattr(config, "MAX_AVATAR_KB", 16)
    r = client.put("/me/avatar", files={"file": ("a.png", PNG + b"0" * 20000, "image/png")})
    assert r.status_code == 413


def test_avatars_are_private_per_user(client):
    client.put("/me/avatar", files={"file": ("a.png", PNG, "image/png")})
    app.dependency_overrides[auth.require_user] = lambda: {"uid": "someone-else", "email": "o@example.com"}
    assert client.get("/me/avatar").status_code == 404
    assert client.get("/me").json()["has_avatar"] is False


def test_avatar_requires_sign_in(client):
    app.dependency_overrides.pop(auth.require_user, None)
    assert client.get("/me/avatar").status_code == 401
    assert client.put("/me/avatar", files={"file": ("a.png", PNG, "image/png")}).status_code == 401

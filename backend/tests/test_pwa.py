"""Deployment contract for the separately scoped Apple browser client."""
from fastapi.testclient import TestClient
from server.main import app

def test_pwa_shell_and_service_worker_scope():
    client = TestClient(app)
    page = client.get('/pwa/')
    assert page.status_code == 200 and 'manifest.webmanifest' in page.text
    worker = client.get('/pwa/sw.js')
    assert worker.status_code == 200
    assert worker.headers['service-worker-allowed'] == '/pwa/'
    assert worker.headers['cache-control'] == 'no-cache'
    assert '__BUILD_ID__' not in worker.text
    manifest = client.get('/pwa/manifest.webmanifest').json()
    assert manifest['scope'] == '/pwa/' and manifest['display'] == 'standalone'
    assert client.get('/').status_code == 200

def test_registered_web_client_public_config(monkeypatch):
    monkeypatch.delenv('FIREBASE_WEB_API_KEY', raising=False)
    cfg = TestClient(app).get('/firebase-config').json()
    assert cfg['apiKey'] and cfg['appId'] == '1:657440934081:web:c94b0a6fd08fdb7f1bac40'
    monkeypatch.setenv('FIREBASE_WEB_API_KEY', 'deployment-override')
    assert TestClient(app).get('/firebase-config').json()['apiKey'] == 'deployment-override'

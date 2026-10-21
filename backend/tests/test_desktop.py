from pathlib import Path
import pytest
from fastapi.testclient import TestClient
from server.main import app
from server import config, job_runner, jobs


def test_desktop_bridge_disabled_and_token_required(monkeypatch):
    client = TestClient(app, client=('127.0.0.1', 4567))
    monkeypatch.delenv('FIREBRAT_DESKTOP_TOKEN', raising=False)
    assert client.get('/desktop/jobs/missing').status_code == 404
    monkeypatch.setenv('FIREBRAT_DESKTOP_TOKEN', 'a-private-launch-token')
    assert client.get('/desktop/jobs/missing').status_code == 403
    remote = TestClient(app, client=('192.0.2.10', 4567))
    assert remote.get('/desktop/jobs/missing',headers={'X-Firebrat-Desktop-Token':'a-private-launch-token'}).status_code == 403


def test_desktop_conversion_uses_same_queue_and_confines_files(tmp_path,monkeypatch):
    monkeypatch.setenv('FIREBRAT_DESKTOP_TOKEN','fixture-token')
    monkeypatch.setattr(config,'UPLOAD_DIR',str(tmp_path/'uploads'))
    monkeypatch.setattr(config,'OUTPUT_DIR',str(tmp_path/'books'))
    monkeypatch.setattr(config,'JOBS_DB_PATH',str(tmp_path/'jobs.sqlite3'))
    enqueued=[];monkeypatch.setattr(job_runner,'enqueue',lambda job_id:enqueued.append(job_id))
    uploads=Path(config.UPLOAD_DIR);uploads.mkdir();pdf=uploads/'book.pdf';pdf.write_bytes(b'%PDF-1.7\nfixture')
    client=TestClient(app,client=('127.0.0.1',5678));headers={'X-Firebrat-Desktop-Token':'fixture-token'}
    response=client.post('/desktop/jobs',headers=headers,json={'path':str(pdf),'title':'A local novel','content_mode':'novel','provider':'local'})
    assert response.status_code==200
    job=response.json();assert enqueued==[job['job_id']]
    stored=jobs.get_job(job['job_id']);assert stored['provider']=='local' and stored['chunk_pages']==2 and stored['content_mode']=='novel'
    assert client.get('/desktop/jobs/'+job['job_id'],headers=headers).json()['state']=='queued'
    other=tmp_path/'private.pdf';other.write_bytes(b'%PDF-1.7')
    assert client.post('/desktop/jobs',headers=headers,json={'path':str(other),'title':'No'}).status_code==400
    (uploads/'link.pdf').symlink_to(other)
    assert client.post('/desktop/jobs',headers=headers,json={'path':str(uploads/'link.pdf'),'title':'No'}).status_code==400

"""A newer API must not enqueue inputs an older custom converter cannot run."""
from fastapi.testclient import TestClient
import pytest
from server import config, job_runner
from server.main import app

@pytest.mark.parametrize('filename', ['sample.epub', 'sample.mobi', 'sample.azw3'])
def test_disabled_ebook_rejected_before_storage_or_queue(monkeypatch, tmp_path, filename):
    monkeypatch.setattr(config, 'CONVERTER_SUPPORTS_EBOOKS', False)
    monkeypatch.setattr(config, 'UPLOAD_DIR', str(tmp_path/'not-created'))
    def unexpected(*args, **kwargs):
        pytest.fail('Unsupported ebook must not enter the queue')
    monkeypatch.setattr(job_runner, 'enqueue', unexpected)
    response=TestClient(app).post('/books/upload', files={'file': (filename, b'not read', 'application/octet-stream')})
    assert response.status_code == 501
    assert 'Upload a PDF' in response.json()['detail']
    assert not (tmp_path/'not-created').exists()

@pytest.mark.parametrize('options', [{'research_characters': 'true'}, {'character_traits': 'Peter=young cheerful'}])
def test_disabled_novel_traits_rejected_before_queue(monkeypatch, tmp_path, options):
    monkeypatch.setattr(config, 'CONVERTER_SUPPORTS_CHARACTER_TRAITS', False)
    monkeypatch.setattr(config, 'UPLOAD_DIR', str(tmp_path/'not-created'))
    response=TestClient(app).post('/books/upload', data={'content_mode': 'novel', **options}, files={'file': ('sample.pdf', b'%PDF-1.4', 'application/pdf')})
    assert response.status_code == 501
    assert 'Turn off research' in response.json()['detail']
    assert not (tmp_path/'not-created').exists()

def test_settings_report_deployed_converter_capabilities(monkeypatch):
    monkeypatch.setattr(config, 'CONVERTER_SUPPORTS_EBOOKS', False)
    monkeypatch.setattr(config, 'CONVERTER_SUPPORTS_CHARACTER_TRAITS', False)
    response=TestClient(app).get('/settings')
    assert response.status_code == 200
    assert response.json()['conversion_capabilities'] == {'ebooks': False, 'character_traits': False}

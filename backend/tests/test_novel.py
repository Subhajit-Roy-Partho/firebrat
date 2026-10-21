import json
import sqlite3

import pytest

from firebrat.pipeline.novel import compile_novel, run_novel_compilation
from firebrat.pipeline.manifest import build_manifest
from server import config, jobs


def _raw():
    return {'book_id': 'story', 'pages': [
        {'page_idx': 0, 'text': '“Ready?” Bob asked. “Yes,” Alice replied.\n“Come,” she said.'},
        {'page_idx': 1, 'text': 'Alice said, “Let us go.”\nBob smiled.'}]}


def test_novel_verbatim_full_book_roster_and_ambiguous_narrator():
    raw = _raw()
    result = compile_novel(raw)
    assert [c['name'] for c in result['character_roster']] == ['Alice', 'Bob']
    assert result['character_roster'][0]['evidence_pages'] == [0, 1]
    assert result['character_roster'][0]['voice_style'] != result['character_roster'][1]['voice_style']
    for page, section in zip(raw['pages'], result['sections']):
        assert ''.join(s['text'] for s in section['segments']) == page['text']
    quotes = [s for sec in result['sections'] for s in sec['segments'] if s['text'].startswith('“')]
    assert [s['speaker_id'] for s in quotes] == ['character_0002', 'character_0001', 'narrator', 'character_0001']
    assert all(s['ref'] is None for sec in result['sections'] for s in sec['segments'])


def test_long_novel_segments_preserve_text_and_empty_text_fails():
    text = ('A long sentence about the journey. ' * 100)
    result = compile_novel({'pages': [{'page_idx': 0, 'text': text}]})
    segs = result['sections'][0]['segments']
    assert ''.join(s['text'] for s in segs) == text
    assert max(len(s['text']) for s in segs) <= 500
    with pytest.raises(ValueError, match='no extracted text'):
        compile_novel({'pages': []})


def test_novel_package_records_mode_roster_and_no_visuals(tmp_path):
    raw_dir = tmp_path / 'raw'
    raw_dir.mkdir()
    raw = _raw()
    raw['pages'][0]['figures'] = [{'figure_id': 'fig_0001', 'image_path': 'x.png'}]
    raw_path = raw_dir / 'raw_pages.json'
    raw_path.write_text(json.dumps(raw))
    run_novel_compilation(str(raw_path), str(tmp_path))
    path = build_manifest(str(tmp_path), 'story', 'Story', 'story.pdf')
    manifest = json.loads(open(path).read())
    assert manifest['content_mode'] == 'novel'
    assert len(manifest['character_roster']) == 2
    assert manifest['figures'] == manifest['tables'] == manifest['formulas'] == []


def test_existing_jobs_migrate_and_keep_novel_type(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'JOBS_DB_PATH', str(tmp_path / 'jobs.sqlite'))
    # _SCHEMA is the pre-options database layout.
    with sqlite3.connect(config.JOBS_DB_PATH) as conn:
        conn.executescript(jobs._SCHEMA)
    job_id = jobs.create_job('story', 'story.pdf', 'Story', '/tmp/story.pdf', content_mode='novel')
    assert jobs.get_job(job_id)['content_mode'] == 'novel'
    other = jobs.create_job('other', 'other.pdf', 'Other', '/tmp/other.pdf')
    assert jobs.get_job(other)['content_mode'] == 'illustrated'
    with pytest.raises(ValueError):
        jobs.create_job('bad', 'bad.pdf', 'Bad', '/tmp/bad.pdf', content_mode='invalid')


def test_novel_upload_round_trips_and_runner_passes_mode(tmp_path, monkeypatch):
    from fastapi.testclient import TestClient
    from server.main import app
    from server import job_runner
    from server.routes import jobs as routes
    monkeypatch.setattr(config, 'JOBS_DB_PATH', str(tmp_path / 'jobs.sqlite'))
    monkeypatch.setattr(config, 'UPLOAD_DIR', str(tmp_path / 'uploads'))
    monkeypatch.setattr(config, 'OUTPUT_DIR', str(tmp_path / 'output'))
    monkeypatch.setattr(job_runner, 'enqueue', lambda *a, **kw: None)
    client = TestClient(app)
    response = client.post('/books/upload', files={'file': ('story.pdf', b'%PDF-test', 'application/pdf')},
                           data={'content_mode': 'novel'})
    assert response.status_code == 200, response.text
    record = response.json()
    assert record['content_mode'] == 'novel'
    calls = []
    class Result:
        returncode = 0
    monkeypatch.setattr(job_runner.subprocess, 'run', lambda cmd, **kw: calls.append(cmd) or Result())
    job_runner._run_job(record['job_id'], [])
    assert calls[0][calls[0].index('--content-mode') + 1] == 'novel'
    assert routes._job_view(jobs.get_job(record['job_id']))['content_mode'] == 'novel'
    invalid = client.post('/books/upload', files={'file': ('bad.pdf', b'%PDF-test', 'application/pdf')},
                          data={'content_mode': 'bad'})
    assert invalid.status_code == 422


def test_chatterbox_style_changes_real_pcm_and_generation_controls(tmp_path, monkeypatch):
    """Use a deterministic tone stand-in, exercising actual WAV pitch processing."""
    import math
    import struct
    import sys
    import types
    import wave
    from firebrat.pipeline.tts import FirebratTTS
    calls = []
    class Model:
        def generate(self, text, exaggeration=0, cfg_weight=0):
            calls.append((text, exaggeration))
            return [math.sin(2 * math.pi * 220 * n / 24000) * 0.4 for n in range(24000)]
    def write(path, samples, rate):
        with wave.open(str(path), 'wb') as out:
            out.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
            out.writeframes(b''.join(struct.pack('<h', round(x * 32767)) for x in samples))
    monkeypatch.setitem(sys.modules, 'soundfile', types.SimpleNamespace(write=write))
    # Tensor detection should not require a heavyweight torch installation here.
    monkeypatch.setitem(sys.modules, 'torch', types.SimpleNamespace(Tensor=type('Tensor', (), {})))
    tts = FirebratTTS(device='cpu')
    tts._model = Model()
    neutral, styled = tmp_path / 'n.wav', tmp_path / 's.wav'
    assert tts.synthesize('Hello.', str(neutral))
    assert tts.synthesize('Hello.', str(styled), voice_style={'pitch_semitones': 2, 'exaggeration': 0.3})
    assert calls == [('Hello.', 0.4), ('Hello.', 0.3)]
    with wave.open(str(neutral)) as n, wave.open(str(styled)) as s:
        assert n.getnframes() == 24000
        assert 21000 < s.getnframes() < 22000
        assert s.getframerate() == 24000
        assert any(s.readframes(s.getnframes()))


def test_voice_gender_uses_explicit_text_not_names_and_conflicts_stay_unknown():
    raw = {'pages': [
        {'page_idx': 0, 'text': 'Alice was a boy. “Hello,” Alice said. “Hi,” Bob replied.'},
        {'page_idx': 1, 'text': 'Bob, a woman, opened the gate. “Come,” Bob said.'},
        {'page_idx': 2, 'text': '“Ann was a girl,” Ann said. “Go,” Chris said.'}]}
    result = compile_novel(raw)
    roster = {c['name']: c for c in result['character_roster']}
    assert roster['Alice']['voice_gender'] == 'male'
    assert roster['Alice']['voice_style']['pitch_semitones'] < 0
    assert roster['Bob']['voice_gender'] == 'female'
    assert roster['Bob']['voice_style']['pitch_semitones'] > 0
    assert roster['Ann']['voice_gender'] == roster['Chris']['voice_gender'] == 'unknown'
    assert roster['Bob']['voice_gender_evidence'][0]['page'] == 1
    raw['pages'].append({'page_idx': 3, 'text': 'Alice was a woman. “Wait,” Alice replied.'})
    conflicted = {c['name']: c for c in compile_novel(raw)['character_roster']}
    assert conflicted['Alice']['voice_gender'] == 'unknown'
    assert len(conflicted['Alice']['voice_gender_evidence']) == 2


def test_configured_character_references_and_missing_files(tmp_path):
    from firebrat.pipeline.tts import FirebratTTS
    narrator, male, female = (tmp_path / name for name in ('n.wav', 'm.wav', 'f.wav'))
    for reference in (narrator, male, female):
        reference.write_bytes(b'local-reference')
    tts = FirebratTTS(voice_ref=str(narrator), male_voice_ref=str(male), female_voice_ref=str(female))
    assert tts.reference_for_style({'voice_gender': 'male'}) == str(male)
    assert tts.reference_for_style({'voice_gender': 'female'}) == str(female)
    assert tts.reference_for_style({'voice_gender': 'unknown'}) == str(narrator)
    assert tts.reference_for_style() == str(narrator)
    fallback = FirebratTTS(voice_ref=str(narrator))
    assert fallback.reference_for_style({'voice_gender': 'female'}) == str(narrator)
    with pytest.raises(ValueError, match='existing local file'):
        FirebratTTS(male_voice_ref='https://example.com/voice.wav')

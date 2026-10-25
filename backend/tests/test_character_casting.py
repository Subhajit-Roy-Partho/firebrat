import pytest
from fastapi.testclient import TestClient

from firebrat.pipeline import character_traits as ct
from firebrat.pipeline.character_research import parse_traits_reply, research_characters
from firebrat.pipeline.novel import compile_novel
from server import config, job_runner, jobs
from server.main import app

PAGES = {'book_id': 'b', 'pages': [{'page_idx': 0, 'text':
         '“Come here,” Alice said. “Not now,” Bob replied. “Hurry,” Carol whispered. “Quiet,” Dan said.'}]}


def _by_name(compiled):
    return {c['name']: c for c in compiled['character_roster']}


def test_user_traits_shape_delivery_and_override_research():
    plain = _by_name(compile_novel(PAGES))
    compiled = compile_novel(
        PAGES,
        researched={'Bob': {**ct.unknown('web'), 'gender': 'male', 'age': 'young', 'temperament': 'cheerful'}},
        user_traits={'Bob': ct.parse_spec('elder gruff')[1], 'Dan': ct.parse_spec('child energetic')[1]})
    cast = _by_name(compiled)
    assert cast['Bob']['traits']['age'] == 'elder'           # user beats research
    assert cast['Bob']['voice_gender'] == 'male'             # research fills an unknown gender
    assert cast['Bob']['voice_style']['pitch_semitones'] < plain['Bob']['voice_style']['pitch_semitones']
    assert cast['Dan']['voice_style']['pitch_semitones'] > plain['Dan']['voice_style']['pitch_semitones']
    assert cast['Dan']['voice_style']['exaggeration'] == 0.65
    assert cast['Alice']['voice_style'] == plain['Alice']['voice_style']  # no traits: unchanged


def test_explicit_narration_gender_beats_research():
    pages = {'pages': [{'page_idx': 0, 'text': 'Bob was a man. “Hi,” Bob said.'}]}
    cast = _by_name(compile_novel(pages, researched={'Bob': {**ct.unknown('web'), 'gender': 'female'}}))
    assert cast['Bob']['voice_gender'] == 'male'


def test_reply_parsing_is_tolerant_and_vocabulary_checked():
    reply = ('Sure!\n```json\n{"alice":{"gender":"Female","age":"child","temperament":"cheerful"},'
             '"Bob":{"gender":"robot","age":"ancient","temperament":"grumpy"},"Zed":{"age":"elder"}}\n```')
    out = parse_traits_reply(reply, ['Alice', 'Bob'])
    assert list(out) == ['Alice'] and out['Alice']['gender'] == 'female'
    assert parse_traits_reply('no json', ['Alice']) == {}


class _Resp:
    def __init__(self, data):
        self._d = data

    def json(self):
        return self._d


class _Session:
    def __init__(self):
        self.calls = []

    def get(self, url, params=None, **kw):
        self.calls.append(params)
        if params.get('list') == 'search':
            return _Resp({'query': {'search': [{'title': 'A Test Novel'}]}})
        return _Resp({'query': {'pages': {'1': {'extract': 'Intro.\n== Characters ==\nAlice is a young girl. Bob is old.'}}}})


def test_research_sends_no_book_text_and_never_raises():
    sent = []

    def chat(messages):
        sent.append(messages)
        return '{"Alice":{"gender":"female","age":"child","temperament":"calm"}}'

    traits, report = research_characters('A Test Novel', ['Alice', 'Bob'], 'm', chat=chat, session=_Session())
    assert report['status'] == 'applied' and traits['Alice']['age'] == 'child'
    assert 'Come here' not in str(sent)

    def boom(messages):
        raise RuntimeError('provider down')

    traits, report = research_characters('A Test Novel', ['Alice'], 'm', chat=boom, session=_Session())
    assert traits == {} and report['status'] == 'skipped' and 'provider down' in report['reason']


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'UPLOAD_DIR', str(tmp_path / 'up'))
    monkeypatch.setattr(config, 'OUTPUT_DIR', str(tmp_path / 'out'))
    monkeypatch.setattr(config, 'JOBS_DB_PATH', str(tmp_path / 'jobs.sqlite3'))
    monkeypatch.setattr(job_runner, 'enqueue', lambda *a, **k: None)
    with TestClient(app) as client:
        yield client


def _upload(client, **form):
    return client.post('/books/upload', files={'file': ('story.pdf', b'%PDF-1.4 x', 'application/pdf')}, data=form)


def test_upload_stores_casting_options_and_validates_them(api):
    ok = _upload(api, content_mode='novel', research_characters='true',
                 character_traits='Bob=elder gruff\nAlice=child cheerful')
    assert ok.status_code == 200, ok.text
    view = ok.json()
    assert view['research_characters'] is True
    assert view['character_traits'] == 'Bob=elder gruff\nAlice=child cheerful'
    assert jobs.get_job(view['job_id'])['research_characters'] == 1

    assert _upload(api, content_mode='novel', character_traits='Bob=grumpy').status_code == 422
    assert _upload(api, content_mode='novel', character_traits='no equals sign').status_code == 422
    # Casting options only apply to novels.
    plain = _upload(api, content_mode='illustrated', research_characters='true', character_traits='Bob=elder')
    assert plain.status_code == 200
    assert plain.json()['research_characters'] is False and plain.json()['character_traits'] == ''


def test_trait_overrides_match_loosely_and_unmatched_are_reported(tmp_path):
    import json
    from firebrat.pipeline.novel import run_novel_compilation
    raw = tmp_path / 'raw_pages.json'
    raw.write_text(json.dumps({'pages': [{'page_idx': 0, 'text': '“Tea,” Hatter said. “Hmm,” Alice replied.'}]}))
    run_novel_compilation(str(raw), str(tmp_path), book_id='b',
                          trait_overrides={'mad hatter': 'elder gruff', 'Cheshire': 'mysterious'})
    compiled = json.loads((tmp_path / 'compiled.json').read_text())
    cast = {c['name']: c for c in compiled['character_roster']}
    assert cast['Hatter']['traits']['age'] == 'elder'
    assert compiled['unmatched_character_traits'] == ['Cheshire']

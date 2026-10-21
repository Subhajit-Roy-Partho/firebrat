import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import types
import urllib.error
import urllib.request

import pytest

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('desktop_launcher', HERE/'launcher.py')
launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(launcher)


def test_local_model_cannot_silently_route_to_cloud():
    value = launcher.validate_config({'mode':'local','model':'qwen3:4b-instruct','endpoint':'https://ignored.example','api_key':'ignored'})
    assert value['endpoint']=='http://127.0.0.1:11434/v1' and value['api_key']=='local'
    with pytest.raises(ValueError): launcher.validate_config({'mode':'local','model':'some-model:cloud'})


def test_api_key_not_reused_for_another_provider():
    old={'endpoint':'https://first.example/v1','api_key':'old-secret'}
    assert launcher.validate_config({'mode':'api','model':'large','endpoint':old['endpoint']},old)['api_key']=='old-secret'
    with pytest.raises(ValueError): launcher.validate_config({'mode':'api','model':'large','endpoint':'https://second.example/v1'},old)
    for url in ['http://example.com/v1','https://secret@example.com/v1','https://example.com/v1?key=abc']:
        with pytest.raises(ValueError): launcher.validate_config({'mode':'api','model':'large','endpoint':url,'api_key':'key'})


def test_configuration_private_and_environment_isolated(tmp_path,monkeypatch):
    c=launcher.Controller(tmp_path,bundle=HERE)
    c.save({'mode':'api','model':'large','endpoint':'https://example.com/v1','api_key':'private-secret','accelerator':'cpu'})
    assert c.config_path.stat().st_mode & 0o777 == 0o600
    assert 'private-secret' not in json.dumps(c.status())
    monkeypatch.setenv('NANO_API_KEY','unrelated-key');monkeypatch.setenv('TELEGRAM_BOT_TOKEN','unrelated-notification')
    env=c.environment()
    assert 'NANO_API_KEY' not in env and 'TELEGRAM_BOT_TOKEN' not in env
    assert env['MODEL_API_KEY']=='private-secret' and env['FIREBRAT_TTS_DEVICE']=='cpu'
    assert env['FIREBRAT_HOST']=='127.0.0.1'


def upload_request(data,filename='chapter.pdf'):
    boundary=b'fixture-boundary'
    body=b'--'+boundary+b'\r\nContent-Disposition: form-data; name="book"; filename="'+filename.encode()+b'"\r\nContent-Type: application/pdf\r\n\r\n'+data+b'\r\n--'+boundary+b'--\r\n'
    class BoundedReader(io.BytesIO):
        def read(self,size=-1):
            assert 0<=size<=65536
            return super().read(size)
    return types.SimpleNamespace(headers={'Content-Type':'multipart/form-data; boundary='+boundary.decode(),'Content-Length':str(len(body))},rfile=BoundedReader(body))


def test_upload_streams_and_does_not_trust_filename(tmp_path):
    path=tmp_path/'owned.pdf'; data=b'%PDF-1.7\n'+b'x'*3_000_000
    assert launcher.receive_upload(upload_request(data,'../../chapter.pdf'),path)=='chapter'
    assert path.read_bytes()==data
    assert not (tmp_path.parent/'chapter.pdf').exists()


def test_invalid_or_truncated_upload_is_removed(tmp_path):
    dest=tmp_path/'book.pdf'
    with pytest.raises(ValueError): launcher.receive_upload(upload_request(b'not a PDF'),dest)
    assert not dest.exists()
    request=upload_request(b'%PDF-1.7\ntext');request.headers['Content-Length']=str(launcher.MAX_UPLOAD+1)
    with pytest.raises(ValueError): launcher.receive_upload(request,dest)


def test_browser_control_requires_token_and_same_origin(tmp_path,monkeypatch):
    monkeypatch.setattr(launcher,'hardware',lambda:{})
    server=launcher.ThreadingHTTPServer(('127.0.0.1',0),launcher.Handler)
    server.token='test-token';server.controller=launcher.Controller(tmp_path,bundle=HERE)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    base='http://127.0.0.1:'+str(server.server_port)
    try:
        with pytest.raises(urllib.error.HTTPError) as rejected: urllib.request.urlopen(base+'/status')
        assert rejected.value.code==403
        request=urllib.request.Request(base+'/status',headers={'X-Firebrat-Token':'test-token','Origin':'https://attacker.example'})
        with pytest.raises(urllib.error.HTTPError): urllib.request.urlopen(request)
        request=urllib.request.Request(base+'/status',headers={'X-Firebrat-Token':'test-token'})
        with urllib.request.urlopen(request) as response: assert json.load(response)['config']=={}
        request=urllib.request.Request(base+'/status',headers={'X-Firebrat-Token':'test-token','Host':'attacker.example'})
        with pytest.raises(urllib.error.HTTPError): urllib.request.urlopen(request)
    finally: server.shutdown();server.server_close();thread.join()


def test_stop_terminates_only_owned_child(tmp_path):
    c=launcher.Controller(tmp_path,bundle=HERE)
    child=c.spawn([sys.executable,'-c','import time;time.sleep(60)'])
    c.stop()
    assert child.poll() is not None


@pytest.mark.parametrize('available,expected',[(False,'cpu'),(True,'cuda')])
def test_speech_selects_local_cpu_or_cuda(available,expected,tmp_path,monkeypatch):
    tts_spec=importlib.util.spec_from_file_location('local_tts',HERE.parents[1]/'backend/firebrat/pipeline/tts.py')
    module=importlib.util.module_from_spec(tts_spec);tts_spec.loader.exec_module(module)
    captured=[]
    class FakeTTS:
        @staticmethod
        def from_pretrained(device): captured.append(device);return types.SimpleNamespace(sr=24000)
    monkeypatch.setitem(sys.modules,'torch',types.SimpleNamespace(cuda=types.SimpleNamespace(is_available=lambda:available)))
    monkeypatch.setitem(sys.modules,'chatterbox',types.ModuleType('chatterbox'))
    monkeypatch.setitem(sys.modules,'chatterbox.tts',types.SimpleNamespace(ChatterboxTTS=FakeTTS))
    monkeypatch.setenv('FIREBRAT_TTS_DEVICE','auto');monkeypatch.setenv('HF_HOME',str(tmp_path))
    model=module.FirebratTTS();model.load()
    assert captured==[expected]


def test_cached_local_model_start_does_not_require_a_pull(tmp_path,monkeypatch):
    c=launcher.Controller(tmp_path,bundle=HERE)
    c.save({'mode':'local','model':'qwen3:4b-instruct'})
    monkeypatch.setattr(launcher.shutil,'which',lambda _: '/fake/ollama')
    monkeypatch.setattr(c,'responds',lambda _:True)
    monkeypatch.setattr(launcher.subprocess,'run',lambda *args,**kwargs:types.SimpleNamespace(returncode=0))
    commands=[];monkeypatch.setattr(c,'run',lambda command:commands.append(command))
    c.prepare_llm()
    assert all('pull' not in command for command in commands)
    assert commands[0][1:3]==['create','firebrat-qwen3-4b-instruct']
    assert 'num_ctx 16384' in (tmp_path/'Ollama.Modelfile').read_text()


def test_container_uses_baked_runtimes_without_native_bootstrap(tmp_path, monkeypatch):
    monkeypatch.setenv('FIREBRAT_DESKTOP_PREINSTALLED','1')
    c = launcher.Controller(tmp_path, bundle=HERE)
    assert str(c.source) == '/app/backend'
    assert c.python('tts') == '/opt/venvs/tts/bin/python'
    c.config = {'mode':'local','model':'qwen3:4b-instruct'}
    monkeypatch.setattr(c, 'run', lambda *args: pytest.fail('Container must not install Python dependencies'))
    c.setup()
    assert 'installed in the image' in c.stage
    assert c.environment()['FIREBRAT_TTS_PY'] == '/opt/venvs/tts/bin/python'
    assert c.environment()['OLLAMA_NO_CLOUD'] == '1'

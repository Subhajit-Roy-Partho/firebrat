"""Real container startup without downloading weights or calling an LLM API."""
import tempfile
from launcher import Controller

with tempfile.TemporaryDirectory() as root:
    controller = Controller(root)
    assert controller.runtime_ready()
    controller.save({'mode': 'api', 'model': 'unused-smoke-model',
                     'endpoint': 'https://example.invalid/v1',
                     'api_key': 'unused-smoke-key', 'accelerator': 'cpu'})
    try:
        controller.start()
        assert controller.responds('http://127.0.0.1:8000/health')
        assert not controller.responds('http://127.0.0.1:8000/desktop/jobs/invalid')
        print('Container runtime, API startup, and protected control route passed')
    finally:
        controller.stop()

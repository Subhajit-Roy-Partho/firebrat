"""FIREBRAT_MAX_CONCURRENT_JOBS caps how many conversions overlap.

Each case runs in its own interpreter: the worker pool is a process-global
that starts once, so an in-process test would inherit workers from other
tests and measure the wrong thing.
"""
import os
import subprocess
import sys
import textwrap

import pytest

_BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

_SCRIPT = textwrap.dedent('''
    import json, os, sys, time
    work = sys.argv[1]
    fake = os.path.join(work, "fake_convert.py")
    open(fake, "w").write("""
    import json, os, sys, time
    a = sys.argv
    book = a[a.index("--book-id") + 1]
    out = a[a.index("--output") + 1]
    path = os.path.join(os.environ["EVENT_LOG"], book + ".json")
    start = time.time()
    time.sleep(1.0)
    with open(path, "w") as f:
        json.dump({"start": start, "end": time.time()}, f)
    os.makedirs(os.path.join(out, book), exist_ok=True)
    """)
    os.makedirs(os.path.join(work, "events"), exist_ok=True)
    os.environ["EVENT_LOG"] = os.path.join(work, "events")
    import server.config as cfg
    cfg.OUTPUT_DIR = os.path.join(work, "out")
    cfg.UPLOAD_DIR = os.path.join(work, "up")
    cfg.JOBS_DB_PATH = os.path.join(work, "jobs.sqlite3")
    cfg.CONVERT_PY = sys.executable
    cfg.CONVERT_SCRIPT = fake
    os.makedirs(cfg.OUTPUT_DIR, exist_ok=True)
    from server import auth
    from server.main import app
    app.dependency_overrides[auth.require_user] = lambda: {"uid": "u", "email": "u@x"}
    from fastapi.testclient import TestClient
    with TestClient(app) as client:
        ids = []
        for i in range(4):
            r = client.post("/books/upload", files={"file": (f"book{i}.pdf", b"%PDF-1.4 x", "application/pdf")})
            assert r.status_code == 200, r.text
            ids.append(r.json()["job_id"])
        deadline = time.time() + 30
        while time.time() < deadline:
            states = [client.get(f"/jobs/{j}").json()["state"] for j in ids]
            if all(s in ("done", "failed") for s in states):
                break
            time.sleep(0.2)
        spans = []
        for i in range(4):
            e = json.load(open(os.path.join(work, "events", f"book{i}.json")))
            spans.append((e["start"], e["end"]))
        peak = max(sum(1 for s, e in spans if s <= t < e) for t, _ in spans)
        print(json.dumps({"limit": cfg.MAX_CONCURRENT_JOBS, "peak": peak}))
''')


@pytest.mark.parametrize("env_value,expected_limit", [
    ("2", 2),
    ("1", 1),
    ("not-a-number", 1),
    ("0", 1),
])
def test_concurrency_cap_is_respected(tmp_path, env_value, expected_limit):
    script = tmp_path / "run.py"
    script.write_text(_SCRIPT)
    env = dict(os.environ, FIREBRAT_MAX_CONCURRENT_JOBS=env_value,
               PYTHONPATH=_BACKEND + os.pathsep + os.environ.get("PYTHONPATH", ""))
    proc = subprocess.run([sys.executable, str(script), str(tmp_path)], cwd=_BACKEND,
                          env=env, capture_output=True, text=True, timeout=90)
    assert proc.returncode == 0, proc.stderr[-2000:]
    import json
    result = json.loads(proc.stdout.strip().splitlines()[-1])
    assert result["limit"] == expected_limit
    assert result["peak"] == expected_limit

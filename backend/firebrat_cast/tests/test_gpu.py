"""gpu.py tests: all offline (torch/nvidia-smi monkeypatched or absent)."""
import os

import firebrat_cast.gpu as gpu


def test_free_vram_returns_none_or_float():
    v = gpu.free_vram_gb()
    assert v is None or (isinstance(v, float) and v >= 0.0)


def test_ensure_free_ok_when_plenty(monkeypatch):
    monkeypatch.setattr(gpu, "free_vram_gb", lambda: 14.0)
    assert gpu.ensure_free(10.0) == 14.0


def test_ensure_free_raises_naming_holder(monkeypatch):
    monkeypatch.setattr(gpu, "free_vram_gb", lambda: 1.5)
    monkeypatch.setattr(gpu, "gpu_holders",
                        lambda: [{"pid": 1234, "name": "python", "used_mib": 13000.0}])
    try:
        gpu.ensure_free(10.0)
    except RuntimeError as e:
        msg = str(e)
        assert "10.0" in msg and "1.5" in msg
        assert "1234" in msg and "python" in msg
        assert "never kills" in msg
    else:
        raise AssertionError("ensure_free should raise when VRAM is short")


def test_ensure_free_no_gpu_warns_only(monkeypatch):
    monkeypatch.setattr(gpu, "free_vram_gb", lambda: None)
    assert gpu.ensure_free(10.0) is None


def test_wait_for_vram_success(monkeypatch):
    monkeypatch.setattr(gpu, "ensure_free", lambda min_gb=10.0: 12.0)
    assert gpu.wait_for_vram(10.0, timeout_s=5) is True


def test_wait_for_vram_timeout(monkeypatch):
    monkeypatch.setattr(gpu, "ensure_free", lambda min_gb=10.0: (_ for _ in ()).throw(RuntimeError("busy")))
    assert gpu.wait_for_vram(10.0, timeout_s=0.05, poll_s=0.01) is False


def test_gpu_lock_exclusive(tmp_path):
    path = str(tmp_path / "gpu.lock")
    a = gpu.GpuLock(path, timeout_s=5)
    b = gpu.GpuLock(path, timeout_s=0.05)
    a.acquire()
    try:
        try:
            b.acquire()
        except TimeoutError:
            pass
        else:
            raise AssertionError("second lock should time out while first is held")
    finally:
        a.release()
    b.acquire()  # releasable and re-acquirable
    b.release()


def test_gpu_lock_context_manager(tmp_path):
    with gpu.GpuLock(str(tmp_path / "gpu.lock")):
        assert os.path.isfile(str(tmp_path / "gpu.lock"))


def test_gpu_stage_runs_body(tmp_path):
    ran = []
    with gpu.gpu_stage("test", min_gb=0.0, lock_path=str(tmp_path / "gpu.lock")):
        ran.append(True)
    assert ran == [True]

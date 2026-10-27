"""GPU lease helpers: VRAM inspection, single-stage file lock, free-VRAM guard.

Only ONE large model is resident on the GPU at a time (LLM for casting, then
TTS). These helpers let the queue runner enforce that without ever killing
processes: if VRAM is short, raise a clear error naming the holder.
"""
from __future__ import annotations

import contextlib
import logging
import os
import subprocess
import tempfile
import time
from typing import Iterator

log = logging.getLogger(__name__)

LOCK_ENV = "FIREBRAT_CAST_GPU_LOCK"
_DEFAULT_MIN_GB = 10.0


def default_lock_path() -> str:
    """Filesystem lock so only one GPU stage runs at once."""
    return os.environ.get(LOCK_ENV, os.path.join(tempfile.gettempdir(), "firebrat_cast_gpu.lock"))


def _nvidia_smi(*args: str) -> str | None:
    try:
        out = subprocess.run(["nvidia-smi", *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip()


def free_vram_gb() -> float | None:
    """Free VRAM in GiB (minimum across GPUs). None when no GPU is visible."""
    try:
        import torch

        if torch.cuda.is_available():
            # torch reports bytes; take the tightest device.
            free = min(f for f, _ in (torch.cuda.mem_get_info(i) for i in range(torch.cuda.device_count())))
            return free / (1024 ** 3)
    except ImportError:
        pass
    except Exception as e:  # torch present but unusable (e.g. no driver)
        log.warning("torch.cuda query failed, trying nvidia-smi: %s", e)
    out = _nvidia_smi("--query-gpu=memory.free", "--format=csv,noheader,nounits")
    if not out:
        return None
    try:
        return min(float(line.split()[0]) for line in out.splitlines() if line.strip()) / 1024.0
    except ValueError:
        return None


def gpu_holders() -> list[dict]:
    """Processes currently holding VRAM: [{pid, name, used_mib}]. Empty if none/unknown."""
    out = _nvidia_smi("--query-compute-apps=pid,process_name,used_memory", "--format=csv,noheader,nounits")
    holders: list[dict] = []
    if not out:
        return holders
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 3:
            continue
        try:
            holders.append({"pid": int(parts[0]), "name": parts[1], "used_mib": float(parts[2])})
        except ValueError:
            continue
    return holders


def ensure_free(min_gb: float = _DEFAULT_MIN_GB) -> float | None:
    """Return free GiB, or raise naming the VRAM holder. Never kills processes.

    Returns None (with a warning) when no GPU is visible, so CPU-only unit
    tests and external-LLM runs don't fail here.
    """
    free = free_vram_gb()
    if free is None:
        log.warning("No GPU visible; skipping VRAM check (need %.1f GiB)", min_gb)
        return None
    if free >= min_gb:
        return free
    holders = gpu_holders()
    who = ", ".join(f"{h['name']} (pid {h['pid']}, {h['used_mib']:.0f} MiB)" for h in holders) or "unknown process"
    raise RuntimeError(
        f"Need {min_gb:.1f} GiB free VRAM but only {free:.1f} GiB is free; "
        f"held by {who}. Unload/stop that process first — this check never kills anything."
    )


def wait_for_vram(min_gb: float = _DEFAULT_MIN_GB, timeout_s: float = 600.0, poll_s: float = 15.0) -> bool:
    """Poll until min_gb is free. True on success, False on timeout."""
    deadline = time.monotonic() + timeout_s
    while True:
        try:
            free = ensure_free(min_gb)
            if free is None:  # no GPU visible: nothing to wait for
                return True
            return True
        except RuntimeError:
            if time.monotonic() >= deadline:
                return False
            time.sleep(min(poll_s, max(0.0, deadline - time.monotonic())))


class GpuLock:
    """Exclusive inter-process file lock: only one GPU stage at a time."""

    def __init__(self, path: str | None = None, timeout_s: float = 3600.0, poll_s: float = 1.0):
        self.path = path or default_lock_path()
        self.timeout_s = timeout_s
        self.poll_s = poll_s
        self._fh = None

    def acquire(self) -> None:
        try:
            import fcntl
        except ImportError:  # pragma: no cover — Windows fallback
            fcntl = None  # type: ignore
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        fh = open(self.path, "w")
        if fcntl is None:
            self._fh = fh
            return
        deadline = time.monotonic() + self.timeout_s
        while True:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                self._fh = fh
                fh.write(f"{os.getpid()}\n")
                fh.flush()
                return
            except OSError:
                if time.monotonic() >= deadline:
                    fh.close()
                    raise TimeoutError(f"Timed out waiting for GPU lock {self.path}")
                time.sleep(self.poll_s)

    def release(self) -> None:
        fh, self._fh = self._fh, None
        if fh is None:
            return
        try:
            import fcntl

            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except ImportError:
            pass
        finally:
            fh.close()

    def __enter__(self) -> "GpuLock":
        self.acquire()
        return self

    def __exit__(self, *exc: object) -> None:
        self.release()


@contextlib.contextmanager
def gpu_stage(name: str = "gpu", min_gb: float = 0.0, lock_path: str | None = None,
              wait_s: float = 12 * 3600.0, poll_s: float = 30.0) -> Iterator[None]:
    """Hold the GPU lock for one stage, first waiting (up to wait_s) until min_gb of VRAM is free.

    Another job (never killed by us) may hold the card; the stage simply queues behind it."""
    with GpuLock(lock_path):
        if min_gb > 0:
            deadline = time.monotonic() + wait_s
            last_log = 0.0
            while True:
                try:
                    ensure_free(min_gb)
                    break
                except RuntimeError as e:
                    if time.monotonic() >= deadline:
                        raise
                    if time.monotonic() - last_log > 300:
                        log.info("GPU stage %s waiting for VRAM: %s", name, e)
                        last_log = time.monotonic()
                    time.sleep(poll_s)
        log.info("GPU stage started: %s", name)
        try:
            yield
        finally:
            log.info("GPU stage finished: %s", name)

"""Audio helpers."""
import os
import shutil

FFMPEG_CANDIDATES = [
    "/packages/apps/spack/21.2/opt/spack/x86_64_v3/gcc-12.3.0/ffmpeg-6.0-2ac3emh/bin/ffmpeg",
    shutil.which("ffmpeg"),
]

def find_ffmpeg() -> str | None:
    for c in FFMPEG_CANDIDATES:
        if c and os.path.isfile(c):
            return c
    return shutil.which("ffmpeg")


def wav_duration_ms(path: str) -> int:
    import soundfile as sf
    data, sr = sf.read(path)
    return int(len(data) / sr * 1000)


def ensure_silence(duration_ms: int, sample_rate: int = 24000):
    from pydub import AudioSegment
    return AudioSegment.silent(duration=duration_ms, frame_rate=sample_rate)

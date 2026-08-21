"""Unit tests for audio assembly cursor bookkeeping — no ffmpeg or torch needed."""

def test_compute_timeline_basic(tmp_path):
    from pydub import AudioSegment
    from firebrat.pipeline.audio_assemble import compute_timeline
    import os
    # Create two tiny silent wavs with known durations
    sr = 24000
    wav1 = os.path.join(tmp_path, "seg1.wav")
    wav2 = os.path.join(tmp_path, "seg2.wav")
    AudioSegment.silent(duration=1000, frame_rate=sr).export(wav1, format="wav")
    AudioSegment.silent(duration=800, frame_rate=sr).export(wav2, format="wav")

    segments = [
        {"segment_id": "sec_0001_seg_001", "type": "prose", "text": "a", "ref": None, "visually_essential": False},
        {"segment_id": "sec_0001_seg_002", "type": "prose", "text": "b", "ref": None, "visually_essential": False},
    ]
    wav_paths = {"sec_0001_seg_001": wav1, "sec_0001_seg_002": wav2}
    timed, total = compute_timeline(segments, wav_paths, pause_ms=220)
    assert timed[0]["start_ms"] == 0
    assert timed[0]["end_ms"] == 1000
    assert timed[1]["start_ms"] == 1220  # 1000 + 220 pause
    assert timed[1]["end_ms"] == 2020
    assert total == 2020

import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/tts/wav_utils.dart';

/// Builds a minimal 16-bit mono PCM WAV file in memory, for round-trip
/// testing without needing a real audio file on disk.
Uint8List _makeWav({required int sampleRate, required int frameCount, int fillByte = 1}) {
  final pcm = Uint8List(frameCount * 2)..fillRange(0, frameCount * 2, fillByte);
  return WavAudio(sampleRate: sampleRate, channels: 1, bitsPerSample: 16, pcmData: pcm).toBytes();
}

void main() {
  test('round-trips a synthetic WAV file (write then parse)', () {
    final bytes = _makeWav(sampleRate: 22050, frameCount: 22050); // exactly 1 second
    final parsed = WavAudio.parse(bytes);
    expect(parsed.sampleRate, 22050);
    expect(parsed.channels, 1);
    expect(parsed.bitsPerSample, 16);
    expect(parsed.frameCount, 22050);
    expect(parsed.durationMs, 1000);
  });

  test('rejects a non-WAV buffer', () {
    expect(() => WavAudio.parse(Uint8List.fromList([1, 2, 3, 4])), throwsFormatException);
  });

  test('concatenation produces sample-accurate, non-overlapping timing', () {
    final clip1 = WavAudio.parse(_makeWav(sampleRate: 22050, frameCount: 11025)); // 500ms
    final clip2 = WavAudio.parse(_makeWav(sampleRate: 22050, frameCount: 22050)); // 1000ms
    final clip3 = WavAudio.parse(_makeWav(sampleRate: 22050, frameCount: 5512)); // ~250ms

    final result = WavAudio.concatenate([clip1, clip2, clip3], pauseMs: 260);

    expect(result.timing, hasLength(3));
    expect(result.timing[0].startMs, 0);
    expect(result.timing[0].endMs, 500);
    // clip2 starts after clip1 ends + the 260ms pause
    expect(result.timing[1].startMs, 500 + 260);
    expect(result.timing[1].endMs, 500 + 260 + 1000);
    expect(result.timing[2].startMs, result.timing[1].endMs + 260);

    // no two segments overlap, and each is strictly increasing
    for (var i = 1; i < result.timing.length; i++) {
      expect(result.timing[i].startMs, greaterThanOrEqualTo(result.timing[i - 1].endMs));
    }

    // combined audio's own PCM length matches all three clips + two pauses
    final expectedFrames = 11025 + 22050 + 5512 + (2 * (22050 * 260 ~/ 1000));
    expect(result.combined.frameCount, expectedFrames);
  });

  test('concatenating a single clip returns it with zero-based timing', () {
    final clip = WavAudio.parse(_makeWav(sampleRate: 16000, frameCount: 8000)); // 500ms
    final result = WavAudio.concatenate([clip]);
    expect(result.timing, [(startMs: 0, endMs: 500)]);
  });

  test('a written-then-parsed WAV survives a full round trip through concatenate', () {
    final clip = WavAudio.parse(_makeWav(sampleRate: 24000, frameCount: 2400, fillByte: 42));
    final result = WavAudio.concatenate([clip, clip]);
    final reparsed = WavAudio.parse(result.combined.toBytes());
    expect(reparsed.sampleRate, 24000);
    expect(reparsed.frameCount, result.combined.frameCount);
  });
}

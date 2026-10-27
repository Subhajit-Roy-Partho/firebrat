import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/src/tts/audio_trim.dart';

Float32List tone(int sr, double seconds, {double amp = 0.3}) =>
    Float32List.fromList([for (var i = 0; i < (sr * seconds).round(); i++) amp * math.sin(2 * math.pi * 220 * i / sr)]);

void main() {
  const sr = 24000;
  test('removes long silent head and tail but keeps a short margin', () {
    final audio = Float32List.fromList([...Float32List(sr), ...tone(sr, 1), ...Float32List(sr * 3 ~/ 4)]);
    final out = trimSilence(audio, sr);
    final seconds = out.length / sr;
    expect(seconds, greaterThan(1.0)); // never shorter than the speech
    expect(seconds, lessThan(1.2)); // 30 ms head + 90 ms tail (+ window slack)
  });

  test('speech is never clipped', () {
    final speech = tone(sr, 0.5);
    final out = trimSilence(Float32List.fromList([...Float32List(5000), ...speech, ...Float32List(20000)]), sr);
    final peak = out.fold<double>(0, (m, v) => math.max(m, v.abs()));
    expect(peak, closeTo(0.3, 0.01));
    expect(out.length, greaterThanOrEqualTo(speech.length));
  });

  test('all-silent audio becomes empty and short audio is untouched', () {
    expect(trimSilence(Float32List(sr), sr), isEmpty);
    final tiny = Float32List(10);
    expect(trimSilence(tiny, sr).length, 10);
  });

  test('silenceSamples length', () => expect(silenceSamples(sr, 170).length, 4080));
}

import 'dart:math' as math;
import 'dart:typed_data';

/// Removes the near-silent head and tail that Kokoro/Piper leave around every
/// generated sentence. Without it each sentence carried ~0.7 s of dead air, so a
/// third of a short chapter was silence. Windows are 10 ms RMS; [headMs] /
/// [tailMs] of the quiet edge are kept so words are never clipped.
Float32List trimSilence(
  Float32List audio,
  int sampleRate, {
  double thresholdDb = -45,
  int headMs = 30,
  int tailMs = 90,
}) {
  final win = math.max(1, sampleRate ~/ 100);
  if (audio.length < win * 2) return audio;
  final threshold = math.pow(10, thresholdDb / 20).toDouble();
  bool loud(int start) {
    final end = math.min(audio.length, start + win);
    var sum = 0.0;
    for (var i = start; i < end; i++) {
      sum += audio[i] * audio[i];
    }
    return math.sqrt(sum / (end - start)) >= threshold;
  }

  var first = -1;
  for (var i = 0; i < audio.length; i += win) {
    if (loud(i)) {
      first = i;
      break;
    }
  }
  if (first < 0) return Float32List(0); // all silence
  var last = first;
  for (var i = ((audio.length - 1) ~/ win) * win; i >= first; i -= win) {
    if (loud(i)) {
      last = math.min(audio.length, i + win);
      break;
    }
  }
  final start = math.max(0, first - headMs * sampleRate ~/ 1000);
  final end = math.min(audio.length, last + tailMs * sampleRate ~/ 1000);
  return Float32List.sublistView(audio, start, end);
}

/// Silence of [ms] milliseconds at [sampleRate].
Float32List silenceSamples(int sampleRate, int ms) => Float32List(sampleRate * ms ~/ 1000);

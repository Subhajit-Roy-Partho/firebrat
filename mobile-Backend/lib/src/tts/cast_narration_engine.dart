import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../cast/cast_plan.dart';
import '../cast/cast_voices.dart';
import '../models/compiled_models.dart';
import '../models/segment_models.dart';
import '../util/ids.dart';
import 'narration_engine.dart';
import 'speech_backend.dart';
import 'wav_utils.dart';

/// Narrates a cast novel: every quote in its character's voice, emotion-aware
/// delivery (tempo, pauses, loudness, light pitch) from [kEmotionDelivery],
/// the narrator for everything else. Produces the standard section audio
/// (16-bit WAV) and `segments.json`, so every client plays it unchanged.
class CastNarrationEngine implements NarrationEngine {
  final SpeechBackend backend;
  final CastPlan plan;
  final double baseSpeed;

  /// Silence when the speaker changes / stays the same between two lines.
  final int speakerChangePauseMs;
  final int sameSpeakerPauseMs;
  CastNarrationEngine({
    required this.backend,
    required this.plan,
    this.baseSpeed = 1.0,
    this.speakerChangePauseMs = 170,
    this.sameSpeakerPauseMs = 70,
  });

  @override
  Future<({String audioPath, SegmentsFile segmentsFile})> narrateSection({
    required String sectionId,
    required List<CompiledSegment> segments,
    required String sectionDir,
    int pauseMs = 260,
    List<int> sourcePages = const [],
  }) async {
    await Directory(sectionDir).create(recursive: true);
    final page = sourcePages.isEmpty ? -1 : sourcePages.first;
    final clips = <WavAudio>[];
    final segmentIds = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segmentId = makeSegmentId(sectionId, i);
      segmentIds.add(segmentId);
      final lines = page >= 0
          ? plan.linesForPage(page, segments[i].text)
          : [PlannedLine(segments[i].text, 'narrator', plan.narratorVoice, 1.0, 0.0, const Delivery())];
      final parts = <Float32List>[];
      String? lastSpeaker;
      for (final line in lines) {
        if (line.text.trim().isEmpty) continue;
        final audio = await speakLine(line);
        if (audio.isEmpty) continue;
        if (lastSpeaker != null) {
          parts.add(silence(lastSpeaker == line.speakerId ? sameSpeakerPauseMs : speakerChangePauseMs));
        }
        if (line.delivery.preMs > 0) parts.add(silence(line.delivery.preMs));
        parts.add(audio);
        if (line.delivery.postMs > 0) parts.add(silence(line.delivery.postMs));
        lastSpeaker = line.speakerId;
      }
      if (parts.isEmpty) throw StateError('No narration for $segmentId');
      clips.add(WavAudio(sampleRate: backend.sampleRate, channels: 1, bitsPerSample: 16, pcmData: toPcm16(parts)));
    }
    final (:combined, :timing) = WavAudio.concatenate(clips, pauseMs: pauseMs);
    final audioPath = '$sectionDir/audio.wav';
    await File(audioPath).writeAsBytes(combined.toBytes());
    return (
      audioPath: audioPath,
      segmentsFile: SegmentsFile(
        sectionId: sectionId,
        sampleRate: combined.sampleRate,
        pauseMsBetweenSegments: pauseMs,
        segments: [
          for (var i = 0; i < segments.length; i++)
            TimedSegment(
              segmentId: segmentIds[i],
              index: i,
              type: segments[i].type,
              text: segments[i].text,
              ref: segments[i].ref,
              startMs: timing[i].startMs,
              endMs: timing[i].endMs,
              visuallyEssential: segments[i].visuallyEssential,
            ),
        ],
      ),
    );
  }

  /// One line with its delivery applied. The engine's `speed` is divided by the
  /// pitch ratio first, because shifting pitch by resampling also changes tempo.
  Future<Float32List> speakLine(PlannedLine line) async {
    final d = line.delivery;
    final semis = (d.semitones + line.semitones).clamp(-3.0, 3.0).toDouble();
    final ratio = ratioForSemitones(semis);
    final speed = (baseSpeed * line.speedMul * d.speed / ratio).clamp(0.5, 1.8).toDouble();
    final raw = await backend.speak(line.text, voice: line.voice, speed: speed);
    if (raw.isEmpty) return raw;
    if (d.gainDb == 0 && semis == 0) return raw;
    return Float32List.fromList(applyGainAndPitch(raw, gainDb: d.gainDb, semitones: semis));
  }

  Float32List silence(int ms) => Float32List(backend.sampleRate * ms ~/ 1000);

  @override
  void dispose() {
    backend.dispose();
  }
}

double ratioForSemitones(double semitones) => semitones == 0 ? 1.0 : math.pow(2, semitones / 12).toDouble();

/// float [-1, 1] parts -> concatenated little-endian 16-bit PCM.
Uint8List toPcm16(List<Float32List> parts) {
  final total = parts.fold<int>(0, (a, p) => a + p.length);
  final out = Uint8List(total * 2);
  final view = ByteData.view(out.buffer);
  var o = 0;
  for (final p in parts) {
    for (var i = 0; i < p.length; i++) {
      final v = p[i];
      final c = v.isNaN ? 0.0 : (v > 1 ? 1.0 : (v < -1 ? -1.0 : v));
      view.setInt16(o, (c * 32767).round(), Endian.little);
      o += 2;
    }
  }
  return out;
}

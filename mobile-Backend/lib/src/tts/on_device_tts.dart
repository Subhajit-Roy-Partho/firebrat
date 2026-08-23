import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/segment_models.dart';
import '../models/compiled_models.dart';
import '../util/ids.dart';
import 'caf_utils.dart';
import 'wav_utils.dart';

/// Narrates one section's segments using the platform's built-in TTS
/// engine (Android `TextToSpeech`, iOS `AVSpeechSynthesizer`), assembling
/// one combined audio file + sample-accurate `segments.json` per section —
/// the same on-disk shape `docs/DATA_SCHEMA.md` describes, just produced
/// by a different narrator engine (fixed stock voice, no cloning — see
/// `mobile-Backend/PROPOSAL.md` §1c for why voice cloning isn't attempted
/// on-device here).
///
/// Android path (WAV) is the one this package can reason about with any
/// confidence; the iOS path (CAF) is implemented but explicitly
/// unverified — see `caf_utils.dart`'s doc comment. Both run through the
/// same [WavAudio] assembly code once parsed, so a CAF-parsing bug would
/// affect only iOS output, not Android's.
class OnDeviceTts {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.48); // flutter_tts rate is 0.0-1.0; ~0.48 reads as a natural, not-rushed pace
    await _tts.awaitSpeakCompletion(true);
    _configured = true;
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// Synthesizes [segments] to one combined audio file under [sectionDir],
  /// returning the [SegmentsFile] with real sample-accurate timing.
  /// Segments whose synthesis fails are still included with an estimated
  /// duration (silence) so one bad segment can't sink the whole section —
  /// mirrors `audio_assemble.py`'s fallback-duration behavior server-side.
  Future<({String audioPath, SegmentsFile segmentsFile})> narrateSection({
    required String sectionId,
    required List<CompiledSegment> segments,
    required String sectionDir,
    int pauseMs = 260,
  }) async {
    await _ensureConfigured();
    await Directory(sectionDir).create(recursive: true);

    final clips = <WavAudio>[];
    final segmentIds = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segmentId = makeSegmentId(sectionId, i);
      segmentIds.add(segmentId);
      final ext = _isAndroid ? 'wav' : 'caf';
      final path = '$sectionDir/_seg_$segmentId.$ext';
      try {
        await _tts.synthesizeToFile(segments[i].text, path, true);
        final bytes = await File(path).readAsBytes();
        clips.add(_isAndroid ? WavAudio.parse(bytes) : CafAudio.parse(bytes));
      } catch (_) {
        // Fallback: 600ms of silence at a nominal rate, so this segment
        // still has a slot in the timeline instead of vanishing.
        clips.add(WavAudio(sampleRate: 22050, channels: 1, bitsPerSample: 16, pcmData: _silencePcm(22050, 600)));
      } finally {
        final f = File(path);
        if (await f.exists()) await f.delete();
      }
    }

    final (:combined, :timing) = WavAudio.concatenate(clips, pauseMs: pauseMs);
    final audioPath = '$sectionDir/audio.wav';
    await File(audioPath).writeAsBytes(combined.toBytes());

    final timedSegments = <TimedSegment>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      timedSegments.add(TimedSegment(
        segmentId: segmentIds[i],
        index: i,
        type: seg.type,
        text: seg.text,
        ref: seg.ref,
        startMs: timing[i].startMs,
        endMs: timing[i].endMs,
        visuallyEssential: seg.visuallyEssential,
      ));
    }

    return (
      audioPath: audioPath,
      segmentsFile: SegmentsFile(
        sectionId: sectionId,
        sampleRate: combined.sampleRate,
        pauseMsBetweenSegments: pauseMs,
        segments: timedSegments,
      ),
    );
  }

  /// 16-bit mono silence — a zero-filled Uint8List is already silence,
  /// no need to write anything into it.
  static Uint8List _silencePcm(int sampleRate, int ms) => Uint8List((sampleRate * ms ~/ 1000) * 2);

  void dispose() {
    _tts.stop();
  }
}

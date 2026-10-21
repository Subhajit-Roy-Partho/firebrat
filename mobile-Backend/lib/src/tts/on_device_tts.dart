import 'dart:io';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/segment_models.dart';
import '../models/compiled_models.dart';
import '../util/ids.dart';
import '../novel/novel_analyzer.dart';
import 'caf_utils.dart';
import 'narration_engine.dart';
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
class OnDeviceTts implements NarrationEngine {
  final FlutterTts _tts = FlutterTts();
  bool _configured = false;
  final NovelBookPlan? novelPlan;
  List<Map<Object?, Object?>> _offlineVoices = [];
  Map<String, String>? _narratorVoice;

  OnDeviceTts({this.novelPlan});

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _tts.setLanguage('en-US');
    if (_isAndroid) {
      final voices = (await _tts.getVoices as List)
          .map((v) => Map<Object?, Object?>.from(v as Map))
          .toList();
      _offlineVoices = voices.where((v) {
        final network = v['network_required'] ?? v['networkRequired'];
        return v['locale'] == 'en-US' &&
            (network == false ||
                network == 'false' ||
                network == 0 ||
                network == '0') &&
            !v['features'].toString().contains('notInstalled');
      }).toList();
      _narratorVoice = resolveOfflineCharacterVoice(
        const NovelUtterance('', null),
        _offlineVoices,
        locale: 'en-US',
      );
      if (_narratorVoice == null) {
        throw StateError(
          'No offline English voice is installed. Download an English voice in Android text-to-speech settings before converting offline.',
        );
      }
      await _tts.setVoice(_narratorVoice!);
    }
    await _tts.setSpeechRate(
      0.48,
    ); // flutter_tts rate is 0.0-1.0; ~0.48 reads as a natural, not-rushed pace
    await _tts.awaitSpeakCompletion(true);
    await _tts.awaitSynthCompletion(true);
    _configured = true;
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  /// Synthesizes [segments] to one combined audio file under [sectionDir],
  /// returning the [SegmentsFile] with real sample-accurate timing.
  /// Synthesis failures abort conversion instead of producing silent narration.
  @override
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
      final utterances =
          novelPlan?.split(segments[i].text) ??
          [NovelUtterance(segments[i].text, null)];
      final utteranceClips = <WavAudio>[];
      for (var u = 0; u < utterances.length; u++) {
        final utterance = utterances[u];
        if (utterance.text.trim().isEmpty) continue;
        if (novelPlan != null) {
          final selected =
              resolveOfflineCharacterVoice(
                utterance,
                _offlineVoices,
                locale: 'en-US',
              ) ??
              _narratorVoice;
          if (selected != null) await _tts.setVoice(selected);
          await _tts.setPitch(utterance.style.pitch);
          await _tts.setSpeechRate(utterance.style.rate);
        }
        final ext = _isAndroid ? 'wav' : 'caf';
        final path = '$sectionDir/_seg_${segmentId}_$u.$ext';
        try {
          await _tts.synthesizeToFile(utterance.text, path, true);
          final bytes = await File(path).readAsBytes();
          final clip = _isAndroid
              ? WavAudio.parse(bytes)
              : CafAudio.parse(bytes);
          if (clip.frameCount == 0) throw StateError('empty narration audio');
          if (utteranceClips.isNotEmpty &&
              (clip.sampleRate != utteranceClips.first.sampleRate ||
                  clip.channels != utteranceClips.first.channels ||
                  clip.bitsPerSample != utteranceClips.first.bitsPerSample)) {
            throw StateError(
              'Installed voices returned incompatible audio formats',
            );
          }
          utteranceClips.add(clip);
        } catch (error) {
          throw StateError(
            'Could not synthesize narration for $segmentId: $error',
          );
        } finally {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
      }
      if (utteranceClips.isEmpty) {
        throw StateError('No narration for $segmentId');
      }
      clips.add(WavAudio.concatenate(utteranceClips, pauseMs: 0).combined);
    }

    final (:combined, :timing) = WavAudio.concatenate(clips, pauseMs: pauseMs);
    final audioPath = '$sectionDir/audio.wav';
    await File(audioPath).writeAsBytes(combined.toBytes());

    final timedSegments = <TimedSegment>[];
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      timedSegments.add(
        TimedSegment(
          segmentId: segmentIds[i],
          index: i,
          type: seg.type,
          text: seg.text,
          ref: seg.ref,
          startMs: timing[i].startMs,
          endMs: timing[i].endMs,
          visuallyEssential: seg.visuallyEssential,
        ),
      );
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

  @override
  void dispose() {
    _tts.stop();
  }
}

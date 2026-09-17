import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_kokoro_tts/flutter_kokoro_tts.dart';
import '../models/compiled_models.dart';
import '../models/segment_models.dart';
import '../util/ids.dart';
import 'narration_engine.dart';
import 'wav_utils.dart';

typedef VoiceDownloadProgress = void Function(double? progress, String status);

/// The catalog of preset voices `flutter_kokoro_tts` ships voice-embedding
/// files for — re-exported here so the host app's Settings screen doesn't
/// need to depend on `flutter_kokoro_tts` directly just to list them.
const List<String> kKokoroVoices = kokoroVoices;

/// Narrates using Kokoro-82M — a real neural TTS model run entirely
/// on-device via ONNX Runtime (`flutter_onnxruntime`) with espeak-ng
/// phonemization (native FFI, bundled by `flutter_kokoro_tts`) — instead
/// of the platform's stock TTS engine (`OnDeviceTts`). See
/// `mobile-Backend/README.md` "On-device voice engines" for why this is
/// offered as a choice alongside the stock engine rather than a
/// replacement for it: Kokoro is a fixed 50-preset-voice model (no
/// cloning), while the stock engine needs no ~90MB model download at all.
///
/// The ONNX session `flutter_kokoro_tts` creates internally runs on
/// ONNX Runtime's default CPU execution provider — `flutter_onnxruntime`
/// does expose NNAPI/CoreML execution-provider selection (see
/// `on_device_compiler.dart`'s sibling note on `llama_cpp_dart`'s
/// `gpuLayers` for the LLM side of hardware acceleration), but
/// `flutter_kokoro_tts` v0.0.1 doesn't take a provider argument through to
/// `createSession`, so wiring that through would mean forking it rather
/// than configuring it. Not done here — flagged as a follow-up, not
/// silently assumed.
///
/// **Not runtime-verified**, same caveat as the rest of this package's
/// plugin-dependent code — no physical device/emulator available in this
/// sandbox. `flutter_kokoro_tts` is also itself an early-stage (v0.0.1),
/// low-adoption package; this is a real, reviewed integration against its
/// actual public API, not a proven one.
class KokoroTtsEngine implements NarrationEngine {
  final String voice;
  final double speed;
  final KokoroTts _tts = KokoroTts();
  bool _initialized = false;

  KokoroTtsEngine({this.voice = 'Bella', this.speed = 1.0});

  Future<void> ensureReady({VoiceDownloadProgress? onProgress}) async {
    if (_initialized) return;
    await _tts.initialize(onProgress: (progress, status) => onProgress?.call(progress, status));
    _initialized = true;
  }

  @override
  Future<({String audioPath, SegmentsFile segmentsFile})> narrateSection({
    required String sectionId,
    required List<CompiledSegment> segments,
    required String sectionDir,
    int pauseMs = 260,
  }) async {
    if (!_initialized) {
      throw StateError('KokoroTtsEngine.ensureReady() must succeed before narrateSection()');
    }
    await Directory(sectionDir).create(recursive: true);

    final clips = <WavAudio>[];
    final segmentIds = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segmentId = makeSegmentId(sectionId, i);
      segmentIds.add(segmentId);
      try {
        final pcmFloat = await _tts.generate(segments[i].text, voice: voice, speed: speed);
        clips.add(WavAudio(
          sampleRate: _tts.sampleRate,
          channels: 1,
          bitsPerSample: 16,
          pcmData: _floatToInt16Pcm(pcmFloat),
        ));
      } catch (_) {
        // Same fallback contract as OnDeviceTts: a bad segment gets a
        // slot of silence instead of sinking the whole section.
        clips.add(WavAudio(
          sampleRate: _tts.sampleRate,
          channels: 1,
          bitsPerSample: 16,
          pcmData: Uint8List((_tts.sampleRate * 600 ~/ 1000) * 2),
        ));
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

  /// Kokoro returns float32 PCM in [-1, 1]; the rest of this package's
  /// audio pipeline (`WavAudio`, `docs/DATA_SCHEMA.md`) is 16-bit PCM.
  static Uint8List _floatToInt16Pcm(Float32List samples) {
    final out = Uint8List(samples.length * 2);
    final view = ByteData.view(out.buffer);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0);
      view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return out;
  }

  @override
  void dispose() {
    if (_initialized) _tts.dispose();
    _initialized = false;
  }
}

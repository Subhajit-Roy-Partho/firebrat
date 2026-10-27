import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
// Upstream 0.0.1 is pinned: reuse its checksummed model/voice downloader.
// ignore: implementation_imports
import 'package:flutter_kokoro_tts/src/model_manager.dart';
import '../models/compiled_models.dart';
import '../models/segment_models.dart';
import '../util/ids.dart';
import '../novel/novel_analyzer.dart';
import 'narration_engine.dart';
import 'wav_utils.dart';
import '../models/device_capabilities.dart';
import '../models/tts_model_catalog.dart';
import 'kokoro_runtime.dart' show FirebratKokoroTts;

typedef VoiceDownloadProgress = void Function(double? progress, String status);

/// The catalog of preset voices `flutter_kokoro_tts` ships voice-embedding
/// files for — re-exported here so the host app's Settings screen doesn't
/// need to depend on `flutter_kokoro_tts` directly just to list them.
final List<String> kKokoroVoices = [for (final v in kKokoroVoiceCatalog) v.name];

/// Narrates using Kokoro-82M — a real neural TTS model run entirely
/// on-device via ONNX Runtime (`flutter_onnxruntime`) with espeak-ng
/// phonemization (native FFI, bundled by `flutter_kokoro_tts`) — instead
/// of the platform's stock TTS engine (`OnDeviceTts`). See
/// `mobile-Backend/README.md` "On-device voice engines" for why this is
/// offered as a choice alongside the stock engine rather than a
/// replacement for it: this integration exposes six preset voices (no
/// cloning), while the stock engine needs no ~90MB model download at all.
///
/// Our adaptation of the upstream Dart runtime defaults to CPU inference with
/// two intra-op threads and one inter-op thread, leaving capacity for Android
/// and the reader. The accelerator choice (Auto / GPU-NPU / CPU) selects the
/// ONNX Runtime execution provider (NNAPI, XNNPACK) with automatic CPU
/// fallback, see `accelerator.dart`; [accelerationStatus] reports what really
/// ran. The GPU-layers slider in Settings applies to the separate GGUF LLM.
///
class KokoroTtsEngine implements NarrationEngine {
  final String voice;
  final String maleVoice;
  final String femaleVoice;
  final double speed;
  final NovelBookPlan? novelPlan;
  final FirebratKokoroTts _tts;
  bool _initialized = false;
  bool _statusRecorded = false;

  /// "CPU", "NNAPI (...)", ... after [ensureReady]; check again after the first
  /// narration (a run-time fallback to CPU can still happen there).
  String get accelerationStatus => _tts.accelerationStatus;
  List<String> get accelerationNotes => _tts.accelerationNotes;
  String? get modelNote => _tts.modelNote;

  KokoroTtsEngine({this.voice = 'Bella', this.maleVoice = 'Adam', this.femaleVoice = 'Sarah', this.speed = 1.0, this.novelPlan,
    int cpuThreads = 2, String acceleration = 'cpu', String modelId = kDefaultTtsModelId,
    DeviceCapabilities device = DeviceCapabilities.unknown})
      : _tts = FirebratKokoroTts(cpuThreads: cpuThreads, acceleration: acceleration, modelId: modelId, device: device);

  static Future<bool> isDownloaded() => KokoroModelManager().isReady();

  static Future<void> downloadModels({VoiceDownloadProgress? onProgress}) async {
    final manager = KokoroModelManager();
    await manager.download(onProgress: (p, status) => onProgress?.call(p, status));
    await manager.ensureEspeakData();
    if (!await manager.isReady()) throw StateError('Kokoro model verification failed');
  }

  static Future<List<String>> availableAcceleration() async {
    try {
      final providers = await OnnxRuntime().getAvailableProviders();
      return [
        'cpu',
        if (Platform.isAndroid && providers.contains(OrtProvider.XNNPACK)) 'xnnpack',
        if (Platform.isAndroid && providers.contains(OrtProvider.NNAPI)) 'nnapi',
      ];
    } catch (_) {
      return ['cpu'];
    }
  }

  Future<void> ensureReady({VoiceDownloadProgress? onProgress}) async {
    if (_initialized) return;
    await _tts.initialize(
      onProgress: (progress, status) => onProgress?.call(progress, status),
    );
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
      throw StateError(
        'KokoroTtsEngine.ensureReady() must succeed before narrateSection()',
      );
    }
    await Directory(sectionDir).create(recursive: true);

    final clips = <WavAudio>[];
    final segmentIds = <String>[];
    for (var i = 0; i < segments.length; i++) {
      final segmentId = makeSegmentId(sectionId, i);
      segmentIds.add(segmentId);
      try {
        final utterances =
            novelPlan?.split(segments[i].text) ??
            [NovelUtterance(segments[i].text, null)];
        final utteranceClips = <WavAudio>[];
        for (final utterance in utterances) {
          if (utterance.text.trim().isEmpty) continue;
          final character = utterance.character;
          final selectedVoice = resolveKokoroCharacterVoice(character,
            narrator: voice, male: maleVoice, female: femaleVoice);
          final selectedSpeed = character == null
              ? speed
              : (speed * character.style.rate / 0.48)
                    .clamp(0.75, 1.25)
                    .toDouble();
          final pcmFloat = await _tts.generate(
            utterance.text,
            voice: selectedVoice,
            speed: selectedSpeed,
          );
          if (pcmFloat.isEmpty) throw StateError('empty narration audio');
          utteranceClips.add(
            WavAudio(
              sampleRate: _tts.sampleRate,
              channels: 1,
              bitsPerSample: 16,
              pcmData: _floatToInt16Pcm(pcmFloat),
            ),
          );
        }
        if (utteranceClips.isEmpty) {
          throw StateError('No narration for $segmentId');
        }
        clips.add(WavAudio.concatenate(utteranceClips, pauseMs: 0).combined);
      } catch (error) {
        throw StateError(
          'Could not synthesize narration for $segmentId: $error',
        );
      }
    }

    if (!_statusRecorded) {
      _statusRecorded = true;
      await _tts.recordStatus();
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

/// Automatic character casting keeps drawing from these six voices so books
/// converted before the extra voices existed cast the same way. A newly added
/// voice only joins a pool when the user picks it as their male/female preset.
const kKokoroMaleVoices = ['Adam', 'Michael'];
const kKokoroFemaleVoices = ['Default', 'Bella', 'Nicole', 'Sarah'];

/// Every voice that may be chosen as the male / female preset.
final List<String> kKokoroAllMaleVoices = [for (final v in kKokoroVoiceCatalog) if (!v.isFemale) v.name];
final List<String> kKokoroAllFemaleVoices = [for (final v in kKokoroVoiceCatalog) if (v.isFemale) v.name];
String resolveKokoroCharacterVoice(NovelCharacter? character,
    {required String narrator, required String male, required String female}) {
  final override = character?.voiceOverride;
  if (override != null) {
    for (final v in kKokoroVoices) {
      if (v.toLowerCase() == override.trim().toLowerCase()) return v;
    }
  }
  final gender = character?.voiceGender;
  final pool = gender == 'male' && kKokoroAllMaleVoices.contains(male)
      ? [male, ...kKokoroMaleVoices.where((v) => v != male)]
      : gender == 'female' && kKokoroAllFemaleVoices.contains(female)
          ? [female, ...kKokoroFemaleVoices.where((v) => v != female)]
          : null;
  if (pool == null) return narrator;
  // Characters with a known age/temperament are spread across the voices of
  // their gender (never the narrator's own voice, so they stay
  // distinguishable); everyone else keeps the single configured voice.
  if (character!.traits.hasStyle) {
    final candidates = pool.where((v) => v != narrator).toList();
    if (candidates.isNotEmpty) {
      return candidates[character.style.voiceIndex % candidates.length];
    }
  }
  return pool.first;
}

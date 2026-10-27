/// Catalog of on-device speech (TTS) models and Kokoro voices.
///
/// Everything listed here is something the CURRENT runtime really loads:
/// Kokoro-82M through ONNX Runtime (`flutter_onnxruntime`) with the
/// espeak-ng phonemizer already bundled by the pinned `flutter_kokoro_tts`.
/// Files are fetched from a PINNED Hugging Face revision with SHA-256
/// verification. Piper/VITS, Matcha and other sherpa-onnx voices are
/// deliberately NOT listed: they need a different runtime/phonemizer that
/// could not be verified here (see docs/handover/flutter-models.md).
library;

import 'device_capabilities.dart';
import 'model_tier.dart';

const String kKokoroRepo = 'onnx-community/Kokoro-82M-ONNX';

/// Pinned commit of [kKokoroRepo]; the same one the bundled downloader uses.
const String kKokoroRevision = 'f46687f7e41512228ae953af24a11b2640ea0f22';
const String _base =
    'https://huggingface.co/$kKokoroRepo/resolve/$kKokoroRevision';

class OnDeviceTtsModel implements DownloadableAsset {
  final String id;
  @override
  final String displayName;
  @override
  final String fileName;

  /// Path inside the repo, relative to the pinned revision.
  final String repoPath;
  @override
  final int approxSizeBytes;
  @override
  final String sha256;
  final ModelTier tier;
  final double minDeviceRamGb;
  final String description;
  final String license;
  final String licenseUrl;
  final String runtime;

  /// Back ends it can be asked to use (CPU always; NNAPI/XNNPACK via ORT).
  final Set<AccelBackend> acceleration;

  /// Whether "Auto" may pick NNAPI for this model (on capable phones).
  /// False for the default int8 model: its dynamic-shape quantised graph is
  /// unlikely to benefit and the verified path is CPU.
  final bool autoUsesNnapi;

  /// True when the file ships with the voice download of the pinned
  /// `flutter_kokoro_tts` (nothing extra to fetch).
  final bool bundledWithBase;

  /// True once measured on a physical phone (only the default is).
  final bool verifiedOnDevice;

  const OnDeviceTtsModel({
    required this.id,
    required this.displayName,
    required this.fileName,
    required this.repoPath,
    required this.approxSizeBytes,
    required this.sha256,
    required this.tier,
    required this.minDeviceRamGb,
    required this.description,
    this.license = 'Apache-2.0',
    this.licenseUrl =
        'https://huggingface.co/hexgrad/Kokoro-82M/blob/main/LICENSE',
    this.runtime = 'ONNX Runtime (Kokoro-82M)',
    this.acceleration = const {
      AccelBackend.cpu,
      AccelBackend.xnnpack,
      AccelBackend.nnapi,
    },
    this.autoUsesNnapi = false,
    this.bundledWithBase = false,
    this.verifiedOnDevice = false,
  });

  @override
  String get downloadUrl => '$_base/$repoPath';
  double get sizeMb => approxSizeBytes / 1048576;
}

const String kDefaultTtsModelId = 'kokoro-int8';

const List<OnDeviceTtsModel> kOnDeviceTtsCatalog = [
  OnDeviceTtsModel(
    id: kDefaultTtsModelId,
    displayName: 'Kokoro 82M, int8 (default)',
    fileName: 'model_quantized.onnx',
    repoPath: 'onnx/model_quantized.onnx',
    approxSizeBytes: 92360543,
    sha256: '0d55b15d4b735d61a21b0105136bc81b8768c4db94753193c19354fa863cd556',
    tier: ModelTier.light,
    minDeviceRamGb: 3,
    description:
        'Smallest and the one verified on a phone. Runs on CPU; works on every device.',
    bundledWithBase: true,
    verifiedOnDevice: true,
  ),
  OnDeviceTtsModel(
    id: 'kokoro-fp16',
    displayName: 'Kokoro 82M, fp16',
    fileName: 'model_fp16.onnx',
    repoPath: 'onnx/model_fp16.onnx',
    approxSizeBytes: 163227585,
    sha256: 'fe5c2134605431ee1b2585aee3e59069ddde2aa1111d6213c1ed3fc7da2bb368',
    tier: ModelTier.balanced,
    minDeviceRamGb: 6,
    description:
        'Half-precision weights, close to full quality. The best candidate for NNAPI/GPU/NPU offload; '
        'on plain CPU it can be slower than int8. Not yet measured on a phone.',
    autoUsesNnapi: true,
  ),
  OnDeviceTtsModel(
    id: 'kokoro-fp32',
    displayName: 'Kokoro 82M, full precision (fp32)',
    fileName: 'model.onnx',
    repoPath: 'onnx/model.onnx',
    approxSizeBytes: 325525037,
    sha256: '53a71ac22a70778d57162e4f92eafc62852d9e04a4460b20638d2424796e6037',
    tier: ModelTier.powerful,
    minDeviceRamGb: 8,
    description:
        'Reference quality, largest download. Can use the XNNPACK or NNAPI back end; '
        'the slowest on CPU of the three. Not yet measured on a phone.',
  ),
];

OnDeviceTtsModel findTtsModel(String? id) => kOnDeviceTtsCatalog.firstWhere(
  (m) => m.id == id,
  orElse: () => kOnDeviceTtsCatalog.first,
);

/// Recommended Kokoro file: the default unless the phone is clearly strong.
/// Conservative on purpose: only the verified default is auto-recommended;
/// stronger variants are opt-in because they are unmeasured on devices.
OnDeviceTtsModel recommendTts(DeviceCapabilities device) =>
    findTtsModel(kDefaultTtsModelId);

FitAssessment assessTts(OnDeviceTtsModel m, DeviceCapabilities device) =>
    assessFit(
      name: m.displayName,
      minDeviceRamGb: m.minDeviceRamGb,
      device: device,
    );

/// One Kokoro voice (a 256-float style table, 512 KB).
class KokoroVoiceInfo implements DownloadableAsset {
  /// UI / settings name, e.g. `Bella`.
  final String name;
  @override
  final String fileName;
  final bool isFemale;
  final String accent;

  /// True for the six voices fetched by the bundled downloader.
  final bool bundled;
  @override
  final String sha256;

  const KokoroVoiceInfo(
    this.name,
    this.fileName, {
    required this.isFemale,
    required this.accent,
    required this.bundled,
    required this.sha256,
  });

  @override
  String get displayName => '$name (${isFemale ? 'female' : 'male'}, $accent)';
  @override
  int get approxSizeBytes => 524288;
  @override
  String get downloadUrl => '$_base/voices/$fileName';
}

const List<KokoroVoiceInfo> kKokoroVoiceCatalog = [
  KokoroVoiceInfo(
    'Default',
    'af.bin',
    isFemale: true,
    accent: 'American',
    bundled: true,
    sha256: 'a4f11d9d055a12bfa0db2668a3e4f0ef8fd1f1ccca69494479718e44dbf9e41a',
  ),
  KokoroVoiceInfo(
    'Bella',
    'af_bella.bin',
    isFemale: true,
    accent: 'American',
    bundled: true,
    sha256: '38e12d4b9b31a751282ab9154fb083dad3df3a749772687cde7873da107160fa',
  ),
  KokoroVoiceInfo(
    'Nicole',
    'af_nicole.bin',
    isFemale: true,
    accent: 'American',
    bundled: true,
    sha256: 'f27666996f2d227711e97ff27374099df6f619f3bfb60cd67fc0d114f5384d13',
  ),
  KokoroVoiceInfo(
    'Sarah',
    'af_sarah.bin',
    isFemale: true,
    accent: 'American',
    bundled: true,
    sha256: 'fe4f8b49c272dc5e484ae31a39004fd4ee2b1afc28cbed75da44fc3510b9f984',
  ),
  KokoroVoiceInfo(
    'Adam',
    'am_adam.bin',
    isFemale: false,
    accent: 'American',
    bundled: true,
    sha256: '6d5255a4b4803f594bfa0c0d7539c4d8bb0829c7f190f0f6a8fa0afa0023b6e4',
  ),
  KokoroVoiceInfo(
    'Michael',
    'am_michael.bin',
    isFemale: false,
    accent: 'American',
    bundled: true,
    sha256: '9c3be118019ddb41b6b529a7f75c7a3dc92613f573ca03b037748b9383b0d9d0',
  ),
  KokoroVoiceInfo(
    'Sky',
    'af_sky.bin',
    isFemale: true,
    accent: 'American',
    bundled: false,
    sha256: 'f8017c8507ec6a55e75a04e345f5e6e736e79c104566d191c9b3c4503383ef51',
  ),
  KokoroVoiceInfo(
    'Emma',
    'bf_emma.bin',
    isFemale: true,
    accent: 'British',
    bundled: false,
    sha256: 'fd71ce57d2d69ccbee23210e9229c0de4b3727e248b0c2603caed7e96fc88906',
  ),
  KokoroVoiceInfo(
    'Isabella',
    'bf_isabella.bin',
    isFemale: true,
    accent: 'British',
    bundled: false,
    sha256: 'd3c6f2737d586f019be084c4c1cd247e41fc83686484818da915b1a8d3f2aeb5',
  ),
  KokoroVoiceInfo(
    'George',
    'bm_george.bin',
    isFemale: false,
    accent: 'British',
    bundled: false,
    sha256: '68736d5397fcbc46658696b2cb3bcba0b6748120d75399bc9e1aee338f8f8032',
  ),
  KokoroVoiceInfo(
    'Lewis',
    'bm_lewis.bin',
    isFemale: false,
    accent: 'British',
    bundled: false,
    sha256: '45b693a17544cc98013e54de34c405f92da207bbc63c8b8c3ef67614f887e48c',
  ),
];

KokoroVoiceInfo? findKokoroVoice(String name) {
  for (final v in kKokoroVoiceCatalog) {
    if (v.name == name) return v;
  }
  return null;
}

/// Voices that need the small extra download (not part of the bundled six).
List<KokoroVoiceInfo> get kKokoroExtraVoices => [
  for (final v in kKokoroVoiceCatalog)
    if (!v.bundled) v,
];

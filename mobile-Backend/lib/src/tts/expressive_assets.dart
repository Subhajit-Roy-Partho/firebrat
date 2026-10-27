/// Downloads for the expressive (multi-voice) narrator: Kokoro v1.0 (3 model
/// precisions + 28 English voices) and Piper libritts_r (904-speaker VITS).
/// Same machinery as the other model downloads: resume, SHA-256, network gate
/// through a cancel token. Files live beside the stock Kokoro files and never
/// touch them.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../compilation/model_downloader.dart';
import '../models/model_tier.dart';

const String kKokoroV1Repo = 'onnx-community/Kokoro-82M-v1.0-ONNX';
const String kKokoroV1Revision = '1939ad2a8e416c0acfeecc08a694d14ef25f2231';
const String kPiperRepo = 'rhasspy/piper-voices';
const String kPiperRevision = '5041a7a49ae5b3a0f30e6837769eb03fdbb231bd';

class AssetFile implements DownloadableAsset {
  @override
  final String displayName;
  @override
  final String fileName;
  @override
  final String downloadUrl;
  @override
  final int approxSizeBytes;
  @override
  final String sha256;
  const AssetFile(this.displayName, this.fileName, this.downloadUrl, this.approxSizeBytes, this.sha256);
}

/// One selectable speech engine for the expressive mode.
enum ExpressiveEngine {
  kokoro('kokoro', 'Kokoro (most natural, slower)'),
  piper('piper', 'Piper (many voices, 8x faster)');

  final String storageValue;
  final String label;
  const ExpressiveEngine(this.storageValue, this.label);
  static ExpressiveEngine parse(String? v) => v == 'kokoro' ? kokoro : piper;
}

/// Kokoro v1.0 graphs. Measured on a Pixel 9a (see docs/handover/android-expressive-gpu.md).
class KokoroV1Model {
  final String id;
  final String label;
  final AssetFile file;
  final bool fp16;
  final ModelTier tier;
  final String note;
  const KokoroV1Model(this.id, this.label, this.file, {this.fp16 = false, required this.tier, required this.note});
}

AssetFile _k(String name, String file, int size, String sha) =>
    AssetFile(name, file, 'https://huggingface.co/$kKokoroV1Repo/resolve/$kKokoroV1Revision/onnx/$file', size, sha);

final List<KokoroV1Model> kKokoroV1Models = [
  KokoroV1Model('kokoro1-int8', 'Kokoro v1.0 int8 (92 MB)',
      _k('Kokoro v1.0 int8', 'model_quantized.onnx', 92361116, 'fbae9257e1e05ffc727e951ef9b9c98418e6d79f1c9b6b13bd59f5c9028a1478'),
      tier: ModelTier.light, note: 'Smallest. Runs on the CPU only (the NNAPI path fails on it).'),
  KokoroV1Model('kokoro1-fp16', 'Kokoro v1.0 fp16 (163 MB)',
      _k('Kokoro v1.0 fp16', 'model_fp16.onnx', 163234740, 'ba4527a874b42b21e35f468c10d326fdff3c7fc8cac1f85e9eb6c0dfc35c334a'),
      fp16: true, tier: ModelTier.balanced, note: 'Fastest on ARM through XNNPACK; a safety net re-runs the rare numeric overflow.'),
  KokoroV1Model('kokoro1-fp32', 'Kokoro v1.0 fp32 (326 MB)',
      _k('Kokoro v1.0 fp32', 'model.onnx', 325532232, '8fbea51ea711f2af382e88c833d9e288c6dc82ce5e98421ea61c058ce21a34cb'),
      tier: ModelTier.powerful, note: 'Reference quality; no overflow risk.'),
];

KokoroV1Model findKokoroV1Model(String? id) => kKokoroV1Models.firstWhere((m) => m.id == id, orElse: () => kKokoroV1Models[1]);

const List<(String, String)> _voiceSha = [
  ('af_heart', 'd583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b'),
  ('af_bella', 'f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b'),
  ('af_nicole', 'cd2191ab31b914ed7b318416b0e4440fdf392ddad9106a060819aa600a64f59a'),
  ('af_aoede', '4a004c33430762e2461eedb2013fad808ef4ab3121f5300f554476caf58d8361'),
  ('af_kore', '9be5221b6a941c04b561959b8ff0b06e809444dcc4ab7e75a7b23606f691819e'),
  ('af_sarah', '4409fbc125afabacc615d94db5398d847006a737b0247d6892b7a9a0007a2f0a'),
  ('af_nova', '18778272caa0d0eebaea251c35fd635f038434f9eee5e691d02a174bd328414f'),
  ('af_alloy', 'c4a6b876047fd7fb472edf4ebd63cfac7c3b958a7cae7c106e8f038ca6308c45'),
  ('af_sky', '4435255c9744f3f31659e0d714ab7689bf65d9e77ec1cce060f083912614f0b9'),
  ('af_jessica', 'a240a5e3c15b43563d6e923bdca8ef5613a23471d9b77653694012435df23bd8'),
  ('af_river', '00a2bcf82b1d86e8f19902ede58c65ccf6c0e43b44b7d74fad54e5d8933c9c30'),
  ('am_fenrir', 'c27989f741f7ee34d273a39d8a595cc0837d35f5ced9a29b7cc162614616df43'),
  ('am_michael', '1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1'),
  ('am_puck', 'fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0'),
  ('am_echo', '3968b92c3c4cd1c4416dbded36c13eaa388a90d5788d02a13e4d781f5f8cf3c3'),
  ('am_eric', 'e8b5be17edd1e3636901ce7598baafe2dc8dd8ff707a0c23bf9e461add7e2832'),
  ('am_liam', '52403be32fd047c6a44517cb0bcd6b134f2a18baa73e70ef41651e0eab921ade'),
  ('am_onyx', 'da5d135b424164916d75a68ffb4c2abce3d7d5ccc82dd1ee6cf447ce286145e6'),
  ('am_santa', '61150cf726ab6c5ed7a99f90a304f91f5a72c00c592e89ec94e5df11c319227a'),
  ('am_adam', '162b035ed91cfc48b6046982184c645f72edcdd1b82843347f605d7bf7b15716'),
  ('bf_emma', '669fe0647f9dd04fcab92f1439a40eeb4c8b4ab1f82e4996fe3d918ce4a63b73'),
  ('bf_isabella', '3754352c4aaa46d17f27654ab7518d65b62ad6163a0f55a5f4330c2da2c4e94f'),
  ('bf_alice', '08afa6ba24da61ea5e8efa139e5aadc938d83f0a6da5a900adaf763ac1da5573'),
  ('bf_lily', '5e0ee32ebe64a467124976b14e69590746f1c4ce41a12b587a50c862edfea335'),
  ('bm_fable', 'f889083196807b4adb15e9204252165f503b8d33d3982e681c52443c49d798f1'),
  ('bm_george', 'c4b235a4c1f2cd3b939fed08b899ce9385638b763f7b73a59616c4fc9bd6c9bc'),
  ('bm_lewis', 'b8f671cef828c30e66fdf0b0756a76bba58f6bb3398cbbf27058642acbcedb97'),
  ('bm_daniel', '6b3194bbceffb746733cbc22c8f593dd44e401a71d53895a2dca891bc595a1e8'),
];

final List<AssetFile> kKokoroV1VoiceFiles = [
  for (final (name, sha) in _voiceSha)
    AssetFile('Kokoro voice $name', '$name.bin', 'https://huggingface.co/$kKokoroV1Repo/resolve/$kKokoroV1Revision/voices/$name.bin', 522240, sha),
];

final AssetFile kPiperLibrittsModel = AssetFile('Piper libritts_r medium', 'en_US-libritts_r-medium.onnx',
    'https://huggingface.co/$kPiperRepo/resolve/$kPiperRevision/en/en_US/libritts_r/medium/en_US-libritts_r-medium.onnx', 78580914,
    '10bb85e071d616fcf4071f369f1799d0491492ab3c5d552ec19fb548fac13195');
final AssetFile kPiperLibrittsConfig = AssetFile('Piper libritts_r config', 'en_US-libritts_r-medium.onnx.json',
    'https://huggingface.co/$kPiperRepo/resolve/$kPiperRevision/en/en_US/libritts_r/medium/en_US-libritts_r-medium.onnx.json', 20123,
    'b471dc60d2d8335e819c393d196d6fbf792817f40051257b269878505bc9afb3');

/// Where the expressive assets live and whether they are complete.
class ExpressiveAssets {
  final String root; // e.g. <app documents>/kokoro
  const ExpressiveAssets(this.root);

  static Future<ExpressiveAssets> forApp() async => ExpressiveAssets('${(await getApplicationDocumentsDirectory()).path}/kokoro');

  String get kokoroDir => '$root/v1';
  String get kokoroVoicesDir => '$root/v1/voices';
  String get piperDir => '$root/piper';
  String get espeakBase => root;

  String kokoroModelPath(KokoroV1Model m) => '$kokoroDir/${m.file.fileName}';
  String get piperModelPath => '$piperDir/${kPiperLibrittsModel.fileName}';
  String get piperConfigPath => '$piperDir/${kPiperLibrittsConfig.fileName}';

  static Future<bool> _has(String path, int size) async {
    final f = File(path);
    return await f.exists() && await f.length() == size;
  }

  Future<bool> kokoroReady(KokoroV1Model m) async {
    if (!await _has(kokoroModelPath(m), m.file.approxSizeBytes)) return false;
    for (final v in kKokoroV1VoiceFiles) {
      if (!await _has('$kokoroVoicesDir/${v.fileName}', v.approxSizeBytes)) return false;
    }
    return true;
  }

  Future<bool> piperReady() async =>
      await _has(piperModelPath, kPiperLibrittsModel.approxSizeBytes) && await _has(piperConfigPath, kPiperLibrittsConfig.approxSizeBytes);

  Future<Set<String>> installedKokoroVoices() async => {
        for (final v in kKokoroV1VoiceFiles)
          if (await _has('$kokoroVoicesDir/${v.fileName}', v.approxSizeBytes)) v.fileName.replaceAll('.bin', ''),
      };

  /// Bytes still to download for [engine] (and Kokoro model [m]).
  Future<int> missingBytes(ExpressiveEngine engine, KokoroV1Model m) async {
    var total = 0;
    if (engine == ExpressiveEngine.piper) {
      if (!await _has(piperModelPath, kPiperLibrittsModel.approxSizeBytes)) total += kPiperLibrittsModel.approxSizeBytes;
      if (!await _has(piperConfigPath, kPiperLibrittsConfig.approxSizeBytes)) total += kPiperLibrittsConfig.approxSizeBytes;
    } else {
      if (!await _has(kokoroModelPath(m), m.file.approxSizeBytes)) total += m.file.approxSizeBytes;
      for (final v in kKokoroV1VoiceFiles) {
        if (!await _has('$kokoroVoicesDir/${v.fileName}', v.approxSizeBytes)) total += v.approxSizeBytes;
      }
    }
    return total;
  }

  /// Downloads whatever is missing for [engine]; resumable and checksummed.
  Future<void> download(ExpressiveEngine engine, KokoroV1Model m,
      {DownloadProgressCallback? onProgress, CancelToken? cancelToken}) async {
    final dl = ModelDownloader();
    final files = engine == ExpressiveEngine.piper
        ? [(kPiperLibrittsModel, piperDir), (kPiperLibrittsConfig, piperDir)]
        : [(m.file, kokoroDir), for (final v in kKokoroV1VoiceFiles) (v, kokoroVoicesDir)];
    for (var i = 0; i < files.length; i++) {
      final (file, dir) = files[i];
      await dl.ensureDownloaded(file, dir,
          cancelToken: cancelToken,
          onProgress: (p, s) => onProgress?.call((i + (p ?? 0)) / files.length, s));
    }
    onProgress?.call(1.0, 'ready');
  }
}

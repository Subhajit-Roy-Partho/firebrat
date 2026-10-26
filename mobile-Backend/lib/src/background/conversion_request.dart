import 'dart:convert';
import 'dart:io';
import '../util/ids.dart';

/// Everything the background task isolate needs to run one conversion.
/// `flutter_foreground_task`'s `TaskHandler` runs in a genuinely separate
/// isolate — static/global Dart state set in the main isolate is NOT
/// visible there, so this gets handed across the isolate boundary as a
/// JSON file rather than passed in memory. See
/// `background_conversion_runner.dart` for where it's written, and
/// `conversion_task_handler.dart` for where it's read back.
class ConversionRequest {
  final String pdfPath;

  /// All source PDFs in chapter order. Null in requests written before
  /// multi-PDF support — readers fall back to the single [pdfPath].
  final List<String>? pdfPaths;
  final String booksRootDir;
  final String modelsDir;
  final String? titleOverride;
  final bool allowCloudFallback;
  final bool cloudForAll;
  final bool researchCharacters;
  /// Opt-in grounded character enrichment using the selected local GGUF only.
  final bool localCharacterResearch;
  final String contentMode;
  final String llmBaseUrl;
  final String llmApiKey;
  final String llmModel;
  final String? onDeviceLlmModelId;
  final int onDeviceGpuLayers;
  final String voiceEngine;
  final String kokoroVoice;
  final String kokoroAcceleration;
  final int kokoroCpuThreads;
  final String maleVoice;
  final String femaleVoice;
  final Map<String, String> characterVoices;

  const ConversionRequest({
    required this.pdfPath,
    this.pdfPaths,
    required this.booksRootDir,
    required this.modelsDir,
    this.titleOverride,
    this.allowCloudFallback = false,
    this.cloudForAll = false,
    this.researchCharacters = true,
    this.localCharacterResearch = false,
    this.contentMode = 'illustrated',
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    this.onDeviceLlmModelId,
    this.onDeviceGpuLayers = 0,
    this.voiceEngine = 'kokoroOnnx',
    this.kokoroVoice = 'Bella',
    this.kokoroAcceleration = 'cpu',
    this.kokoroCpuThreads = 2,
    this.maleVoice = 'Adam',
    this.femaleVoice = 'Sarah',
    this.characterVoices = const {},
  });

  /// Every source PDF in chapter order — [pdfPaths] when set, else the
  /// legacy single [pdfPath]. The pipeline merges them at the text layer.
  /// The folder name (under the books root) this conversion writes into; mirrors
  /// how the pipeline names a book, so a cancelled run's leftovers can be found.
  String get bookId => sanitizeBookId(
      titleOverride != null ? '$titleOverride.pdf' : sourcePdfPaths.first.split(Platform.pathSeparator).last);

  List<String> get sourcePdfPaths =>
      (pdfPaths != null && pdfPaths!.isNotEmpty) ? pdfPaths! : [pdfPath];

  Map<String, dynamic> toJson() => {
    'pdfPath': pdfPath,
    'pdfPaths': pdfPaths,
    'booksRootDir': booksRootDir,
    'modelsDir': modelsDir,
    'titleOverride': titleOverride,
    'allowCloudFallback': allowCloudFallback,
    'cloudForAll': cloudForAll,
    'researchCharacters': researchCharacters,
    'localCharacterResearch': localCharacterResearch,
    'contentMode': contentMode,
    'llmBaseUrl': llmBaseUrl,
    'llmApiKey': llmApiKey,
    'llmModel': llmModel,
    'onDeviceLlmModelId': onDeviceLlmModelId,
    'onDeviceGpuLayers': onDeviceGpuLayers,
    'voiceEngine': voiceEngine,
    'kokoroVoice': kokoroVoice,
    'kokoroAcceleration': kokoroAcceleration,
    'kokoroCpuThreads': kokoroCpuThreads,
    'maleVoice': maleVoice, 'femaleVoice': femaleVoice, 'characterVoices': characterVoices,
  };

  factory ConversionRequest.fromJson(Map<String, dynamic> json) =>
      ConversionRequest(
        pdfPath: json['pdfPath'] as String,
        pdfPaths: (json['pdfPaths'] as List?)?.cast<String>(),
        booksRootDir: json['booksRootDir'] as String,
        modelsDir: json['modelsDir'] as String,
        titleOverride: json['titleOverride'] as String?,
        allowCloudFallback: json['allowCloudFallback'] as bool? ?? false,
        cloudForAll: json['cloudForAll'] as bool? ?? false,
        researchCharacters: json['researchCharacters'] as bool? ?? true,
        localCharacterResearch: json['localCharacterResearch'] as bool? ?? false,
        contentMode: json['contentMode'] as String? ?? 'illustrated',
        llmBaseUrl: json['llmBaseUrl'] as String,
        llmApiKey: json['llmApiKey'] as String,
        llmModel: json['llmModel'] as String,
        onDeviceLlmModelId: json['onDeviceLlmModelId'] as String?,
        onDeviceGpuLayers: json['onDeviceGpuLayers'] as int? ?? 0,
        voiceEngine: json['voiceEngine'] as String? ?? 'kokoroOnnx',
        kokoroVoice: json['kokoroVoice'] as String? ?? 'Bella',
        kokoroAcceleration: json['kokoroAcceleration'] as String? ?? 'cpu',
        kokoroCpuThreads: (json['kokoroCpuThreads'] as int? ?? 2).clamp(1, 4),
        maleVoice: json['maleVoice'] as String? ?? 'Adam',
        femaleVoice: json['femaleVoice'] as String? ?? 'Sarah',
        characterVoices: Map<String, String>.from(json['characterVoices'] as Map? ?? {}),
      );

  static String _filePath(String stateDir) =>
      '$stateDir/firebrat_pending_conversion.json';

  Future<void> writeTo(String stateDir) async {
    final file = File(_filePath(stateDir));
    await file.writeAsString(jsonEncode(toJson()));
  }

  static Future<ConversionRequest?> readFrom(String stateDir) async {
    final file = File(_filePath(stateDir));
    if (!await file.exists()) return null;
    final text = await file.readAsString();
    return ConversionRequest.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  static Future<void> clear(String stateDir) async {
    final file = File(_filePath(stateDir));
    if (await file.exists()) await file.delete();
  }
}

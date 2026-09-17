import 'dart:convert';
import 'dart:io';

/// Everything the background task isolate needs to run one conversion.
/// `flutter_foreground_task`'s `TaskHandler` runs in a genuinely separate
/// isolate — static/global Dart state set in the main isolate is NOT
/// visible there, so this gets handed across the isolate boundary as a
/// JSON file rather than passed in memory. See
/// `background_conversion_runner.dart` for where it's written, and
/// `conversion_task_handler.dart` for where it's read back.
class ConversionRequest {
  final String pdfPath;
  final String booksRootDir;
  final String modelsDir;
  final String? titleOverride;
  final String llmBaseUrl;
  final String llmApiKey;
  final String llmModel;
  final String? onDeviceLlmModelId;
  final int onDeviceGpuLayers;
  final String voiceEngine;
  final String kokoroVoice;

  const ConversionRequest({
    required this.pdfPath,
    required this.booksRootDir,
    required this.modelsDir,
    this.titleOverride,
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    this.onDeviceLlmModelId,
    this.onDeviceGpuLayers = 99,
    this.voiceEngine = 'stockTts',
    this.kokoroVoice = 'Bella',
  });

  Map<String, dynamic> toJson() => {
        'pdfPath': pdfPath,
        'booksRootDir': booksRootDir,
        'modelsDir': modelsDir,
        'titleOverride': titleOverride,
        'llmBaseUrl': llmBaseUrl,
        'llmApiKey': llmApiKey,
        'llmModel': llmModel,
        'onDeviceLlmModelId': onDeviceLlmModelId,
        'onDeviceGpuLayers': onDeviceGpuLayers,
        'voiceEngine': voiceEngine,
        'kokoroVoice': kokoroVoice,
      };

  factory ConversionRequest.fromJson(Map<String, dynamic> json) => ConversionRequest(
        pdfPath: json['pdfPath'] as String,
        booksRootDir: json['booksRootDir'] as String,
        modelsDir: json['modelsDir'] as String,
        titleOverride: json['titleOverride'] as String?,
        llmBaseUrl: json['llmBaseUrl'] as String,
        llmApiKey: json['llmApiKey'] as String,
        llmModel: json['llmModel'] as String,
        onDeviceLlmModelId: json['onDeviceLlmModelId'] as String?,
        onDeviceGpuLayers: json['onDeviceGpuLayers'] as int? ?? 99,
        voiceEngine: json['voiceEngine'] as String? ?? 'stockTts',
        kokoroVoice: json['kokoroVoice'] as String? ?? 'Bella',
      );

  static String _filePath(String stateDir) => '$stateDir/firebrat_pending_conversion.json';

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

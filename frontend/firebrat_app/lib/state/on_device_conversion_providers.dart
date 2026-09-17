import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/server_url.dart';

/// How the app should convert a new PDF: send it to a Firebrat server
/// (existing upload flow, `state/conversions_providers.dart`), or convert
/// it right here using `mobile_backend_pipeline` — see
/// `mobile-Backend/PROPOSAL.md` for why the on-device pipeline still needs
/// a user-configured cloud LLM for the chunks its own on-device model
/// isn't trusted with.
enum ConversionModePref { cloud, onDevice }

class ConversionModeSettings {
  final ConversionModePref mode;
  final String cloudServerUrl;
  final String onDeviceLlmUrl;
  final String onDeviceLlmApiKey;
  final String onDeviceLlmModel;
  /// Catalog id of the on-device GGUF model (see mobile_backend_pipeline's
  /// kOnDeviceLlmCatalog), e.g. 'qwen3-4b'. Used for easy chunks; hard
  /// chunks still go to the cloud LLM above.
  final String onDeviceLlmModelId;
  /// llama.cpp GPU offload layers: 99 = everything that fits (accelerated),
  /// 0 = pure CPU fallback for uncooperative GPU drivers.
  final int onDeviceGpuLayers;
  /// 'stockTts' (platform voice, default) or 'kokoroOnnx' (on-device neural).
  final String voiceEngine;
  /// Kokoro preset voice name (kKokoroVoices), only used for kokoroOnnx.
  final String kokoroVoice;

  const ConversionModeSettings({
    this.mode = ConversionModePref.cloud,
    this.cloudServerUrl = '',
    this.onDeviceLlmUrl = '',
    this.onDeviceLlmApiKey = '',
    this.onDeviceLlmModel = '',
    this.onDeviceLlmModelId = 'qwen3-4b',
    this.onDeviceGpuLayers = 99,
    this.voiceEngine = 'stockTts',
    this.kokoroVoice = 'Bella',
  });

  ConversionModeSettings copyWith({
    ConversionModePref? mode,
    String? cloudServerUrl,
    String? onDeviceLlmUrl,
    String? onDeviceLlmApiKey,
    String? onDeviceLlmModel,
    String? onDeviceLlmModelId,
    int? onDeviceGpuLayers,
    String? voiceEngine,
    String? kokoroVoice,
  }) =>
      ConversionModeSettings(
        mode: mode ?? this.mode,
        cloudServerUrl: cloudServerUrl ?? this.cloudServerUrl,
        onDeviceLlmUrl: onDeviceLlmUrl ?? this.onDeviceLlmUrl,
        onDeviceLlmApiKey: onDeviceLlmApiKey ?? this.onDeviceLlmApiKey,
        onDeviceLlmModel: onDeviceLlmModel ?? this.onDeviceLlmModel,
        onDeviceLlmModelId: onDeviceLlmModelId ?? this.onDeviceLlmModelId,
        onDeviceGpuLayers: onDeviceGpuLayers ?? this.onDeviceGpuLayers,
        voiceEngine: voiceEngine ?? this.voiceEngine,
        kokoroVoice: kokoroVoice ?? this.kokoroVoice,
      );

  bool get isOnDeviceConfigured =>
      onDeviceLlmUrl.trim().isNotEmpty && onDeviceLlmApiKey.trim().isNotEmpty && onDeviceLlmModel.trim().isNotEmpty;

  bool get isKokoroVoice => voiceEngine == 'kokoroOnnx';
}

class ConversionModeNotifier extends Notifier<ConversionModeSettings> {
  static const _kMode = 'conversion.mode';
  static const _kCloudUrl = 'conversion.cloudServerUrl';
  static const _kLlmUrl = 'conversion.onDeviceLlmUrl';
  static const _kLlmKey = 'conversion.onDeviceLlmApiKey';
  static const _kLlmModel = 'conversion.onDeviceLlmModel';
  static const _kLocalLlmId = 'conversion.onDeviceLlmModelId';
  static const _kGpuLayers = 'conversion.onDeviceGpuLayers';
  static const _kVoiceEngine = 'conversion.voiceEngine';
  static const _kKokoroVoice = 'conversion.kokoroVoice';

  @override
  ConversionModeSettings build() {
    _load();
    return const ConversionModeSettings();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = ConversionModeSettings(
      mode: (prefs.getString(_kMode) == 'onDevice') ? ConversionModePref.onDevice : ConversionModePref.cloud,
      cloudServerUrl: prefs.getString(_kCloudUrl) ?? '',
      onDeviceLlmUrl: prefs.getString(_kLlmUrl) ?? '',
      onDeviceLlmApiKey: prefs.getString(_kLlmKey) ?? '',
      onDeviceLlmModel: prefs.getString(_kLlmModel) ?? '',
      onDeviceLlmModelId: prefs.getString(_kLocalLlmId) ?? 'qwen3-4b',
      onDeviceGpuLayers: prefs.getInt(_kGpuLayers) ?? 99,
      voiceEngine: prefs.getString(_kVoiceEngine) ?? 'stockTts',
      kokoroVoice: prefs.getString(_kKokoroVoice) ?? 'Bella',
    );
  }

  Future<void> setMode(ConversionModePref mode) async {
    state = state.copyWith(mode: mode);
    (await SharedPreferences.getInstance()).setString(_kMode, mode == ConversionModePref.onDevice ? 'onDevice' : 'cloud');
  }

  Future<void> setCloudServerUrl(String url) async {
    final normalized = normalizeServerUrl(url);
    state = state.copyWith(cloudServerUrl: normalized);
    (await SharedPreferences.getInstance()).setString(_kCloudUrl, normalized);
  }

  Future<void> setOnDeviceLlm({required String url, required String apiKey, required String model}) async {
    final normalizedUrl = normalizeLlmUrl(url);
    state = state.copyWith(onDeviceLlmUrl: normalizedUrl, onDeviceLlmApiKey: apiKey, onDeviceLlmModel: model);
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_kLlmUrl, normalizedUrl);
    prefs.setString(_kLlmKey, apiKey);
    prefs.setString(_kLlmModel, model);
  }

  Future<void> setLocalLlmModel(String id) async {
    state = state.copyWith(onDeviceLlmModelId: id);
    (await SharedPreferences.getInstance()).setString(_kLocalLlmId, id);
  }

  Future<void> setGpuLayers(int layers) async {
    state = state.copyWith(onDeviceGpuLayers: layers);
    (await SharedPreferences.getInstance()).setInt(_kGpuLayers, layers);
  }

  Future<void> setVoiceEngine(String engine) async {
    assert(engine == 'stockTts' || engine == 'kokoroOnnx');
    state = state.copyWith(voiceEngine: engine);
    (await SharedPreferences.getInstance()).setString(_kVoiceEngine, engine);
  }

  Future<void> setKokoroVoice(String voice) async {
    state = state.copyWith(kokoroVoice: voice);
    (await SharedPreferences.getInstance()).setString(_kKokoroVoice, voice);
  }
}

final conversionModeProvider =
    NotifierProvider<ConversionModeNotifier, ConversionModeSettings>(ConversionModeNotifier.new);

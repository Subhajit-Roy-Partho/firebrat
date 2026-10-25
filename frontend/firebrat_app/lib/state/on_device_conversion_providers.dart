import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/server_url.dart';

/// How the app should convert a new PDF: send it to a Firebrat server
/// (existing upload flow, `state/conversions_providers.dart`), or convert
/// it right here using `mobile_backend_pipeline` — see
/// `mobile-Backend/PROPOSAL.md` for why the on-device pipeline still needs
/// a user-configured cloud LLM for the chunks its own on-device model
/// isn't trusted with.
enum ConversionModePref { offline, cloud, onDevice }

class ConversionModeSettings {
  final ConversionModePref mode;
  final String cloudServerUrl;
  /// Where finished books live for this device: 'server' (the Firebrat
  /// server above — downloads + shelf) or 'drive' (your own Google Drive;
  /// books back up there after downloading and other devices pull them).
  final String storageBackend;
  final String contentMode;
  final bool allowCloudFallback;
  final bool cloudForAll;
  final bool researchCharacters;
  final String onDeviceLlmUrl;
  final String onDeviceLlmApiKey;
  final String onDeviceLlmModel;
  /// Server-side conversion engine: 'llm' (cloud LLM helper, the server
  /// default) or 'native' (datacenter GPUs only). Only used in cloud mode.
  final String serverProvider;
  /// Optional cloud-LLM override sent with each server upload: endpoint URL,
  /// API key (stored only on this phone), and model name.
  final String serverLlmUrl;
  final String serverLlmApiKey;
  final String serverLlmModel;
  /// Catalog id of the on-device GGUF model (see mobile_backend_pipeline's
  /// kOnDeviceLlmCatalog), e.g. 'qwen3-4b'. Used for easy chunks; hard
  /// chunks still go to the cloud LLM above.
  final String onDeviceLlmModelId;
  /// llama.cpp GPU offload layers: 99 = everything that fits (accelerated),
  /// 0 = pure CPU fallback for uncooperative GPU drivers.
  final int onDeviceGpuLayers;
  /// 'kokoroOnnx' (on-device neural, default) or 'stockTts' (the phone's own voice).
  final String voiceEngine;
  /// Kokoro preset voice name (kKokoroVoices), only used for kokoroOnnx.
  final String kokoroVoice;
  final String maleVoice;
  final String femaleVoice;
  final Map<String, String> characterVoices;

  const ConversionModeSettings({
    this.mode = ConversionModePref.offline,
    this.cloudServerUrl = '',
    this.storageBackend = 'server',
    this.contentMode = 'illustrated',
    this.allowCloudFallback = false,
    this.cloudForAll = false,
    this.researchCharacters = true,
    this.onDeviceLlmUrl = '',
    this.onDeviceLlmApiKey = '',
    this.onDeviceLlmModel = '',
    this.serverProvider = 'llm',
    this.serverLlmUrl = '',
    this.serverLlmApiKey = '',
    this.serverLlmModel = '',
    this.onDeviceLlmModelId = 'qwen3-1.7b',
    this.onDeviceGpuLayers = 0,
    this.voiceEngine = 'kokoroOnnx',
    this.kokoroVoice = 'Bella',
    this.maleVoice = 'Adam',
    this.femaleVoice = 'Sarah',
    this.characterVoices = const {},
  });

  ConversionModeSettings copyWith({
    ConversionModePref? mode,
    String? cloudServerUrl,
    String? storageBackend,
    String? contentMode,
    bool? allowCloudFallback,
    bool? cloudForAll,
    bool? researchCharacters,
    String? onDeviceLlmUrl,
    String? onDeviceLlmApiKey,
    String? onDeviceLlmModel,
    String? serverProvider,
    String? serverLlmUrl,
    String? serverLlmApiKey,
    String? serverLlmModel,
    String? onDeviceLlmModelId,
    int? onDeviceGpuLayers,
    String? voiceEngine,
    String? kokoroVoice,
    String? maleVoice, String? femaleVoice, Map<String, String>? characterVoices,
  }) =>
      ConversionModeSettings(
        mode: mode ?? this.mode,
        cloudServerUrl: cloudServerUrl ?? this.cloudServerUrl,
        storageBackend: storageBackend ?? this.storageBackend,
        contentMode: contentMode ?? this.contentMode,
        allowCloudFallback: allowCloudFallback ?? this.allowCloudFallback,
        cloudForAll: cloudForAll ?? this.cloudForAll,
        researchCharacters: researchCharacters ?? this.researchCharacters,
        onDeviceLlmUrl: onDeviceLlmUrl ?? this.onDeviceLlmUrl,
        onDeviceLlmApiKey: onDeviceLlmApiKey ?? this.onDeviceLlmApiKey,
        onDeviceLlmModel: onDeviceLlmModel ?? this.onDeviceLlmModel,
        serverProvider: serverProvider ?? this.serverProvider,
        serverLlmUrl: serverLlmUrl ?? this.serverLlmUrl,
        serverLlmApiKey: serverLlmApiKey ?? this.serverLlmApiKey,
        serverLlmModel: serverLlmModel ?? this.serverLlmModel,
        onDeviceLlmModelId: onDeviceLlmModelId ?? this.onDeviceLlmModelId,
        onDeviceGpuLayers: onDeviceGpuLayers ?? this.onDeviceGpuLayers,
        voiceEngine: voiceEngine ?? this.voiceEngine,
        kokoroVoice: kokoroVoice ?? this.kokoroVoice,
        maleVoice: maleVoice ?? this.maleVoice, femaleVoice: femaleVoice ?? this.femaleVoice,
        characterVoices: characterVoices ?? this.characterVoices,
      );

  bool get isOnDeviceConfigured =>
      contentMode == 'novel' || !allowCloudFallback || (onDeviceLlmUrl.trim().isNotEmpty && onDeviceLlmApiKey.trim().isNotEmpty && onDeviceLlmModel.trim().isNotEmpty);

  bool get isKokoroVoice => voiceEngine == 'kokoroOnnx';
}

class ConversionModeNotifier extends Notifier<ConversionModeSettings> {
  static const _kMode = 'conversion.mode';
  static const _kCloudUrl = 'conversion.cloudServerUrl';
  static const _kStorage = 'conversion.storageBackend';
  static const _kLlmUrl = 'conversion.onDeviceLlmUrl';
  static const _kLlmKey = 'conversion.onDeviceLlmApiKey';
  static const _kLlmModel = 'conversion.onDeviceLlmModel';
  static const _kLocalLlmId = 'conversion.onDeviceLlmModelId';
  static const _kGpuLayers = 'conversion.onDeviceGpuLayers';
  static const _kServerProvider = 'conversion.serverProvider';
  static const _kServerLlmUrl = 'conversion.serverLlmUrl';
  static const _kServerLlmKey = 'conversion.serverLlmApiKey';
  static const _kServerLlmModel = 'conversion.serverLlmModel';
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
      mode: switch (prefs.getString(_kMode)) {
        'cloud' => ConversionModePref.cloud,
        'onDevice' => ConversionModePref.onDevice,
        _ => ConversionModePref.offline,
      },
      cloudServerUrl: prefs.getString(_kCloudUrl) ?? '',
      storageBackend: prefs.getString(_kStorage) ?? 'server',
      contentMode: prefs.getString('conversion.contentMode') ?? 'illustrated',
      allowCloudFallback: prefs.getBool('conversion.allowCloudFallback') ?? false,
      cloudForAll: prefs.getBool('conversion.cloudForAll') ?? false,
      researchCharacters: prefs.getBool('conversion.researchCharacters') ?? true,
      onDeviceLlmUrl: prefs.getString(_kLlmUrl) ?? '',
      onDeviceLlmApiKey: prefs.getString(_kLlmKey) ?? '',
      onDeviceLlmModel: prefs.getString(_kLlmModel) ?? '',
      serverProvider: prefs.getString(_kServerProvider) ?? 'llm',
      serverLlmUrl: prefs.getString(_kServerLlmUrl) ?? '',
      serverLlmApiKey: prefs.getString(_kServerLlmKey) ?? '',
      serverLlmModel: prefs.getString(_kServerLlmModel) ?? '',
      onDeviceLlmModelId: prefs.getString(_kLocalLlmId) ?? 'qwen3-1.7b',
      onDeviceGpuLayers: prefs.getInt(_kGpuLayers) ?? 0,
      voiceEngine: prefs.getString(_kVoiceEngine) ?? 'kokoroOnnx',
      kokoroVoice: prefs.getString(_kKokoroVoice) ?? 'Bella',
      maleVoice: prefs.getString('conversion.maleVoice') ?? 'Adam',
      femaleVoice: prefs.getString('conversion.femaleVoice') ?? 'Sarah',
      characterVoices: Map<String, String>.from(jsonDecode(prefs.getString('conversion.characterVoices') ?? '{}') as Map),
    );
  }

  Future<void> setContentMode(String mode) async {
    if (mode != 'illustrated' && mode != 'novel') throw ArgumentError.value(mode);
    state = state.copyWith(contentMode: mode);
    await (await SharedPreferences.getInstance()).setString('conversion.contentMode', mode);
  }

  Future<void> setAllowCloudFallback(bool enabled) async {
    state = state.copyWith(allowCloudFallback: enabled);
    await (await SharedPreferences.getInstance()).setBool('conversion.allowCloudFallback', enabled);
  }

  Future<void> setResearchCharacters(bool enabled) async {
    state = state.copyWith(researchCharacters: enabled);
    await (await SharedPreferences.getInstance()).setBool('conversion.researchCharacters', enabled);
  }

  Future<void> setCloudForAll(bool enabled) async {
    state = state.copyWith(cloudForAll: enabled);
    await (await SharedPreferences.getInstance()).setBool('conversion.cloudForAll', enabled);
  }

  Future<void> setMode(ConversionModePref mode) async {
    state = state.copyWith(mode: mode);
    await (await SharedPreferences.getInstance()).setString(_kMode, mode.name);
  }

  Future<void> setCloudServerUrl(String url) async {
    final normalized = normalizeServerUrl(url);
    state = state.copyWith(cloudServerUrl: normalized);
    (await SharedPreferences.getInstance()).setString(_kCloudUrl, normalized);
  }

  /// 'server' (shelf + downloads from the Firebrat server URL above) or
  /// 'drive' (your Google Drive — books back up there, other devices pull
  /// them; needs Drive sign-in below, uses your own Drive quota).
  Future<void> setStorageBackend(String backend) async {
    assert(backend == 'server' || backend == 'drive');
    state = state.copyWith(storageBackend: backend);
    (await SharedPreferences.getInstance()).setString(_kStorage, backend);
  }

  Future<void> setOnDeviceLlm({required String url, required String apiKey, required String model}) async {    final normalizedUrl = normalizeLlmUrl(url);
    state = state.copyWith(onDeviceLlmUrl: normalizedUrl, onDeviceLlmApiKey: apiKey, onDeviceLlmModel: model);
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_kLlmUrl, normalizedUrl);
    prefs.setString(_kLlmKey, apiKey);
    prefs.setString(_kLlmModel, model);
  }

  /// 'llm' (cloud LLM helper, matches the server default) or 'native'
  /// (datacenter GPUs only, no LLM calls).
  Future<void> setServerProvider(String provider) async {
    assert(provider == 'llm' || provider == 'native');
    state = state.copyWith(serverProvider: provider);
    (await SharedPreferences.getInstance()).setString(_kServerProvider, provider);
  }

  /// Optional per-upload LLM override for the server: endpoint + key stay
  /// on this phone and travel only with its own upload requests.
  Future<void> setServerLlm({required String url, required String apiKey, required String model}) async {
    final normalizedUrl = url.trim().isEmpty ? '' : normalizeLlmUrl(url);
    state = state.copyWith(serverLlmUrl: normalizedUrl, serverLlmApiKey: apiKey, serverLlmModel: model);
    final prefs = await SharedPreferences.getInstance();
    prefs.setString(_kServerLlmUrl, normalizedUrl);
    prefs.setString(_kServerLlmKey, apiKey);
    prefs.setString(_kServerLlmModel, model);
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

  Future<void> setCharacterVoiceDefaults({String? male, String? female, Map<String, String>? overrides}) async {
    state = state.copyWith(maleVoice: male, femaleVoice: female, characterVoices: overrides);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('conversion.maleVoice', state.maleVoice);
    await prefs.setString('conversion.femaleVoice', state.femaleVoice);
    await prefs.setString('conversion.characterVoices', jsonEncode(state.characterVoices));
  }

  Future<void> setKokoroVoice(String voice) async {
    state = state.copyWith(kokoroVoice: voice);
    (await SharedPreferences.getInstance()).setString(_kKokoroVoice, voice);
  }
}

final conversionModeProvider =
    NotifierProvider<ConversionModeNotifier, ConversionModeSettings>(ConversionModeNotifier.new);

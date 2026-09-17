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

  const ConversionModeSettings({
    this.mode = ConversionModePref.cloud,
    this.cloudServerUrl = '',
    this.onDeviceLlmUrl = '',
    this.onDeviceLlmApiKey = '',
    this.onDeviceLlmModel = '',
  });

  ConversionModeSettings copyWith({
    ConversionModePref? mode,
    String? cloudServerUrl,
    String? onDeviceLlmUrl,
    String? onDeviceLlmApiKey,
    String? onDeviceLlmModel,
  }) =>
      ConversionModeSettings(
        mode: mode ?? this.mode,
        cloudServerUrl: cloudServerUrl ?? this.cloudServerUrl,
        onDeviceLlmUrl: onDeviceLlmUrl ?? this.onDeviceLlmUrl,
        onDeviceLlmApiKey: onDeviceLlmApiKey ?? this.onDeviceLlmApiKey,
        onDeviceLlmModel: onDeviceLlmModel ?? this.onDeviceLlmModel,
      );

  bool get isOnDeviceConfigured =>
      onDeviceLlmUrl.trim().isNotEmpty && onDeviceLlmApiKey.trim().isNotEmpty && onDeviceLlmModel.trim().isNotEmpty;
}

class ConversionModeNotifier extends Notifier<ConversionModeSettings> {
  static const _kMode = 'conversion.mode';
  static const _kCloudUrl = 'conversion.cloudServerUrl';
  static const _kLlmUrl = 'conversion.onDeviceLlmUrl';
  static const _kLlmKey = 'conversion.onDeviceLlmApiKey';
  static const _kLlmModel = 'conversion.onDeviceLlmModel';

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
}

final conversionModeProvider =
    NotifierProvider<ConversionModeNotifier, ConversionModeSettings>(ConversionModeNotifier.new);

/// How a conversion should be carried out — the one choice the host app
/// needs to surface to the user (see package README "Integrating into the
/// Flutter app").
enum ConversionMode {
  /// Upload the PDF to a Firebrat server (existing `backend/`) and let it
  /// do everything, same as `frontend/firebrat_app`'s existing upload flow.
  cloud,

  /// Run extraction + compilation-routing + narration on this device.
  /// Compilation still calls out to a cloud LLM for chunks the routing
  /// heuristic flags as needing it (math-heavy / 2+ figures-tables) —
  /// see `compilation/routing.dart` — using the OpenAI-compatible
  /// endpoint the user configures below, not a fixed provider.
  onDevice,
}

/// Cloud mode only needs the existing Firebrat server's base URL —
/// identical to `FIREBRAT_API_BASE_URL` in the Flutter app today.
class CloudModeSettings {
  final String serverBaseUrl;
  const CloudModeSettings({required this.serverBaseUrl});
}

/// On-device mode's one required piece of cloud configuration: an
/// OpenAI-compatible chat-completions endpoint for the "difficult" chunks
/// (math-heavy or figure/table-dense — see `routing.dart`). Works with
/// nano-gpt, OpenAI itself, or any other OpenAI-compatible provider —
/// nothing here is provider-specific.
class OnDeviceModeSettings {
  /// e.g. https://nano-gpt.com/api/v1 or https://api.openai.com/v1
  final String llmBaseUrl;
  final String llmApiKey;
  /// e.g. "deepseek/deepseek-v4-pro:thinking" or "gpt-4.1"
  final String llmModel;

  /// Cactus on-device model slug for the easy-chunk tier, e.g. "qwen3-0.6".
  /// Defaults to Cactus's own default if left null.
  final String? onDeviceModelSlug;

  const OnDeviceModeSettings({
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    this.onDeviceModelSlug,
  });
}

class ConversionSettings {
  final ConversionMode mode;
  final CloudModeSettings? cloud;
  final OnDeviceModeSettings? onDevice;

  const ConversionSettings.cloud(CloudModeSettings settings)
      : mode = ConversionMode.cloud,
        cloud = settings,
        onDevice = null;

  const ConversionSettings.onDevice(OnDeviceModeSettings settings)
      : mode = ConversionMode.onDevice,
        cloud = null,
        onDevice = settings;
}

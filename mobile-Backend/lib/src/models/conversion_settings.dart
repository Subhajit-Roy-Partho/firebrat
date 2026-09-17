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

/// Which local narration engine to use for on-device TTS (see
/// `tts/narration_engine.dart`) — the platform's built-in stock voice
/// (`OnDeviceTts`, no download, no cloning) or Kokoro-82M, a real neural
/// voice model run on-device via ONNX Runtime (`KokoroTtsEngine`,
/// ~90MB one-time download, 50 preset voices, still no cloning).
enum OnDeviceVoiceEngine { stockTts, kokoroOnnx }

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

  /// Catalog id for the easy-chunk tier's on-device model (see
  /// `compilation/model_catalog.dart`), e.g. "qwen3-4b". Defaults to the
  /// catalog's own recommended default if left null.
  final String? onDeviceLlmModelId;

  /// Transformer layers to offload to the GPU for the on-device LLM (see
  /// `compilation/on_device_compiler.dart`). `99` offloads everything
  /// that fits (hardware-accelerated); `0` forces pure-CPU inference —
  /// the fallback if a device's GPU driver doesn't cooperate with
  /// llama.cpp's Vulkan/OpenCL backend.
  final int onDeviceGpuLayers;

  /// Which on-device narrator to use — see [OnDeviceVoiceEngine].
  final OnDeviceVoiceEngine voiceEngine;

  /// Kokoro preset voice name (see `tts/kokoro_tts_engine.dart`'s
  /// `kKokoroVoices`), only used when [voiceEngine] is `kokoroOnnx`.
  final String kokoroVoice;

  const OnDeviceModeSettings({
    required this.llmBaseUrl,
    required this.llmApiKey,
    required this.llmModel,
    this.onDeviceLlmModelId,
    this.onDeviceGpuLayers = 99,
    this.voiceEngine = OnDeviceVoiceEngine.stockTts,
    this.kokoroVoice = 'Bella',
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

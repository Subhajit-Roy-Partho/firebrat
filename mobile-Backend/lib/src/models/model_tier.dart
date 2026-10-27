/// Shared vocabulary for the model catalogs (LLM and TTS).
library;

/// Device/model class. Ordered: a higher index needs a stronger phone.
enum ModelTier {
  light('Light', 'Any phone, including 3-4 GB RAM'),
  balanced('Balanced', 'Mid-range, 6-8 GB RAM'),
  powerful('Powerful', 'High-end, 10-12 GB RAM'),
  desktopClass(
    'Desktop-class',
    'Flagship with 12-16 GB RAM; slow, battery heavy',
  );

  final String label;
  final String audience;
  const ModelTier(this.label, this.audience);
}

/// Hardware back ends a model can be asked to run on.
enum AccelBackend {
  cpu('CPU'),

  /// llama.cpp's Vulkan GPU back end (LLMs).
  vulkan('GPU (Vulkan)'),

  /// ONNX Runtime NNAPI execution provider: GPU, DSP/NPU or CPU depending
  /// on the vendor driver; unsupported ops fall back to CPU per node.
  nnapi('NNAPI (GPU/NPU)'),

  /// ONNX Runtime XNNPACK: optimised ARM CPU kernels (still CPU).
  xnnpack('XNNPACK (optimised CPU)');

  final String label;
  const AccelBackend(this.label);
}

/// Common metadata of every downloadable model file.
abstract interface class DownloadableAsset {
  String get displayName;
  String get fileName;
  String get downloadUrl;

  /// Size in bytes. Exact when [sha256] is set, otherwise approximate.
  int get approxSizeBytes;

  /// Lower-case hex SHA-256 of the file (verified after download) or null.
  String? get sha256;
}

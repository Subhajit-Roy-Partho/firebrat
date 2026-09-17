import '../models/compiled_models.dart';
import '../models/segment_models.dart';

/// Common shape both on-device narrators produce, so
/// `pipeline/mobile_conversion_pipeline.dart` can pick either one at
/// runtime from `ConversionSettings` without branching on which engine it
/// is anywhere else. Implemented by `OnDeviceTts` (platform stock voice)
/// and `KokoroTtsEngine` (ONNX neural voice) — see
/// `mobile-Backend/README.md` "On-device voice engines" for the tradeoff.
abstract class NarrationEngine {
  Future<({String audioPath, SegmentsFile segmentsFile})> narrateSection({
    required String sectionId,
    required List<CompiledSegment> segments,
    required String sectionDir,
    int pauseMs = 260,
  });

  void dispose();
}

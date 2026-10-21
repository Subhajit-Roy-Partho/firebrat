/// On-device PDF -> audiobook conversion pipeline for Firebrat — see
/// `mobile-Backend/PROPOSAL.md` for the feasibility research this is
/// built from, and `mobile-Backend/README.md` for integration + known
/// limitations.
library;

export 'src/models/conversion_settings.dart';
export 'src/models/manifest_models.dart';
export 'src/models/segment_models.dart';
export 'src/models/compiled_models.dart';
export 'src/models/raw_page.dart';
export 'src/extraction/pdf_text_extractor.dart';
export 'src/compilation/chunker.dart';
export 'src/compilation/routing.dart';
export 'src/compilation/compilation_router.dart';
export 'src/compilation/cloud_compiler.dart';
export 'src/compilation/model_catalog.dart';
export 'src/compilation/model_downloader.dart';
export 'src/compilation/on_device_compiler.dart';
export 'src/tts/narration_engine.dart';
export 'src/tts/kokoro_tts_engine.dart';
export 'src/tts/on_device_tts.dart';
export 'src/tts/wav_utils.dart';
export 'src/pipeline/mobile_conversion_pipeline.dart';
export 'src/util/ids.dart';
export 'src/background/conversion_request.dart';
export 'src/background/conversion_task_handler.dart';
export 'src/background/background_conversion_runner.dart';

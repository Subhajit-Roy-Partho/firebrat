import '../cast/cast_engine.dart';
import '../compilation/model_catalog.dart';
import '../models/model_tier.dart';
import '../tts/expressive_assets.dart';

/// Honest time estimate for an expressive conversion, before it starts.
class ExpressiveTimeEstimate {
  final double castingMinutes;
  final double narrationMinutes;
  final double audioMinutes;
  final int rosterCalls;
  final int attributionCalls;
  const ExpressiveTimeEstimate(
      this.castingMinutes, this.narrationMinutes, this.audioMinutes, this.rosterCalls, this.attributionCalls);
  double get totalMinutes => castingMinutes + narrationMinutes;
}

/// Quoted lines per word in English fiction (292 quotes / ~7,800 words in the
/// evaluation fixture; novels vary from 0.02 to 0.06).
const double kQuotesPerWord = 0.035;

/// Narration speed: ~155 words per minute of audio.
const double kWordsPerAudioMinute = 155;

/// Real-time factor (processing time / audio time) of each speech engine on a
/// Pixel 9a CPU; sustained (a cool phone is up to 2x faster). Measured, see
/// docs/handover/android-expressive-gpu.md.
double speechRtf(ExpressiveEngine engine, {String kokoroModelId = 'kokoro1-fp16'}) =>
    engine == ExpressiveEngine.piper ? 0.14 : 1.3;

ExpressiveTimeEstimate estimateExpressive({
  required int words,
  required OnDeviceLlmModel model,
  required ModelTier tier,
  required ExpressiveEngine engine,
  String kokoroModelId = 'kokoro1-fp16',
}) {
  final limits = CastLimits.forTier(tier);
  final quotes = (words * kQuotesPerWord).round();
  final windows = (words / (limits.windowWords - limits.windowOverlap)).ceil().clamp(1, limits.rosterWindows);
  final chunks = (words / limits.chunkWords).ceil().clamp(1, 1 << 30);
  final byQuotes = (quotes / limits.maxQuotesPerChunk).ceil();
  var attr = (chunks > byQuotes ? chunks : byQuotes).clamp(1, 1 << 30);
  final budget = limits.maxLlmCalls - windows;
  if (attr > budget) attr = budget < 1 ? 1 : budget;
  final avgQuotes = quotes == 0 ? 0 : quotes / (chunks > byQuotes ? chunks : byQuotes);
  const rosterPrompt = 1500.0, rosterOut = 300.0, attrBase = 450.0, perQuotePrompt = 70.0, perQuoteOut = 20.0;
  final seconds = windows * (rosterPrompt / model.prefillTokS + rosterOut / model.genTokS) +
      attr * ((attrBase + avgQuotes * perQuotePrompt) / model.prefillTokS + (avgQuotes * perQuoteOut + 10) / model.genTokS);
  final audioMin = words / kWordsPerAudioMinute;
  return ExpressiveTimeEstimate(seconds / 60, audioMin * speechRtf(engine, kokoroModelId: kokoroModelId), audioMin, windows, attr);
}

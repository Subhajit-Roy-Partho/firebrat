import '../models/raw_page.dart';

/// Direct port of `_needs_strong_model()` in `compile_llm.py` — a chunk
/// that looks math-heavy or figure/table-dense gets escalated to the
/// user-configured cloud LLM (see `cloud_compiler.dart`); everything else
/// runs on the on-device model (see `on_device_compiler.dart`). This is
/// the same heuristic the server pipeline already trusts for flash-vs-pro
/// routing — reused here for on-device-vs-cloud routing instead, per
/// `mobile-Backend/PROPOSAL.md` §5's recommendation.
///
/// Note: since this v1 extractor doesn't detect figures/tables (see
/// `pdf_text_extractor.dart`), the figure/table half of the heuristic is
/// always 0 here — only the equation-hint signal is live until layout
/// extraction is added.
final RegExp _equationHintPattern = RegExp(r'[A-Za-z]{1,6}\s*=\s*[A-Za-z0-9]');

bool needsCloudModel(PageChunk chunk, {int figuresAndTablesCount = 0}) {
  final equationHints = chunk.pages.fold<int>(
    0,
    (sum, page) => sum + _equationHintPattern.allMatches(page.text).length,
  );
  return equationHints >= 1 || figuresAndTablesCount >= 2;
}

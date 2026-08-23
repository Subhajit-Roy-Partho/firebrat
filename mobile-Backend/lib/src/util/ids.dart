/// Id-minting conventions, mirroring `backend/firebrat/utils/ids.py` exactly
/// (see `docs/DATA_SCHEMA.md`) — the on-device pipeline must produce ids in
/// the same shape as the server pipeline so the two are interchangeable to
/// the reader app, which only ever validates id *format*, not origin.
library;

String sanitizeBookId(String pdfFileName) {
  final stem = pdfFileName.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
  final cleaned = stem
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '')
      .toLowerCase();
  return cleaned.isEmpty ? 'book' : cleaned;
}

String makeFigureId(int n) => 'fig_${n.toString().padLeft(4, '0')}';
String makeFormulaId(int n) => 'formula_${n.toString().padLeft(4, '0')}';
String makeTableId(int n) => 'tbl_${n.toString().padLeft(4, '0')}';
String makeSectionId(int n) => 'sec_${n.toString().padLeft(4, '0')}';

/// 1-based within its section, matching `make_segment_id` server-side.
String makeSegmentId(String sectionId, int zeroBasedIndex) =>
    '${sectionId}_seg_${(zeroBasedIndex + 1).toString().padLeft(3, '0')}';

/// A ref must match one of these shapes to be trusted — anything else is a
/// hallucinated id and gets nulled out rather than propagated, mirroring
/// `compile_llm.py`'s `_sanitize_refs()`.
final RegExp validRefPattern = RegExp(r'^(fig|formula|tbl)_\d{4}$');

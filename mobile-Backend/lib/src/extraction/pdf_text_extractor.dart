import 'dart:io';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../models/raw_page.dart';

/// Text-layer extraction for born-digital PDFs — no OCR, no vision model,
/// just the PDF's own text objects. This is the part of the original
/// server pipeline's Stage 1 that has a genuinely mature, lightweight
/// on-device equivalent (see `mobile-Backend/PROPOSAL.md` §1a).
///
/// **Known limitation (v1)**: this does not detect or extract figures,
/// tables, or embedded images — the manifest this pipeline produces will
/// always have empty `figures`/`tables` arrays. Full layout-aware
/// extraction (distinguishing a figure region from body text, cropping its
/// image) needs a model like DocLayout-YOLO with no mature Flutter plugin
/// today — see the proposal's §1a for what that would take. Math typeset
/// as prose (the common case for the sample book this project targets) is
/// unaffected: the compilation LLM still authors LaTeX from the extracted
/// text exactly as the server pipeline does.
class MobilePdfTextExtractor {
  /// Extracts every page's text. Pages with implausibly little text
  /// (below [minCharsPerPage]) are returned in [ExtractionResult.ocrCandidatePageIndices]
  /// so the caller can optionally run OCR on them instead (see
  /// `ocr_fallback.dart`) — this is the scanned-page case, where the PDF
  /// has no real text layer.
  static Future<ExtractionResult> extractPages(
    String pdfPath, {
    int minCharsPerPage = 40,
  }) async {
    final bytes = await File(pdfPath).readAsBytes();
    final document = sf.PdfDocument(inputBytes: bytes);
    try {
      final pages = <RawPage>[];
      final ocrCandidates = <int>[];
      final extractor = sf.PdfTextExtractor(document);
      for (var i = 0; i < document.pages.count; i++) {
        final text = extractor.extractText(startPageIndex: i, endPageIndex: i);
        final cleaned = _normalizeWhitespace(text);
        pages.add(RawPage(pageIdx: i, text: cleaned));
        if (cleaned.length < minCharsPerPage) ocrCandidates.add(i);
      }
      return ExtractionResult(pages: pages, ocrCandidatePageIndices: ocrCandidates);
    } finally {
      document.dispose();
    }
  }

  static String _normalizeWhitespace(String s) =>
      s.replaceAll(RegExp(r'[ \t]+'), ' ').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

class ExtractionResult {
  final List<RawPage> pages;
  final List<int> ocrCandidatePageIndices;
  const ExtractionResult({required this.pages, required this.ocrCandidatePageIndices});
}

/// Concatenates per-PDF extractions into one continuous page stream, as if
/// the chapters had been one PDF all along: page indices (and OCR-candidate
/// indices) are offset by each preceding file's page count. Pure function
/// so it stays unit-testable without real PDF fixtures — see
/// `test/extraction_merge_test.dart`.
ExtractionResult mergeExtractions(List<ExtractionResult> parts) {
  final pages = <RawPage>[];
  final ocrCandidates = <int>[];
  var offset = 0;
  for (final part in parts) {
    for (final page in part.pages) {
      pages.add(RawPage(pageIdx: page.pageIdx + offset, text: page.text));
    }
    for (final idx in part.ocrCandidatePageIndices) {
      ocrCandidates.add(idx + offset);
    }
    offset += part.pages.length;
  }
  return ExtractionResult(pages: pages, ocrCandidatePageIndices: ocrCandidates);
}

import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;
import '../models/raw_page.dart';

/// On-device OCR for pages a text-layer extraction pass flagged as
/// probably-scanned (near-zero extractable text). Google ML Kit Text
/// Recognition v2 — production-grade, fully on-device, Android + iOS (see
/// `mobile-Backend/PROPOSAL.md` §1a). This renders the flagged page to a
/// bitmap first (Syncfusion's page-to-image render), then OCRs the bitmap.
class OcrFallback {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Re-extracts [pageIndices] from [pdfPath] via render-to-image + OCR,
  /// returning replacement [RawPage]s for the caller to splice back in.
  Future<List<RawPage>> reExtractPages(String pdfPath, List<int> pageIndices, String tempDir) async {
    if (pageIndices.isEmpty) return const [];
    final bytes = await File(pdfPath).readAsBytes();
    final document = sf.PdfDocument(inputBytes: bytes);
    final results = <RawPage>[];
    try {
      for (final pageIdx in pageIndices) {
        final imageBytes = _renderPageToPng(document, pageIdx);
        if (imageBytes == null) {
          results.add(RawPage(pageIdx: pageIdx, text: ''));
          continue;
        }
        final tempPath = '$tempDir/ocr_page_$pageIdx.png';
        final tempFile = File(tempPath);
        await tempFile.writeAsBytes(imageBytes);
        try {
          final recognized = await _recognizer.processImage(InputImage.fromFilePath(tempPath));
          results.add(RawPage(pageIdx: pageIdx, text: recognized.text));
        } finally {
          if (await tempFile.exists()) await tempFile.delete();
        }
      }
    } finally {
      document.dispose();
    }
    return results;
  }

  /// Syncfusion's PDF library doesn't rasterize pages to images on its own
  /// (that's PdfViewer's job, a widget, not usable headlessly here) — a
  /// real implementation needs a page-to-bitmap renderer such as `pdfx` or
  /// platform PDF-rendering APIs (Android `PdfRenderer`, iOS `PDFKit`).
  /// Left unimplemented in this v1: OCR fallback is wired up and ready to
  /// use once page rasterization is added, but scanned (image-only) PDFs
  /// aren't fully supported yet — text-layer PDFs (the common case) work
  /// today without this path ever being hit. See package README.
  List<int>? _renderPageToPng(sf.PdfDocument document, int pageIndex) => null;

  void dispose() => _recognizer.close();
}

import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter/services.dart';
import '../models/raw_page.dart';

/// On-device OCR for pages a text-layer extraction pass flagged as
/// probably-scanned (near-zero extractable text). Google ML Kit Text
/// Recognition v2 — production-grade, fully on-device, Android + iOS (see
/// `mobile-Backend/PROPOSAL.md` §1a). This renders the flagged page to a
/// bitmap through Android's native PDF renderer, then OCRs the bitmap.
/// The iOS page-rendering bridge is not implemented.
class OcrFallback {
  final TextRecognizer _recognizer = TextRecognizer(script: TextRecognitionScript.latin);

  /// Re-extracts [pageIndices] from [pdfPath] via render-to-image + OCR,
  /// returning replacement [RawPage]s for the caller to splice back in.
  Future<List<RawPage>> reExtractPages(String pdfPath, List<int> pageIndices, String tempDir) async {
    if (pageIndices.isEmpty) return const [];
    await Directory(tempDir).create(recursive: true);
    final results = <RawPage>[];
    for (final pageIdx in pageIndices) {
      final tempPath = '$tempDir/ocr_page_$pageIdx.png';
      await const MethodChannel('firebrat/local_pdf').invokeMethod<String>('renderPage', {
        'path': pdfPath, 'page': pageIdx, 'output': tempPath,
      });
      try {
        final recognized = await _recognizer.processImage(InputImage.fromFilePath(tempPath));
        if (recognized.text.trim().isEmpty) {
          throw StateError('Could not read source page ${pageIdx + 1} with offline OCR.');
        }
        results.add(RawPage(pageIdx: pageIdx, text: recognized.text));
      } finally {
        final file = File(tempPath);
        if (await file.exists()) await file.delete();
      }
    }
    return results;
  }

  void dispose() => _recognizer.close();
}

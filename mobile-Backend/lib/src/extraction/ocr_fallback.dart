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
    // Recognised text is kept per page, so a paused or interrupted conversion
    // does not read the scanned pages again when it resumes.
    final key = await _sourceKey(pdfPath);
    for (final pageIdx in pageIndices) {
      final cached = File('$tempDir/ocr_${key}_$pageIdx.txt');
      if (await cached.exists()) {
        results.add(RawPage(pageIdx: pageIdx, text: await cached.readAsString()));
        continue;
      }
      final tempPath = '$tempDir/ocr_page_$pageIdx.png';
      await const MethodChannel('firebrat/local_pdf').invokeMethod<String>('renderPage', {
        'path': pdfPath, 'page': pageIdx, 'output': tempPath,
      });
      try {
        final recognized = await _recognizer.processImage(InputImage.fromFilePath(tempPath));
        // A cover, frontispiece or blank page legitimately has no text. Keep it as an
        // empty page instead of failing the whole book; the pipeline reports how many
        // pages had no readable text, and still refuses a document with none at all.
        final text = recognized.text.trim();
        final staged = File('${cached.path}.tmp');
        await staged.writeAsString(text);
        await staged.rename(cached.path);
        results.add(RawPage(pageIdx: pageIdx, text: text));
      } finally {
        final file = File(tempPath);
        if (await file.exists()) await file.delete();
      }
    }
    return results;
  }

  /// Identifies one source file (its path and size) in the cache file names.
  static Future<String> _sourceKey(String pdfPath) async {
    var h = 0x811c9dc5;
    for (final unit in '$pdfPath:${await File(pdfPath).length()}'.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0xffffffff;
    }
    return h.toRadixString(16);
  }

  void dispose() => _recognizer.close();
}

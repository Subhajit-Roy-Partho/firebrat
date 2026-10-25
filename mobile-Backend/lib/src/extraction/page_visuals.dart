import 'dart:io';
import 'package:flutter/services.dart';
import '../models/manifest_models.dart';
import '../models/raw_page.dart';
import '../util/ids.dart';

/// Source-page images preserve vector diagrams, photos, and table layout.
/// These are explicitly page views, not purported figure-region crops.
class PageVisuals {
  static const _channel = MethodChannel('firebrat/local_pdf');

  /// A page-1 cover is used only when the first page has almost no text, like a
  /// title page. A first page of body text or a contents list keeps the generated cover.
  static const maxCoverTextChars = 150;
  static bool looksLikeCover(String firstPageText) => firstPageText.trim().length < maxCoverTextChars;

  /// Renders page 1 of [pdfPath] to `<bookDir>/cover.png` (Android only). Never
  /// throws: a cover is cosmetic.
  static Future<bool> renderCover({required String pdfPath, required String bookDir}) async {
    if (!Platform.isAndroid) return false;
    try {
      await _channel.invokeMethod<String>('renderPage', {
        'path': pdfPath, 'page': 0, 'output': '$bookDir/cover.png',
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<ManifestFigure>> render({
    required List<String> pdfPaths,
    required String bookDir,
    required List<RawPage> pages,
  }) async {
    if (!Platform.isAndroid) return [];
    final figures = <ManifestFigure>[];
    var offset = 0;
    for (final path in pdfPaths) {
      // Counts supplied by extraction avoid reopening a document in Dart.
      final count = await _channel.invokeMethod<int>('pageCount', {'path': path});
      for (var local = 0; local < (count ?? 0); local++) {
        final global = offset + local;
        final page = pages.where((p) => p.pageIdx == global).first;
        // Preserve a page view for every page: vector-only artwork and
        // scanned pages have no embedded-image catalog to enumerate.
        final relative = 'figures/page_${(global + 1).toString().padLeft(4, '0')}.png';
        await _channel.invokeMethod<String>('renderPage', {
          'path': path, 'page': local, 'output': '$bookDir/$relative',
        });
        figures.add(ManifestFigure(figureId: makeFigureId(figures.length + 1),
          caption: 'Source page ${page.pageIdx + 1} (original layout)',
          imagePath: relative, page: global));
      }
      offset += count ?? 0;
    }
    return figures;
  }
}

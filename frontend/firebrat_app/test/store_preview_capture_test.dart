// Opt-in widget-rendered listing previews; no device execution implied.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/screens/library_screen.dart';
import 'package:firebrat_app/screens/conversion_settings_screen.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/theme/app_theme.dart';

void main() {
  testWidgets('capture genuine library and conversion widgets', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_STORE_PREVIEWS')) return;
    final font = FontLoader('Roboto');
    font.addFont(
      Future.value(
        ByteData.sublistView(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ).readAsBytesSync(),
        ),
      ),
    );
    await font.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(
      Future.value(
        ByteData.sublistView(
          File(
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytesSync(),
        ),
      ),
    );
    await icons.load();
    SharedPreferences.setMockInitialValues({
      'conversion.mode': 'onDevice',
      'conversion.contentMode': 'novel',
      'conversion.voiceEngine': 'kokoroOnnx',
    });
    final temp = Directory.systemTemp.createTempSync('firebrat-preview-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (_) async => temp.path,
    );
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3;
    final boundaryKey = GlobalKey();
    final books = [
      const BookSummary(
        bookId: 'alice',
        title: 'Alice’s Adventures in Wonderland',
        author: 'Lewis Carroll',
        totalDurationMs: 9000000,
        sectionCount: 12,
        sizeBytes: 54000000,
        updatedAt: '',
      ),
      const BookSummary(
        bookId: 'pride',
        title: 'Pride and Prejudice',
        author: 'Jane Austen',
        totalDurationMs: 36000000,
        sectionCount: 61,
        sizeBytes: 180000000,
        updatedAt: '',
      ),
      const BookSummary(
        bookId: 'sherlock',
        title: 'The Adventures of Sherlock Holmes',
        author: 'Arthur Conan Doyle',
        totalDurationMs: 30000000,
        sectionCount: 12,
        sizeBytes: 150000000,
        updatedAt: '',
      ),
      const BookSummary(
        bookId: 'frankenstein',
        title: 'Frankenstein',
        author: 'Mary Shelley',
        totalDurationMs: 25200000,
        sectionCount: 24,
        sizeBytes: 125000000,
        updatedAt: '',
      ),
    ];
    Widget wrap(Widget screen) => ProviderScope(
      overrides: [
        localBooksProvider.overrideWith((ref) async => books),
        catalogProvider.overrideWith((ref) async => []),
        for (final b in books)
          bookCoverProvider(b.bookId).overrideWith((ref) async => null),
      ],
      child: RepaintBoundary(
        key: boundaryKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          home: screen,
        ),
      ),
    );
    Future<void> capture(String filename) async {
      expect(tester.takeException(), isNull);
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 3);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '../../assets/play-store/screenshots/$filename',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    Directory(
      '../../assets/play-store/screenshots',
    ).createSync(recursive: true);
    await tester.pumpWidget(wrap(const LibraryScreen()));
    await tester.pumpAndSettle();
    await capture('01-library-small-cards.png');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(wrap(const ConversionSettingsScreen()));
    await tester.pumpAndSettle();
    await capture('02-offline-conversion-settings.png');
    await tester.scrollUntilVisible(
      find.text('Kokoro voice'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Kokoro voice'));
    await tester.pumpAndSettle();
    await capture('03-novel-voices.png');
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.reset();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
    temp.deleteSync(recursive: true);
  });
}

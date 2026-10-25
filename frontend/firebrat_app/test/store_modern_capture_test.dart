// Opt-in: renders the real LibraryScreen/BookCover widgets for the Play
// listing. No capture happens without --dart-define=CAPTURE_STORE_MODERN=true.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/screens/library_screen.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/tour_providers.dart';
import 'package:firebrat_app/theme/app_theme.dart';
import 'package:firebrat_app/widgets/book_cover.dart';

const _out = '../../assets/play-store/modern-refresh/sources';
const _flutterFonts = '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts';

Future<void> _font(String family, String path) async {
  final l = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await l.load();
}

BookSummary _b(String id, String t, String a, int min, int sections) => BookSummary(
      bookId: id, title: t, author: a, totalDurationMs: min * 60000,
      sectionCount: sections, sizeBytes: 1, updatedAt: '');

void main() {
  testWidgets('capture modern store sources', (tester) async {
    if (!const bool.fromEnvironment('CAPTURE_STORE_MODERN')) return;
    await _font('Roboto', '$_flutterFonts/Roboto-Regular.ttf');
    await _font('MaterialIcons', '$_flutterFonts/MaterialIcons-Regular.otf');
    await _font('serif', '/System/Library/Fonts/NewYork.ttf');
    SharedPreferences.setMockInitialValues({
      TourStore.preferenceKey: true,
      'conversion.mode': 'offline',
      'app.libraryLayout': 'smallCards',
    });
    final temp = Directory.systemTemp.createTempSync('firebrat-modern-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => temp.path);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final books = [
      _b('alice', 'Alice’s Adventures in Wonderland', 'Lewis Carroll', 150, 12),
      _b('pride', 'Pride and Prejudice', 'Jane Austen', 600, 61),
      _b('sherlock', 'The Adventures of Sherlock Holmes', 'Arthur Conan Doyle', 500, 12),
      _b('frank', 'Frankenstein', 'Mary Shelley', 420, 24),
      _b('moby', 'Moby-Dick', 'Herman Melville', 1250, 135),
      _b('dracula', 'Dracula', 'Bram Stoker', 690, 27),
      _b('peter', 'The Tale of Peter Rabbit', 'Beatrix Potter', 8, 3),
      _b('treasure', 'Treasure Island', 'R. L. Stevenson', 480, 34),
      _b('gatsby', 'Great Expectations', 'Charles Dickens', 780, 59),
    ];
    final key = GlobalKey();
    ThemeData roboto(ThemeData t) => t.copyWith(
          appBarTheme: t.appBarTheme.copyWith(
            titleTextStyle: t.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          ),
        );
    Widget app(ThemeData theme) => ProviderScope(
          overrides: [
            localBooksProvider.overrideWith((ref) async => books),
            catalogProvider.overrideWith((ref) async => []),
            for (final b in books) bookCoverProvider(b.bookId).overrideWith((ref) async => null),
          ],
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: theme,
              home: const LibraryScreen(),
            ),
          ),
        );
    Future<void> shot(String name, {double ratio = 3}) async {
      expect(tester.takeException(), isNull);
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await b.toImage(pixelRatio: ratio);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
        img.dispose();
      });
    }

    await tester.pumpWidget(app(roboto(AppTheme.light())));
    await tester.pumpAndSettle();
    await shot('library-light.png');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(roboto(AppTheme.dark())));
    await tester.pumpAndSettle();
    await shot('library-dark.png');

    // Individual covers (for the feature graphic).
    await tester.pumpWidget(const SizedBox());
    final ck = GlobalKey();
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1;
    for (final b in books.take(6)) {
      await tester.pumpWidget(RepaintBoundary(
        key: ck,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 400, height: 600,
              child: BookCover(bookId: b.bookId, title: b.title, author: b.author, radius: 18),
            ),
          ),
        ),
      ));
      await tester.pump();
      final rb = ck.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await rb.toImage(pixelRatio: 2);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/cover-${b.bookId}.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        img.dispose();
      });
    }
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    temp.deleteSync(recursive: true);
  });
}

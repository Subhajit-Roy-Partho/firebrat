import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/state/library_layout_provider.dart';
import 'package:firebrat_app/services/download_manager.dart';
import 'package:firebrat_app/widgets/book_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the library-card bug reports: text escaping the
/// card, unreachable download controls, and the missing long-press menu.
/// RenderFlex overflows surface as test failures via takeException.
BookSummary _book({String title = 'T', String author = ''}) => BookSummary(
  bookId: 'b1',
  title: title,
  author: author,
  totalDurationMs: 99 * 60000,
  sectionCount: 1929,
  sizeBytes: 100,
  updatedAt: '',
);

Future<void> _pumpCard(WidgetTester tester, BookCard card) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 300, height: 400, child: card)),
    ),
  );
  await tester.pump();
}

void main() {
  for (final layout in LibraryLayout.values) {
    testWidgets('$layout supports missing covers and accessible downloads', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: layout == LibraryLayout.list ? 320 : 164,
                height: layout == LibraryLayout.list ? null : 480,
                child: BookCard(
                  layout: layout,
                  book: _book(
                    title: 'Digital design with a very long title',
                    author: 'An author',
                  ),
                  isDownloaded: false,
                  downloadProgress: const DownloadProgress(
                    fraction: .4,
                    receivedBytes: 40,
                    totalBytes: 100,
                    phase: 'downloading',
                  ),
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.bySemanticsLabel('Default book cover'), findsOneWidget);
      expect(find.byTooltip('Cancel and clear download'), findsOneWidget);
    });
  }

  testWidgets('narrow downloading card fits large text and cover', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 390,
            child: BookCard(
              book: _book(
                title: 'A very long title that needs both lines',
                author: 'An author',
              ),
              coverPath: '/nonexistent-cover.png',
              isDownloaded: false,
              downloadProgress: const DownloadProgress(
                fraction: .4,
                receivedBytes: 40,
                totalBytes: 100,
                phase: 'downloading',
              ),
              onTap: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Cancel and clear download'), findsOneWidget);
  });

  testWidgets('long titles stay inside the card', (tester) async {
    await _pumpCard(
      tester,
      BookCard(
        book: _book(
          title:
              'Digital Design and Computer Architecture ARM Edition with a very long subtitle that must wrap',
          author:
              'David Money Harris and Sarah L. Harris with extra names appended',
        ),
        isDownloaded: true,
        downloadProgress: null,
        onTap: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Digital Design'), findsOneWidget);
  });

  testWidgets('downloading card fits pause and cancel controls', (
    tester,
  ) async {
    var paused = 0;
    var cancelled = 0;
    await _pumpCard(
      tester,
      BookCard(
        book: _book(
          title: 'A very long book title that wraps to two full lines here',
        ),
        isDownloaded: false,
        downloadProgress: const DownloadProgress(
          fraction: 0.42,
          receivedBytes: 42,
          totalBytes: 100,
          phase: 'downloading',
        ),
        onTap: () {},
        onPauseDownload: () => paused++,
        onDiscardDownload: () => cancelled++,
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Pause download (tap the book to resume)'));
    await tester.tap(find.byTooltip('Cancel and clear download'));
    expect(paused, 1);
    expect(cancelled, 1);
  });

  testWidgets('long-press fires the action callback', (tester) async {
    var longPressed = 0;
    await _pumpCard(
      tester,
      BookCard(
        book: _book(),
        isDownloaded: true,
        downloadProgress: null,
        onTap: () {},
        onLongPress: () => longPressed++,
      ),
    );
    await tester.longPress(find.byType(BookCard));
    expect(longPressed, 1);
  });

  testWidgets('download ring follows the progress and shows the percentage', (tester) async {
    Future<void> pump(double fraction) => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 164,
                height: 300,
                child: BookCard(
                  layout: LibraryLayout.smallCards,
                  book: _book(title: 'Moving'),
                  isDownloaded: false,
                  downloadProgress: DownloadProgress(
                    fraction: fraction,
                    receivedBytes: (fraction * 100).round(),
                    totalBytes: 100,
                    phase: 'downloading',
                  ),
                  onTap: () {},
                ),
              ),
            ),
          ),
        );
    double ringValue() => tester
        .widget<CircularProgressIndicator>(find.byKey(const ValueKey('download-ring')))
        .value!;

    await pump(0.25);
    await tester.pumpAndSettle();
    expect(ringValue(), closeTo(.25, .001));
    expect(find.text('25%'), findsOneWidget);

    await pump(0.70); // same widget, new progress: the ring must move
    await tester.pumpAndSettle();
    expect(ringValue(), closeTo(.70, .001));
    expect(find.text('70%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

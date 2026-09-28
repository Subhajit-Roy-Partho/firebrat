import 'package:firebrat_app/models/book.dart';
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
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(body: SizedBox(width: 300, height: 400, child: card)),
  ));
  await tester.pump();
}

void main() {
  testWidgets('long titles stay inside the card', (tester) async {
    await _pumpCard(
      tester,
      BookCard(
        book: _book(
          title: 'Digital Design and Computer Architecture ARM Edition with a very long subtitle that must wrap',
          author: 'David Money Harris and Sarah L. Harris with extra names appended',
        ),
        isDownloaded: true,
        downloadProgress: null,
        onTap: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Digital Design'), findsOneWidget);
  });

  testWidgets('downloading card fits pause and cancel controls', (tester) async {
    var paused = 0;
    var cancelled = 0;
    await _pumpCard(
      tester,
      BookCard(
        book: _book(title: 'A very long book title that wraps to two full lines here'),
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
}

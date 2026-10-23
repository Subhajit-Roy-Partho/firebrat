import 'package:firebrat_app/state/library_layout_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:firebrat_app/app.dart';
import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/widgets/book_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('library menu switches between all three layouts', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(overrides: [
      localBooksProvider.overrideWith((ref) async => const <BookSummary>[]),
      catalogProvider.overrideWith((ref) async => [
        for (var i = 0; i < 4; i++) BookSummary(bookId: 'b$i', title: 'Book $i',
          author: 'Author', totalDurationMs: 60000, sectionCount: 5, sizeBytes: 0, updatedAt: ''),
      ]),
    ], child: const FirebratApp()));
    await tester.pumpAndSettle();
    expect(tester.widget<BookCard>(find.byType(BookCard).first).layout, LibraryLayout.smallCards);
    for (final option in [('List', LibraryLayout.list), ('Large cards', LibraryLayout.largeCards),
      ('Small cards', LibraryLayout.smallCards)]) {
      await tester.tap(find.byTooltip('Library layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(option.$1));
      await tester.pumpAndSettle();
      expect(tester.widget<BookCard>(find.byType(BookCard).first).layout, option.$2);
      expect(tester.takeException(), isNull);
    }
  });

  test(
    'small cards default; choice survives a new provider container',
    () async {
      SharedPreferences.setMockInitialValues({});
      final first = ProviderContainer();
      expect(first.read(libraryLayoutProvider), LibraryLayout.smallCards);
      await first
          .read(libraryLayoutProvider.notifier)
          .select(LibraryLayout.list);
      first.dispose();
      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(libraryLayoutProvider);
      await Future<void>.delayed(Duration.zero);
      expect(second.read(libraryLayoutProvider), LibraryLayout.list);
    },
  );
}

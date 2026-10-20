import 'dart:async';

import 'package:firebrat_app/models/book.dart';
import 'package:firebrat_app/models/manifest.dart';
import 'package:firebrat_app/screens/library_screen.dart';
import 'package:firebrat_app/screens/reader_screen.dart';
import 'package:firebrat_app/services/firestore_sync_service.dart';
import 'package:firebrat_app/services/library_repository.dart';
import 'package:firebrat_app/state/library_providers.dart';
import 'package:firebrat_app/state/reader_providers.dart';
import 'package:firebrat_app/state/on_device_conversion_providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LocalRepository implements LibraryRepository {
  @override
  Future<Manifest> loadLocalManifest(String bookId) async => Manifest.fromJson({
    'book_id': bookId,
    'title': 'Offline book',
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PendingSync implements FirestoreSyncService {
  final pending = Completer<void>();
  String? openedBook;

  @override
  Future<void> touchOpened(String bookId) {
    openedBook = bookId;
    return pending.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CloudMode extends ConversionModeNotifier {
  @override
  ConversionModeSettings build() => const ConversionModeSettings(mode: ConversionModePref.cloud);
}

class _IdleReader extends ReaderController {
  _IdleReader(super.bookId);

  @override
  ReaderState? build() => null;
}

void main() {
  testWidgets('downloaded book opens while cloud metadata stays pending', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sync = _PendingSync();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        conversionModeProvider.overrideWith(_CloudMode.new),
        localBooksProvider.overrideWith((ref) async => [const BookSummary(
          bookId: 'offline', title: 'Offline book', author: '',
          totalDurationMs: 60000, sectionCount: 1, sizeBytes: 100, updatedAt: '',
        )]),
        catalogProvider.overrideWith((ref) async => throw Exception('Server offline')),
        bookCoverProvider('offline').overrideWith((ref) async => null),
        libraryRepositoryProvider.overrideWithValue(_LocalRepository()),
        firestoreSyncServiceProvider.overrideWithValue(sync),
        readerControllerProvider('offline').overrideWith(() => _IdleReader('offline')),
      ],
      child: const MaterialApp(home: LibraryScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Offline book'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(sync.openedBook, 'offline');
    expect(sync.pending.isCompleted, isFalse);
    expect(find.byType(ReaderScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    sync.pending.complete();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

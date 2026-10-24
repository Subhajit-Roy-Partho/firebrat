import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebrat_app/models/reading_checkpoint.dart';
import 'package:firebrat_app/services/reading_progress_store.dart';

ReadingCheckpoint checkpoint(
  int time, {
  int position = 1500,
  String signature = 'book',
}) => ReadingCheckpoint(
  sectionId: 'section-one',
  positionMs: position,
  updatedAtMs: time,
  signature: signature,
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'guest progress survives restart and is isolated from signed-in accounts',
    () async {
      await ReadingProgressStore(
        scope: 'guest',
        bookId: 'book',
      ).save(checkpoint(10));
      final restored = await ReadingProgressStore(
        scope: 'guest',
        bookId: 'book',
      ).restore('book');
      expect(restored?.positionMs, 1500);
      expect(
        await ReadingProgressStore(
          scope: 'user-a',
          bookId: 'book',
        ).restore('book'),
        isNull,
      );
    },
  );
  test('newer remote checkpoint wins and is durable offline', () async {
    final first = ReadingProgressStore(scope: 'user', bookId: 'book');
    await first.save(checkpoint(10));
    final remote = ReadingProgressStore(
      scope: 'user',
      bookId: 'book',
      readRemote: () async => checkpoint(20, position: 9000),
    );
    expect((await remote.restore('book'))?.positionMs, 9000);
    final offline = ReadingProgressStore(
      scope: 'user',
      bookId: 'book',
      readRemote: () async => throw StateError('offline'),
    );
    expect((await offline.restore('book'))?.positionMs, 9000);
  });
  test(
    'newer local checkpoint wins and incompatible conversion is ignored',
    () async {
      await ReadingProgressStore(
        scope: 'user',
        bookId: 'book',
      ).save(checkpoint(30));
      final store = ReadingProgressStore(
        scope: 'user',
        bookId: 'book',
        readRemote: () async => checkpoint(20),
      );
      expect((await store.restore('book'))?.updatedAtMs, 30);
      expect(await store.restore('different-conversion'), isNull);
    },
  );
  test('corrupt optional progress never blocks a book', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('reader.checkpoint.guest.book', '{bad json');
    expect(
      await ReadingProgressStore(
        scope: 'guest',
        bookId: 'book',
      ).restore('book'),
      isNull,
    );
  });
  test(
    'cloud writes are throttled, deduplicated and disabled without losing local progress',
    () async {
      var now = DateTime(2026);
      var enabled = true;
      final uploads = <ReadingCheckpoint>[];
      final store = ReadingProgressStore(
        scope: 'user',
        bookId: 'book',
        now: () => now,
        enabled: () async => enabled,
        writeRemote: (value) async {
          uploads.add(value);
          return true;
        },
      );
      await store.save(checkpoint(10));
      await Future<void>.delayed(Duration.zero);
      await store.save(checkpoint(20, position: 3000));
      expect(uploads, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      await store.save(checkpoint(30, position: 3000));
      await Future<void>.delayed(Duration.zero);
      expect(uploads, hasLength(2));
      now = now.add(const Duration(minutes: 2));
      await store.save(checkpoint(40, position: 3000));
      expect(uploads, hasLength(2));
      enabled = false;
      await store.save(checkpoint(50, position: 7000), force: true);
      expect(uploads, hasLength(2));
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(store.key)!)['positionMs'], 7000);
    },
  );
  test(
    'latest pause is retained while an earlier upload is in flight',
    () async {
      var now = DateTime(2026);
      final firstUpload = Completer<bool>();
      final uploads = <ReadingCheckpoint>[];
      final store = ReadingProgressStore(
        scope: 'user',
        bookId: 'book',
        now: () => now,
        writeRemote: (value) async {
          uploads.add(value);
          return uploads.length == 1 ? firstUpload.future : true;
        },
      );
      await store.save(checkpoint(10));
      now = now.add(const Duration(seconds: 20));
      await store.save(checkpoint(20, position: 5000), force: true);
      firstUpload.complete(true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(uploads.map((p) => p.positionMs), [1500, 5000]);
    },
  );
}

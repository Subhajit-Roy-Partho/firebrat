import 'dart:io';
import 'dart:typed_data';
import 'package:firebrat_app/services/source_visual_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;
  late SourceVisualStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('source-visual-test');
    store = SourceVisualStore(directory.path);
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'selection survives reopening and stays attached to its own section',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final saved = await store.save('section/one', 12, bytes);
      final restored = await SourceVisualStore(
        directory.path,
      ).load('section/one');
      expect(restored?.sourcePage, 12);
      expect(restored?.caption, 'Selected from source page 13');
      expect(await File(restored!.imagePath).readAsBytes(), bytes);
      expect(restored.imagePath, saved.imagePath);
      expect(await store.load('section/two'), isNull);
    },
  );

  test(
    'replacing and removing selections clean up the previous crop',
    () async {
      final first = await store.save('one', 0, Uint8List.fromList([1]));
      final second = await store.save('one', 1, Uint8List.fromList([2]));
      expect(await File(first.imagePath).exists(), isFalse);
      expect(await File(second.imagePath).exists(), isTrue);
      await store.remove('one');
      expect(await store.load('one'), isNull);
      expect(await File(second.imagePath).exists(), isFalse);
      await store.remove('one');
    },
  );

  test('a missing crop gracefully falls back to automatic artwork', () async {
    final selection = await store.save('one', 0, Uint8List.fromList([1]));
    await File(selection.imagePath).delete();
    expect(await store.load('one'), isNull);
  });
}

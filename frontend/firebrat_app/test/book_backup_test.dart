import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:firebrat_app/services/book_sync_coordinator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Drive ZIP preserves flat manifest and nested audio and picture bytes',
    () async {
      final root = await Directory.systemTemp.createTemp('firebrat_backup_');
      try {
        final book = await Directory('${root.path}/sample').create();
        await File(
          '${book.path}/manifest.json',
        ).writeAsString('{"book_id":"sample"}');
        await Directory(
          '${book.path}/sections/sec_0001',
        ).create(recursive: true);
        final audio = List.generate(100000, (i) => i % 251);
        await File(
          '${book.path}/sections/sec_0001/audio.wav',
        ).writeAsBytes(audio);
        await Directory('${book.path}/assets').create();
        await File(
          '${book.path}/assets/figure.png',
        ).writeAsBytes([137, 80, 78, 71]);
        final output = File('${root.path}/backup.zip');
        await writeBookBackup(book, output);
        await validateBookBackup(output, 'sample');
        await expectLater(
          validateBookBackup(output, 'other'),
          throwsFormatException,
        );
        final zip = ZipDecoder().decodeBytes(await output.readAsBytes());
        expect(
          utf8.decode(zip.findFile('manifest.json')!.content),
          '{"book_id":"sample"}',
        );
        expect(zip.findFile('sections/sec_0001/audio.wav')!.content, audio);
        expect(zip.findFile('assets/figure.png')!.content, [137, 80, 78, 71]);
        expect(zip.findFile('backup.zip'), isNull);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:firebrat_app/services/import_manager.dart';
import 'package:firebrat_app/utils/tar_stream.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the 1.2 GB import failure: the old import path did
/// `readAsBytes()` + in-memory gzip/tar decode of the whole package and was
/// reliably killed by the OS. The new path ([extractTarGzToDir]) streams
/// entry-by-entry with flat memory, and these tests pin its correctness:
/// layout fidelity, traversal/link rejection, and corrupt-input errors.
Future<File> _makeTarGz(Directory dir, Map<String, List<int>> entries) async {
  final archive = Archive();
  for (final e in entries.entries) {
    archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  final tar = TarEncoder().encode(archive);
  final gz = GZipEncoder().encode(tar);
  final file = File('${dir.path}/book.tar.gz');
  await file.writeAsBytes(gz);
  return file;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tar_stream_test');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('round-trips a book-like layout byte-identical', () async {
    final manifest = utf8.encode('{"book_id":"b1"}');
    final audio = Uint8List.fromList(List.generate(300000, (i) => i % 251));
    final tgz = await _makeTarGz(tmp, {
      'manifest.json': manifest,
      'sections/sec_0001/audio.m4a': audio,
      'sections/sec_0001/segments.json': utf8.encode('{"segments":[]}'),
      'assets/figures/fig_0001.png': utf8.encode('png'),
      'source.pdf': utf8.encode('%PDF'),
    });
    var last = 0.0;
    await extractTarGzToDir(tgz.path, '${tmp.path}/out',
        onProgress: (f) => last = f);
    expect(last, 1.0);
    expect(await File('${tmp.path}/out/manifest.json').readAsBytes(), manifest);
    expect(await File('${tmp.path}/out/sections/sec_0001/audio.m4a').readAsBytes(), audio);
    expect(await File('${tmp.path}/out/source.pdf').readAsString(), '%PDF');
  });

  test('skips absolute paths, .. escapes and symlinks', () async {
    final tgz = await _makeTarGz(tmp, {
      'manifest.json': utf8.encode('{}'),
      '../../evil.txt': utf8.encode('x'),
      '/tmp/abs.txt': utf8.encode('x'),
      'a/../../evil2.txt': utf8.encode('x'),
    });
    // Symlink entry (must never be materialized on extract).
    final archive = Archive();
    archive.addFile(ArchiveFile.symlink('link.m4a', 'sections/sec_0001/audio.m4a'));
    final tar = TarEncoder().encode(archive);
    final file = File('${tmp.path}/evil.tar.gz');
    await file.writeAsBytes(GZipEncoder().encode(tar));
    await extractTarGzToDir(file.path, '${tmp.path}/out2');
    expect(await File('${tmp.path}/evil.txt').exists(), isFalse);
    expect(await File('/tmp/abs.txt').exists(), isFalse);
    expect(await File('${tmp.path}/out2/link.m4a').exists(), isFalse);
    await extractTarGzToDir(tgz.path, '${tmp.path}/out');
    expect(await File('${tmp.path}/out/manifest.json').exists(), isTrue);
    expect(await File('${tmp.path}/evil2.txt').exists(), isFalse);
  });

  test('rejects non-tar input with a readable error', () async {
    final f = File('${tmp.path}/fake.tar.gz');
    await f.writeAsString('this is not a gzip file at all, just text');
    expect(() => extractTarGzToDir(f.path, '${tmp.path}/out'),
        throwsA(isA<TarFormatException>()));
  });

  test('rejects truncated archives', () async {
    final tgz = await _makeTarGz(tmp, {
      'manifest.json': utf8.encode('{"book_id":"b1"}'),
      'sections/sec_0001/audio.m4a':
          Uint8List.fromList(List.generate(100000, (i) => i % 251)),
    });
    final bytes = await tgz.readAsBytes();
    final cut = File('${tmp.path}/cut.tar.gz');
    await cut.writeAsBytes(bytes.sublist(0, bytes.length ~/ 2));
    expect(() => extractTarGzToDir(cut.path, '${tmp.path}/out'),
        throwsA(isA<TarFormatException>()));
  });

  test('handles GNU long names and pax path records', () async {
    // Python's tarfile (which builds our packages) emits pax headers for
    // non-ascii/long names; hand-roll one long name via the archive pkg.
    final longName = 'sections/sec_0001/${'d' * 120}.m4a';
    final tgz = await _makeTarGz(tmp, {
      'manifest.json': utf8.encode('{}'),
      longName: utf8.encode('data'),
    });
    await extractTarGzToDir(tgz.path, '${tmp.path}/out');
    expect(await File('${tmp.path}/out/$longName').readAsString(), 'data');
  });

  test('sanitizeBookId keeps slugs, neutralizes traversal', () {
    expect(sanitizeBookId('digital-design-and-computer-architecture'),
        'digital-design-and-computer-architecture');
    expect(sanitizeBookId('../../etc'), 'etc');
    expect(sanitizeBookId('/abs/path'), 'abs-path');
    expect(sanitizeBookId('My Book! 2026'), 'my-book-2026');
    expect(() => sanitizeBookId(''), throwsA(isA<FormatException>()));
    expect(() => sanitizeBookId('../..'), throwsA(isA<FormatException>()));
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:firebrat_app/services/api_client.dart';
import 'package:firebrat_app/services/download_manager.dart';
import 'package:firebrat_app/services/import_manager.dart';
import 'package:flutter_test/flutter_test.dart';

class TestStorage extends DownloadManager {
  final Directory root;
  TestStorage(this.root) : super(ApiClient(baseUrl: 'http://localhost'));
  @override
  Future<Directory> booksDir() async => root;
}

void main() {
  late Directory root;
  setUp(() async => root = await Directory.systemTemp.createTemp('book_zip_'));
  tearDown(() async => root.delete(recursive: true));

  Future<File> package(Uint8List audio) async {
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', 0,
          utf8.encode('{"book_id":"sample","sections":[]}')))
      ..addFile(ArchiveFile('sections/sec_0001/audio.wav', audio.length, audio));
    return File('${root.path}/sample.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test('download extraction returns only after all audio bytes are committed', () async {
    final audio = Uint8List.fromList(List.generate(2000000, (i) => i % 251));
    final zip = await package(audio);
    final target = Directory('${root.path}/downloaded');
    await TestStorage(root).extractZipToBook(zip.path, target);
    expect(await File('${target.path}/sections/sec_0001/audio.wav').readAsBytes(), audio);
    expect(await Directory('${target.path}.new').exists(), isFalse);
  });

  test('ZIP import waits for extraction before inspecting and moving manifest', () async {
    final audio = Uint8List.fromList(List.generate(1000000, (i) => i % 239));
    final zip = await package(audio);
    expect(await ImportManager(TestStorage(root)).importFromFile(zip), 'sample');
    expect(await File('${root.path}/sample/sections/sec_0001/audio.wav').readAsBytes(), audio);
  });
}

import 'dart:io';

import 'package:firebrat_app/services/api_client.dart';
import 'package:firebrat_app/services/download_manager.dart';
import 'package:firebrat_app/services/import_manager.dart';
import 'package:firebrat_app/services/library_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// On-device import test: streams the real repaired 1.2 GB book package
/// (pushed via adb to the app's external files dir — no permission needed)
/// through [ImportManager.importFromFile] and asserts it lands usable in
/// the local library. This is the exact flow that died before the fix
/// (whole-file `readAsBytes` + in-memory decode → OS kill) and that the
/// repaired book unblocks (all 1929 section audios present).
///
/// Run with the emulator attached:
///   adb push book.tar.gz /sdcard/Android/data/com.firebrat.firebrat_app/files/book.tar.gz
///   flutter test integration_test/import_book_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'imports the real book package into the local library',
    (tester) async {
      final ext = await getExternalStorageDirectory();
      expect(ext, isNotNull, reason: 'no external files dir');
      final archive = File('${ext!.path}/book.tar.gz');
      expect(await archive.exists(), isTrue,
          reason: 'push the book tar.gz to ${ext.path}/book.tar.gz first');

      final dm = DownloadManager(ApiClient(baseUrl: 'http://10.0.2.2:8000'));
      final repo = LibraryRepository(ApiClient(baseUrl: 'http://10.0.2.2:8000'), dm);
      final mgr = ImportManager(dm);

      var lastProgress = 0.0;
      final bookId = await mgr.importFromFile(archive,
          onProgress: (f) => lastProgress = f);
      expect(bookId, 'digital-design-and-computer-architecture');
      expect(lastProgress, 1.0);

      final manifest = await repo.loadLocalManifest(bookId);
      expect(manifest.sections.length, 1929);
      expect(await dm.isDownloaded(bookId), isTrue);
      expect(await dm.listLocalBookIds(), contains(bookId));
      final local = await repo.listLocalBooks();
      expect(local.map((b) => b.bookId), contains(bookId));
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Extracts the espeak-ng data shipped in `flutter_kokoro_tts`'s assets into
/// [dir]/espeak-ng-data (skipped when already there). [dir] is the same parent
/// folder the stock Kokoro engine uses, so the data is shared.
Future<void> ensureEspeakData(String dir) async {
  if (File('$dir/espeak-ng-data/phontab').existsSync()) return;
  final data = await rootBundle.load('packages/flutter_kokoro_tts/assets/espeak_ng_data.zip');
  final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  for (final f in archive) {
    final path = '$dir/${f.name.replaceAll('\\', '/')}';
    if (f.isFile) {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(f.content as List<int>);
    } else {
      Directory(path).createSync(recursive: true);
    }
  }
}

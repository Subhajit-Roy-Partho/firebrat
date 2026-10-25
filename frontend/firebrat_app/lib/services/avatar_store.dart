import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Keeps one profile photo per account on this device. Photos are center-cropped
/// to a square and downscaled to [size] px, so the file stays small enough to
/// upload and cheap to decode in the drawer.
class AvatarStore {
  static const size = 512;
  final Directory? _dirOverride;
  AvatarStore({Directory? directory}) : _dirOverride = directory;

  Future<Directory> _dir() async {
    final base = _dirOverride ?? await getApplicationSupportDirectory();
    final d = Directory('${base.path}/avatars');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// [accountKey] is the Firebase uid, or 'guest'. It is hashed for the
  /// filename so no account identifier appears on disk in clear.
  Future<File> _file(String accountKey) async {
    final name = sha256.convert(accountKey.codeUnits).toString().substring(0, 24);
    return File('${(await _dir()).path}/$name.png');
  }

  Future<File?> load(String accountKey) async {
    final f = await _file(accountKey);
    return await f.exists() ? f : null;
  }

  /// Square-crops and downsizes any decodable image, then stores it as PNG.
  /// Throws [FormatException] when the bytes are not an image.
  Future<File> save(String accountKey, Uint8List source) async {
    final png = await normalize(source);
    final f = await _file(accountKey);
    await f.writeAsBytes(png, flush: true);
    return f;
  }

  Future<void> remove(String accountKey) async {
    final f = await _file(accountKey);
    if (await f.exists()) await f.delete();
  }

  static Future<Uint8List> normalize(Uint8List source, {int target = size}) async {
    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(source);
    } catch (_) {
      throw const FormatException('That file is not a readable image.');
    }
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final side = img.width < img.height ? img.width : img.height;
    final out = side < target ? side : target;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      img,
      ui.Rect.fromLTWH((img.width - side) / 2, (img.height - side) / 2,
          side.toDouble(), side.toDouble()),
      ui.Rect.fromLTWH(0, 0, out.toDouble(), out.toDouble()),
      ui.Paint()..filterQuality = ui.FilterQuality.high,
    );
    final scaled = await recorder.endRecording().toImage(out, out);
    final bytes = await scaled.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    scaled.dispose();
    return bytes!.buffer.asUint8List();
  }
}

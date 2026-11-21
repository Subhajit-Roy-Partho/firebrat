import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../models/visual_item.dart';

/// Local PDF selections live alongside the book, outside its generated manifest.
/// Separate section records also remain valid while a partial book grows.
class SourceVisualStore {
  final Directory directory;
  SourceVisualStore(String bookDirectory)
    : directory = Directory('$bookDirectory/source_selections');

  String _key(String sectionId) =>
      sha256.convert(utf8.encode(sectionId)).toString();
  File _record(String sectionId) =>
      File('${directory.path}/${_key(sectionId)}.json');

  Future<VisualItem?> load(String sectionId) async {
    try {
      final json =
          jsonDecode(await _record(sectionId).readAsString())
              as Map<String, dynamic>;
      final name = json['image'] as String;
      if (name.contains('/') || name.contains('\\')) return null;
      final image = File('${directory.path}/$name');
      if (!await image.exists()) return null;
      return VisualItem(
        id: 'source:$sectionId',
        kind: VisualKind.figure,
        imagePath: image.path,
        caption: json['caption'] as String,
        sourcePage: json['page'] as int,
      );
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<VisualItem> save(String sectionId, int page, Uint8List png) async {
    await directory.create(recursive: true);
    final old = await load(sectionId);
    final name =
        '${_key(sectionId)}_${DateTime.now().microsecondsSinceEpoch}.png';
    final image = File('${directory.path}/$name');
    await image.writeAsBytes(png, flush: true);
    final record = _record(sectionId);
    final temp = File('${record.path}.tmp');
    await temp.writeAsString(
      jsonEncode({
        'image': name,
        'page': page,
        'caption': 'Selected from source page ${page + 1}',
      }),
      flush: true,
    );
    await temp.rename(record.path);
    if (old != null) await _deleteImage(old.imagePath);
    return (await load(sectionId))!;
  }

  Future<void> remove(String sectionId) async {
    final old = await load(sectionId);
    final record = _record(sectionId);
    if (await record.exists()) await record.delete();
    if (old != null) await _deleteImage(old.imagePath);
  }

  Future<void> _deleteImage(String path) async {
    try {
      await File(path).delete();
    } on FileSystemException {
      /* Cosmetic cleanup. */
    }
  }
}

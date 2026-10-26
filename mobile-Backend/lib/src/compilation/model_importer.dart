import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'model_catalog.dart';

/// Import deliberately supports only the selected catalog's single-file Q4_K_M
/// model, not arbitrary architectures, projections, shards or quantizations.
class ModelImporter {
  Future<String> importFile({required String sourcePath, required String pickedName,
      required OnDeviceLlmModel model, required String modelsDir,
      CancelToken? cancelToken, void Function(int received, int total)? onBytes}) async {
    if (pickedName != model.fileName || pickedName.contains('/') || pickedName.contains('\\')) {
      throw FormatException('Select ${model.fileName} for ${model.displayName}. Other models or quantizations cannot be imported into this slot.');
    }
    if (await FileSystemEntity.type(sourcePath, followLinks: false) != FileSystemEntityType.file) {
      throw const FormatException('Choose a regular GGUF file, not a link or folder.');
    }
    final source = File(sourcePath);
    await Isolate.run(() => validateCatalogGguf(sourcePath, model));
    final root = Directory(modelsDir);
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory) {
      throw const FormatException('Model storage cannot be a symbolic link.');
    }
    final canonical = await root.resolveSymbolicLinks();
    final target = '$canonical/${model.fileName}';
    if (await FileSystemEntity.type(target, followLinks: false) == FileSystemEntityType.link) {
      throw const FormatException('Model destination cannot be a symbolic link.');
    }
    final temporary = File('$target.import-${Random.secure().nextInt(0x7fffffff)}.part');
    if (await temporary.exists()) throw StateError('Import temporary file already exists; try again.');
    final total = await source.length();
    var received = 0;
    final sink = temporary.openWrite();
    try {
      await for (final chunk in source.openRead()) {
        if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
        sink.add(chunk); received += chunk.length; onBytes?.call(received, total);
      }
      await sink.flush(); await sink.close();
      if (received != total) throw const FormatException('The selected GGUF changed or was truncated during import.');
      await Isolate.run(() => validateCatalogGguf(temporary.path, model));
      if (cancelToken?.isCancelled ?? false) throw cancelToken!.cancelError!;
      if (await FileSystemEntity.type(target, followLinks: false) == FileSystemEntityType.link) {
        throw const FormatException('Model destination changed during import.');
      }
      // Same-filesystem rename is atomic on Android. Preserve an existing good
      // model until validation succeeds; do not touch a download's .part file.
      await temporary.rename(target);
      return target;
    } catch (_) {
      try { await sink.close(); } catch (_) {}
      if (await temporary.exists()) await temporary.delete();
      rethrow;
    }
  }
}

/// Bounded GGUF v2/v3 parser. Validates every tensor's end offset, so a file
/// truncated inside the 2% catalog size tolerance is still rejected. This is
/// structural validation, not a cryptographic authenticity or inference test.
void validateCatalogGguf(String path, OnDeviceLlmModel model) {
  if (model.fileName.contains('/') || model.fileName.contains('\\') ||
      !model.fileName.endsWith('.gguf')) { throw const FormatException('Invalid catalog model path.'); }
  final length = File(path).lengthSync();
  if ((length - model.approxSizeBytes).abs() >= model.approxSizeBytes * .02) {
    throw FormatException('Wrong file size for ${model.displayName}. Select the catalog Q4_K_M file and ensure its download is complete.');
  }
  final reader = _GgufReader(File(path).openSync(), length);
  try {
    if (reader.u32() != 0x46554747) throw const FormatException('Not a GGUF file.');
    final version = reader.u32();
    if (version != 2 && version != 3) throw const FormatException('Only GGUF version 2 or 3 is supported.');
    final tensors = reader.u64(), fields = reader.u64();
    if (tensors < 1 || tensors > 100000 || fields > 100000) throw const FormatException('Invalid GGUF header counts.');
    final metadata = <String, Object?>{};
    for (var i = 0; i < fields; i++) {
      final key = reader.string(); final type = reader.u32();
      final keep = key == 'general.architecture' || key == 'general.file_type' || key == 'general.alignment' || key == 'split.count';
      metadata[key] = reader.value(type, keep: keep);
      if (reader.position > 128 * 1024 * 1024) throw const FormatException('GGUF metadata is too large.');
    }
    final expected = model.id.startsWith('qwen3-') ? 'qwen3'
        : model.id.startsWith('gemma-3-') ? 'gemma3'
        : model.id.startsWith('phi-') ? 'phi3' : 'llama';
    if (metadata['general.architecture'] != expected || metadata['general.file_type'] != 15 ||
        (metadata['split.count'] is int && (metadata['split.count'] as int) > 1)) {
      throw FormatException('This file is not the selected ${model.displayName} single-file Q4_K_M architecture.');
    }
    final alignment = metadata['general.alignment'] as int? ?? 32;
    if (alignment < 1 || alignment > 4096 || alignment & (alignment - 1) != 0) throw const FormatException('Invalid GGUF alignment.');
    final ranges = <(int, int)>[];
    const sizes = <int, (int, int)>{0:(1,4),1:(1,2),2:(32,18),3:(32,20),6:(32,22),7:(32,24),8:(32,34),10:(256,84),11:(256,110),12:(256,144),13:(256,176),14:(256,210),15:(256,292),30:(1,2)};
    for (var i = 0; i < tensors; i++) {
      reader.string(); final dimensions = reader.u32();
      if (dimensions < 1 || dimensions > 4) throw const FormatException('Invalid GGUF tensor dimensions.');
      final shape = [for (var d = 0; d < dimensions; d++) reader.u64()];
      final type = reader.u32(), offset = reader.u64(); final layout = sizes[type];
      if (layout == null) throw FormatException('Unsupported tensor quantization $type; choose the catalog Q4_K_M file.');
      if (shape.any((n) => n < 1 || n > 100000000) || shape.first % layout.$1 != 0 || offset % alignment != 0) throw const FormatException('Invalid GGUF tensor shape or offset.');
      var bytes = shape.first ~/ layout.$1 * layout.$2;
      for (final n in shape.skip(1)) { bytes *= n; if (bytes > length) throw const FormatException('Truncated GGUF tensor data.'); }
      ranges.add((offset, bytes));
    }
    final dataStart = (reader.position + alignment - 1) ~/ alignment * alignment;
    for (final range in ranges) {
      if (dataStart + range.$1 + range.$2 > length) throw const FormatException('GGUF tensor data is truncated; complete the download first.');
    }
  } finally { reader.file.closeSync(); }
}

class _GgufReader {
  final RandomAccessFile file; final int length;
  int position = 0, _start = -1; Uint8List _buffer = Uint8List(0);
  _GgufReader(this.file, this.length);
  Uint8List read(int count) {
    if (count < 0 || position + count > length) throw const FormatException('Truncated GGUF metadata.');
    if (position < _start || position + count > _start + _buffer.length) {
      file.setPositionSync(position); _start = position; _buffer = file.readSync(max(65536, count));
    }
    final out = Uint8List.sublistView(_buffer, position - _start, position - _start + count); position += count; return out;
  }
  int u32() => ByteData.sublistView(read(4)).getUint32(0, Endian.little);
  int u64() { final n = ByteData.sublistView(read(8)).getUint64(0, Endian.little); if (n < 0) throw const FormatException('Invalid GGUF length.'); return n; }
  void skip(int count) { if (count < 0 || position + count > length) throw const FormatException('Truncated GGUF value.'); position += count; }
  String string() { final n = u64(); if (n > 1024 * 1024) throw const FormatException('GGUF string exceeds limit.'); return utf8.decode(read(n)); }
  Object? value(int type, {bool keep = false}) {
    if (type == 8) { final n = u64(); if (n > 1024 * 1024) throw const FormatException('GGUF string exceeds limit.'); if (keep) return utf8.decode(read(n)); skip(n); return null; }
    if (type == 9) {
      final element = u32(), count = u64();
      if (element == 9 || count > 2000000) throw const FormatException('Unsupported GGUF array.');
      for (var i = 0; i < count; i++) { value(element); } return null;
    }
    const widths = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1,10:8,11:8,12:8};
    final width = widths[type]; if (width == null) throw const FormatException('Unknown GGUF metadata type.');
    if (keep && type == 4) return u32(); if (keep && type == 10) return u64(); skip(width); return null;
  }
}

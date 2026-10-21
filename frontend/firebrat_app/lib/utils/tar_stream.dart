import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Streaming .tar.gz/.tgz extractor with flat memory usage.
///
/// Why this exists instead of `package:archive`'s `TarDecoder`:
/// `TarDecoder.decodeStream` (and `GZipDecoder.decodeBytes` before it)
/// materialize the whole archive — and every entry's bytes — in memory.
/// A 1.2 GB book package therefore needs ~3 GB of transient RAM and is
/// reliably killed on a phone. This reader parses the gzip stream
/// incrementally and writes each entry straight to disk, so peak memory
/// stays under a megabyte no matter the package size.
///
/// Supported: ustar/pax/gnu tar, regular files + directories, GNU `L`
/// longnames and pax `path=` overrides. Skipped (never extracted):
/// absolute paths, `..` escapes, symlinks/hardlinks/dev nodes, and sparse
/// entries (explicit failure — silent misalignment would corrupt the rest).
/// Throws [TarFormatException] on truncated or non-tar input.
Future<void> extractTarGzToDir(
  String tarGzPath,
  String destination, {
  void Function(double fraction)? onProgress,
}) async {
  final total = await File(tarGzPath).length();
  if (total <= 0) {
    throw const TarFormatException('Archive file is empty');
  }
  final outDir = Directory(destination);
  await outDir.create(recursive: true);

  var compressedSeen = 0;
  var lastReported = -1.0;
  void report() {
    if (onProgress == null) return;
    final f = (compressedSeen / total).clamp(0.0, 1.0);
    if (f - lastReported >= 0.005 || f >= 1.0) {
      lastReported = f;
      onProgress(f);
    }
  }

  late StreamIterator<List<int>> it;
  try {
    it = StreamIterator<List<int>>(File(tarGzPath).openRead().map((chunk) {
      compressedSeen += chunk.length;
      report();
      return chunk;
    }).transform(gzip.decoder));
  } on FormatException catch (e) {
    throw TarFormatException('Not a gzip file: ${e.message}');
  }
  final reader = _StreamReader(it);

  String? pendingLongName;
  Map<String, String>? pendingPax;
  Map<String, String>? globalPax;

  try {
    while (true) {
      Uint8List header;
      try {
        header = await reader.readExactly(512);
      } on TarFormatException {
        throw const TarFormatException('Unexpected end of archive (truncated tar header)');
      }
      if (_isZeroBlock(header)) break; // end of archive (1-2 zero blocks)
      _checkChecksum(header);

      final typeFlag = header[156];
      final size = _parseOctal(header, 124, 12, 'size');
      var name = _parseName(header);
      var pax = pendingPax;
      pendingPax = null;
      if (pendingLongName != null) {
        name = pendingLongName;
        pendingLongName = null;
      } else if ((pax ?? globalPax)?['path'] case final paxPath?) {
        name = paxPath;
      }

      if (typeFlag == _gnuLongName || typeFlag == _gnuLongLink) {
        final data = await reader.readFullyBounded(size, 64 * 1024, 'entry name');
        await reader.skipPadding(size);
        final text = utf8.decode(data, allowMalformed: true).split('\x00').first;
        if (typeFlag == _gnuLongName) {
          pendingLongName = text;
        }
        // link targets are never used — links are skipped below.
        continue;
      }
      if (typeFlag == _paxExtended || typeFlag == _paxGlobal) {
        final data = await reader.readFullyBounded(size, 1024 * 1024, 'pax header');
        await reader.skipPadding(size);
        final records = _parsePax(data);
        if (typeFlag == _paxGlobal) {
          globalPax = {...?globalPax, ...records};
        } else {
          pendingPax = records;
        }
        continue;
      }

      final safe = _safeJoin(destination, name);
      if (typeFlag == _dirType) {
        if (safe != null) await Directory(safe).create(recursive: true);
        // directories carry no data; size is 0 by convention.
        continue;
      }
      if (!_isRegularFile(typeFlag)) {
        // Symlinks, hardlinks, dev nodes, sparse files: never materialize
        // user-controlled links, and never guess at exotic layouts.
        if (typeFlag == _gnuSparse) {
          throw const TarFormatException('Sparse tar entries are not supported');
        }
        await reader.skipFully(size);
        await reader.skipPadding(size);
        continue;
      }
      if (safe == null) {
        // Path escape — skip the data, keep the archive position in sync.
        await reader.skipFully(size);
        await reader.skipPadding(size);
        continue;
      }
      final file = File(safe);
      await file.parent.create(recursive: true);
      final sink = file.openWrite();
      try {
        await reader.pipeTo(sink, size);
      } finally {
        await sink.close();
      }
      await reader.skipPadding(size);
    }
  } on FormatException catch (e) {
    // GZip stream errors surface as FormatException mid-iteration.
    throw TarFormatException('Archive is truncated or corrupt: ${e.message}');
  } finally {
    await it.cancel();
  }
  onProgress?.call(1.0);
}

class TarFormatException extends FormatException {
  const TarFormatException([super.message = 'Invalid tar archive']);
}

// tar type flags
const _regularA = 0; // '\0'
const _regularB = 48; // '0'
const _dirType = 53; // '5'
const _gnuLongName = 76; // 'L'
const _gnuLongLink = 75; // 'K'
const _gnuSparse = 83; // 'S'
const _paxExtended = 120; // 'x'
const _paxGlobal = 103; // 'g'

bool _isRegularFile(int flag) => flag == _regularA || flag == _regularB;

bool _isZeroBlock(Uint8List block) {
  for (var i = 0; i < block.length; i++) {
    if (block[i] != 0) return false;
  }
  return true;
}

void _checkChecksum(Uint8List header) {
  var sum = 0;
  for (var i = 0; i < 512; i++) {
    sum += (i >= 148 && i < 156) ? 32 : header[i];
  }
  final stored = _parseOctal(header, 148, 8, 'checksum');
  if (stored != sum) {
    throw const TarFormatException('Not a tar archive (bad header checksum)');
  }
}

int _parseOctal(Uint8List buf, int offset, int length, String field) {
  var end = offset;
  while (end < offset + length && (buf[end] == 0 || buf[end] == 32)) {
    end++;
  }
  var digits = '';
  while (end < offset + length && buf[end] != 0 && buf[end] != 32) {
    digits += String.fromCharCode(buf[end]);
    end++;
  }
  final value = int.tryParse(digits, radix: 8);
  if (value == null || value < 0) {
    throw TarFormatException('Invalid octal $field in tar header');
  }
  return value;
}

String _parseName(Uint8List header) {
  var name = _cString(header, 0, 100);
  final prefix = _cString(header, 345, 155);
  if (prefix.isNotEmpty) name = '$prefix/$name';
  return name;
}

String _cString(Uint8List buf, int offset, int maxLen) {
  var end = offset;
  while (end < offset + maxLen && buf[end] != 0) {
    end++;
  }
  return utf8.decode(buf.sublist(offset, end), allowMalformed: true);
}

/// Joins [name] under [base], returning null for absolute paths or any
/// entry that would escape [base] via `..`.
String? _safeJoin(String base, String name) {
  final normalized = name.replaceAll('\\', '/');
  if (normalized.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    return null;
  }
  final parts = <String>[];
  for (final seg in normalized.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null;
    parts.add(seg);
  }
  if (parts.isEmpty) return null;
  return '${Directory(base).path}/${parts.join('/')}';
}

Map<String, String> _parsePax(Uint8List data) {
  final out = <String, String>{};
  final text = utf8.decode(data, allowMalformed: true);
  var pos = 0;
  while (pos < text.length) {
    final nl = text.indexOf('\n', pos);
    final line = (nl < 0 ? text.substring(pos) : text.substring(pos, nl)).trim();
    pos = nl < 0 ? text.length : nl + 1;
    final sp = line.indexOf(' ');
    final eq = line.indexOf('=');
    if (sp < 0 || eq < 0 || eq < sp) continue;
    out[line.substring(sp + 1, eq)] = line.substring(eq + 1);
  }
  return out;
}

/// Buffered exact-size reader over a chunk stream; holds at most one
/// in-flight chunk plus leftovers (kilobytes, never the archive).
class _StreamReader {
  final StreamIterator<List<int>> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;

  _StreamReader(this._it);

  int get _available => _buf.length - _pos;

  Future<void> _fill(int need) async {
    while (_available < need) {
      if (!await _it.moveNext()) return;
      final chunk = _it.current;
      if (chunk.isEmpty) continue;
      if (_pos == _buf.length) {
        _buf = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        _pos = 0;
      } else {
        final rest = _buf.length - _pos;
        final grown = Uint8List(rest + chunk.length)
          ..setRange(0, rest, _buf, _pos)
          ..setRange(rest, rest + chunk.length, chunk);
        _buf = grown;
        _pos = 0;
      }
    }
  }

  Future<Uint8List> readExactly(int n) async {
    await _fill(n);
    if (_available < n) throw const TarFormatException('Unexpected end of archive');
    final out = Uint8List(n)..setRange(0, n, _buf, _pos);
    _pos += n;
    return out;
  }

  /// Reads exactly [n] bytes, rejecting sizes above [cap] (name/metadata
  /// records must be small; file bodies stream via [pipeTo] instead).
  Future<Uint8List> readFullyBounded(int n, int cap, String what) async {
    if (n > cap) throw TarFormatException('Refusing to buffer oversized tar $what ($n bytes)');
    return readExactly(n);
  }

  /// Streams exactly [n] bytes of entry body to [sink] in buffered pieces
  /// (one small copy per chunk — transient garbage the collector reclaims
  /// promptly, with no buffer lifetimes pinned past the write).
  Future<void> pipeTo(IOSink sink, int n) async {
    var remaining = n;
    while (remaining > 0) {
      if (_available == 0) {
        await _fill(1);
        if (_available == 0) throw const TarFormatException('Unexpected end of archive');
      }
      final take = remaining < _available ? remaining : _available;
      sink.add(_buf.sublist(_pos, _pos + take));
      _pos += take;
      remaining -= take;
    }
  }

  Future<void> skipFully(int n) async {
    var remaining = n;
    while (remaining > 0) {
      if (_available == 0) {
        await _fill(1);
        if (_available == 0) throw const TarFormatException('Unexpected end of archive');
      }
      final take = remaining < _available ? remaining : _available;
      _pos += take;
      remaining -= take;
    }
  }

  Future<void> skipPadding(int size) async {
    final pad = (512 - (size % 512)) % 512;
    if (pad > 0) await readExactly(pad);
  }
}

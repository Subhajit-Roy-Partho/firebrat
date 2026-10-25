import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import '../models/raw_page.dart';
import 'pdf_text_extractor.dart' show ExtractionResult;

/// Reads EPUB, MOBI and AZW/AZW3 books as plain text in reading order, so the
/// normal pipeline (novel mode, compilation, narration) can use them. Mirrors
/// `backend/firebrat/pipeline/ebook.py`. Pictures are not extracted and an
/// ebook has no "source page". Kindle files must be DRM-free and PalmDoc
/// compressed (the common case); anything else raises [EbookException] with a
/// message that is safe to show the user.
const kEbookExtensions = ['.epub', '.mobi', '.azw', '.azw3'];

bool isEbookPath(String path) {
  final lower = path.toLowerCase();
  return kEbookExtensions.any(lower.endsWith);
}

class EbookException implements Exception {
  final String message;
  EbookException(this.message);
  @override
  String toString() => message;
}

class EbookContent {
  final String? title;
  final String? author;
  final List<({String title, String text})> chapters;

  /// The book's own front cover (JPEG, PNG or WebP) when it ships one.
  final ({Uint8List bytes, String ext})? cover;
  const EbookContent(this.title, this.author, this.chapters, {this.cover});
}

class EbookTextExtractor {
  static const pageChars = 1800;

  /// File extension for image bytes the app can show as a cover; null for
  /// anything else (GIF and friends are skipped).
  static String? sniffImage(List<int> d) {
    if (d.length > 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return '.jpg';
    if (d.length > 8 && d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return '.png';
    if (d.length > 12 && String.fromCharCodes(d.sublist(0, 4)) == 'RIFF' && String.fromCharCodes(d.sublist(8, 12)) == 'WEBP') {
      return '.webp';
    }
    return null;
  }

  static Future<EbookContent> read(String path) async {
    final bytes = await File(path).readAsBytes();
    return readBytes(bytes, path);
  }

  static EbookContent readBytes(Uint8List bytes, String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.epub')) return _readEpub(bytes);
    if (lower.endsWith('.mobi') || lower.endsWith('.azw') || lower.endsWith('.azw3')) {
      return _readMobi(bytes);
    }
    throw EbookException('Unsupported ebook format.');
  }

  static Future<ExtractionResult> extractPages(String path) async {
    final content = await read(path);
    return ExtractionResult(pages: chaptersToPages(content.chapters), ocrCandidatePageIndices: const []);
  }

  /// Groups paragraphs into page-sized chunks, each keeping its chapter title.
  static List<RawPage> chaptersToPages(List<({String title, String text})> chapters,
      {int maxChars = pageChars}) {
    final pages = <RawPage>[];
    for (final chapter in chapters) {
      final pieces = <String>[];
      var current = '';
      for (var paragraph in chapter.text.split('\n\n')) {
        while (paragraph.length > maxChars * 2) {
          var cut = paragraph.lastIndexOf('. ', maxChars);
          cut = cut > 0 ? cut + 2 : maxChars;
          pieces.add(paragraph.substring(0, cut));
          paragraph = paragraph.substring(cut);
        }
        if (current.isNotEmpty && current.length + paragraph.length > maxChars) {
          pieces.add(current);
          current = '';
        }
        current = current.isEmpty ? paragraph : '$current\n\n$paragraph';
      }
      if (current.isNotEmpty) pieces.add(current);
      for (var k = 0; k < pieces.length; k++) {
        final suffix = pieces.length > 1 ? ' (${k + 1})' : '';
        pages.add(RawPage(pageIdx: pages.length, text: pieces[k], title: '${chapter.title}$suffix'));
      }
    }
    return pages;
  }

  // ── HTML -> text ────────────────────────────────────────────────────
  static const _block = {
    'p', 'div', 'br', 'li', 'tr', 'section', 'article', 'blockquote', 'pre',
    'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'ul', 'ol', 'table', 'aside',
    'figure', 'mbp:pagebreak',
  };
  static const _skip = {'script', 'style', 'head', 'svg', 'nav'};
  static const _headings = {'h1', 'h2', 'h3'};
  static const _entities = {
    'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
    'mdash': '\u2014', 'ndash': '\u2013', 'hellip': '\u2026', 'lsquo': '\u2018',
    'rsquo': '\u2019', 'ldquo': '\u201C', 'rdquo': '\u201D', 'eacute': '\u00E9',
    'egrave': '\u00E8', 'agrave': '\u00E0', 'aacute': '\u00E1', 'uuml': '\u00FC',
    'ouml': '\u00F6', 'auml': '\u00E4', 'ccedil': '\u00E7', 'ntilde': '\u00F1',
    'copy': '\u00A9', 'deg': '\u00B0', 'times': '\u00D7', 'middot': '\u00B7',
  };

  static String _decode(String s) => s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
        final e = m.group(1)!;
        if (e.startsWith('#x')) return String.fromCharCode(int.parse(e.substring(2), radix: 16));
        if (e.startsWith('#')) return String.fromCharCode(int.parse(e.substring(1)));
        return _entities[e] ?? m.group(0)!;
      });

  /// -> (text with blank lines between blocks, first h1-h3 heading or null)
  static (String, String?) htmlToText(String markup) {
    final out = StringBuffer();
    var skip = 0;
    String? heading;
    StringBuffer? inHeading;
    for (final m in RegExp(r'<!--.*?-->|<[^>]*>|[^<]+', dotAll: true).allMatches(markup)) {
      final token = m.group(0)!;
      if (token.startsWith('<!--')) continue;
      if (token.startsWith('<')) {
        final tag = RegExp(r'^</?\s*([a-zA-Z0-9:]+)').firstMatch(token)?.group(1)?.toLowerCase();
        if (tag == null) continue;
        final closing = token.startsWith('</');
        if (_skip.contains(tag)) {
          skip = closing ? (skip > 0 ? skip - 1 : 0) : skip + 1;
        }
        if (_block.contains(tag)) out.write(tag == 'br' && !closing ? '\n' : '\n\n');
        if (_headings.contains(tag) && heading == null) {
          if (!closing) {
            inHeading = StringBuffer();
          } else if (inHeading != null) {
            final text = inHeading.toString().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
            if (text.isNotEmpty) heading = text;
            inHeading = null;
          }
        }
      } else if (skip == 0) {
        final text = _decode(token);
        out.write(text);
        inHeading?.write(text);
      }
    }
    final paragraphs = out
        .toString()
        .replaceAll('\u00A0', ' ')
        .split(RegExp(r'\n\s*\n'))
        .map((p) => p.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' '))
        .where((p) => p.isNotEmpty)
        .toList();
    return (paragraphs.join('\n\n'), heading);
  }

  // ── EPUB ────────────────────────────────────────────────────────────
  static String _attr(String tag, String name) =>
      RegExp('$name\\s*=\\s*["\']([^"\']*)["\']', caseSensitive: false).firstMatch(tag)?.group(1) ?? '';

  static String _normalize(String path) {
    final parts = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(seg);
      }
    }
    return parts.join('/');
  }

  static EbookContent _readEpub(Uint8List bytes) {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw EbookException('This EPUB is damaged or is not a real EPUB file.');
    }
    ArchiveFile? file(String name) {
      for (final f in archive) {
        if (f.name == name) return f;
      }
      return null;
    }

    String read(ArchiveFile f) => utf8.decode(f.content, allowMalformed: true);
    final enc = file('META-INF/encryption.xml');
    if (enc != null) {
      final algorithms = RegExp(r'Algorithm="([^"]+)"').allMatches(read(enc)).map((m) => m.group(1)!);
      if (algorithms.any((a) => !a.contains('obfuscation'))) {
        throw EbookException('This EPUB is protected by DRM and cannot be converted.');
      }
    }
    final container = file('META-INF/container.xml');
    final opfPath = container == null
        ? ''
        : RegExp(r'full-path\s*=\s*"([^"]+)"').firstMatch(read(container))?.group(1) ?? '';
    final opfFile = opfPath.isEmpty ? null : file(opfPath);
    if (opfFile == null) throw EbookException('This EPUB has no readable package file.');
    final opf = read(opfFile);
    final base = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/')) : '';
    final manifest = <String, ({String href, String media})>{};
    for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final tag = m.group(0)!;
      manifest[_attr(tag, 'id')] = (href: _attr(tag, 'href'), media: _attr(tag, 'media-type'));
    }
    final spine = [
      for (final m in RegExp(r'<itemref\b[^>]*>', caseSensitive: false).allMatches(opf)) _attr(m.group(0)!, 'idref'),
    ];
    String? meta(String tag) => RegExp('<dc:$tag[^>]*>([^<]*)</dc:$tag>', caseSensitive: false)
        .firstMatch(opf)
        ?.group(1)
        ?.trim();
    final chapters = <({String title, String text})>[];
    for (final id in spine) {
      final item = manifest[id];
      if (item == null || item.href.isEmpty || !(item.media.contains('html') || item.media.contains('xml'))) continue;
      final href = Uri.decodeFull(item.href.split('#').first);
      final f = file(_normalize(base.isEmpty ? href : '$base/$href'));
      if (f == null) continue;
      final (text, heading) = htmlToText(read(f));
      if (text.isNotEmpty) chapters.add((title: heading ?? 'Part ${chapters.length + 1}', text: text));
    }
    if (chapters.length > 1 && chapters.first.text.length < 40) chapters.removeAt(0);
    if (chapters.isEmpty) throw EbookException('No readable text was found in this EPUB.');
    final title = meta('title');
    final author = meta('creator');
    ({Uint8List bytes, String ext})? cover;
    try {
      cover = _epubCover(archive, opf, base, manifest);
    } catch (_) {
      cover = null; // a cover is cosmetic; never fail the book over it
    }
    return EbookContent(title == null || title.isEmpty ? null : _decode(title), author == null || author.isEmpty ? null : _decode(author), chapters,
        cover: cover);
  }

  static ({Uint8List bytes, String ext})? _epubCover(Archive archive, String opf, String base,
      Map<String, ({String href, String media})> manifest) {
    ArchiveFile? file(String name) {
      for (final f in archive) {
        if (f.name == name) return f;
      }
      return null;
    }

    String resolve(String dir, String href) =>
        _normalize(dir.isEmpty ? Uri.decodeFull(href.split('#').first) : '$dir/${Uri.decodeFull(href.split('#').first)}');
    final candidates = <String>[];
    // EPUB 2: <meta name="cover" content="item-id"/>
    for (final m in RegExp(r'<meta\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final tag = m.group(0)!;
      if (_attr(tag, 'name') == 'cover') {
        final item = manifest[_attr(tag, 'content')];
        if (item != null) candidates.add(item.href);
      }
    }
    // EPUB 3: properties="cover-image"
    for (final m in RegExp(r'<item\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final tag = m.group(0)!;
      if (_attr(tag, 'properties').split(RegExp(r'\s+')).contains('cover-image')) candidates.add(_attr(tag, 'href'));
    }
    // <guide><reference type="cover"> pointing at a page that wraps the image.
    for (final m in RegExp(r'<reference\b[^>]*>', caseSensitive: false).allMatches(opf)) {
      final tag = m.group(0)!;
      if (_attr(tag, 'type') == 'cover') {
        final page = file(resolve(base, _attr(tag, 'href')));
        if (page != null) {
          final src = RegExp(r'''(?:src|href)\s*=\s*["']([^"']+\.(?:jpe?g|png|webp))["']''', caseSensitive: false)
              .firstMatch(utf8.decode(page.content, allowMalformed: true))
              ?.group(1);
          if (src != null) {
            final pageDir = _attr(tag, 'href').contains('/') ? _attr(tag, 'href').substring(0, _attr(tag, 'href').lastIndexOf('/')) : '';
            candidates.add(pageDir.isEmpty ? src : '$pageDir/$src');
          }
        }
      }
    }
    // Last resort: any image whose path says "cover".
    for (final item in manifest.values) {
      if (item.media.contains('image') && item.href.toLowerCase().contains('cover')) candidates.add(item.href);
    }
    for (final href in candidates) {
      final f = href.isEmpty ? null : file(resolve(base, href));
      if (f == null) continue;
      final bytes = Uint8List.fromList(f.content);
      final ext = sniffImage(bytes);
      if (ext != null) return (bytes: bytes, ext: ext);
    }
    return null;
  }

  static ({Uint8List bytes, String ext})? _mobiCover(Uint8List data, Uint8List r0, ByteData bd, int recordCount, Uint8List Function(int) rec) {
    if (r0.length < 112) return null;
    final r0d = ByteData.sublistView(r0);
    final headerLen = r0d.getUint32(20);
    final firstImage = r0d.getUint32(108);
    if (firstImage >= recordCount) return null;
    int? coverOffset;
    final exth = 16 + headerLen;
    if (r0.length > exth + 12 && String.fromCharCodes(r0.sublist(exth, exth + 4)) == 'EXTH') {
      final n = r0d.getUint32(exth + 8);
      var pos = exth + 12;
      for (var i = 0; i < n && pos + 8 <= r0.length; i++) {
        final type = r0d.getUint32(pos), len = r0d.getUint32(pos + 4);
        if (type == 201 && len >= 12 && pos + 12 <= r0.length) coverOffset = r0d.getUint32(pos + 8);
        pos += len < 8 ? 8 : len;
      }
    }
    final order = [
      if (coverOffset != null) firstImage + coverOffset,
      for (var i = firstImage; i < recordCount && i < firstImage + 12; i++) i,
    ];
    for (final index in order) {
      if (index < 0 || index >= recordCount) continue;
      final blob = rec(index);
      final ext = sniffImage(blob);
      if (ext != null) return (bytes: Uint8List.fromList(blob), ext: ext);
    }
    return null;
  }

  // ── MOBI / AZW / AZW3 (PalmDoc) ─────────────────────────────────────
  static Uint8List palmDocDecompress(Uint8List data) {
    final out = BytesBuilder(copy: false);
    final buf = <int>[];
    var i = 0;
    while (i < data.length) {
      final c = data[i++];
      if (c == 0 || (c >= 9 && c <= 0x7F)) {
        buf.add(c);
      } else if (c >= 1 && c <= 8) {
        for (var k = 0; k < c && i < data.length; k++) {
          buf.add(data[i++]);
        }
      } else if (c >= 0xC0) {
        buf.add(0x20);
        buf.add(c ^ 0x80);
      } else {
        if (i >= data.length) break;
        final pair = (c << 8) | data[i++];
        final distance = (pair >> 3) & 0x7FF;
        final length = (pair & 7) + 3;
        if (distance == 0 || distance > buf.length) continue;
        for (var k = 0; k < length; k++) {
          buf.add(buf[buf.length - distance]);
        }
      }
    }
    out.add(buf);
    return out.toBytes();
  }

  static int _trailingSize(Uint8List record, int flags) {
    var size = 0;
    var f = flags >> 1;
    while (f != 0) {
      if ((f & 1) != 0) {
        var pos = record.length - size;
        var shift = 0, value = 0;
        while (pos > 0) {
          final b = record[pos - 1];
          value |= (b & 0x7F) << shift;
          shift += 7;
          pos--;
          if ((b & 0x80) != 0 || shift >= 28) break;
        }
        size += value;
      }
      f >>= 1;
    }
    if ((flags & 1) != 0 && record.length - size - 1 >= 0) {
      size += (record[record.length - size - 1] & 3) + 1;
    }
    return size;
  }

  static EbookContent _readMobi(Uint8List data) {
    String ascii(int a, int b) => String.fromCharCodes(data.sublist(a, b));
    if (data.length < 80 || (ascii(60, 68) != 'BOOKMOBI' && ascii(60, 68) != 'TEXtREAd')) {
      throw EbookException('This does not look like a Kindle or MOBI book (it may be a different format with the wrong extension).');
    }
    final bd = ByteData.sublistView(data);
    final recordCount = bd.getUint16(76);
    final offsets = [for (var i = 0; i < recordCount; i++) bd.getUint32(78 + 8 * i), data.length];
    Uint8List rec(int i) => Uint8List.sublistView(data, offsets[i], offsets[i + 1]);
    final r0 = rec(0);
    final r0d = ByteData.sublistView(r0);
    final compression = r0d.getUint16(0);
    final textRecords = r0d.getUint16(8);
    final encryption = r0d.getUint16(12);
    if (encryption != 0) {
      throw EbookException('This Kindle book is protected by DRM and cannot be converted. Remove the DRM with your own tools, or import a DRM-free copy.');
    }
    if (compression != 1 && compression != 2) {
      throw EbookException('This Kindle book uses an unsupported compression (HUFF/CDIC). Convert it to EPUB first, for example with Calibre.');
    }
    var flags = 0, encoding = 1252;
    String? fullName;
    if (r0.length >= 20 && String.fromCharCodes(r0.sublist(16, 20)) == 'MOBI') {
      final headerLen = r0d.getUint32(20);
      encoding = r0d.getUint32(28);
      if (headerLen >= 228 && r0.length >= 244) flags = r0d.getUint16(242);
      if (r0.length >= 92) {
        final off = r0d.getUint32(84), len = r0d.getUint32(88);
        if (off > 0 && len > 0 && off + len <= r0.length) {
          fullName = _decodeText(Uint8List.sublistView(r0, off, off + len), encoding).trim();
          if (fullName.isEmpty) fullName = null;
        }
      }
    }
    final text = BytesBuilder();
    final last = textRecords < recordCount - 1 ? textRecords : recordCount - 1;
    for (var i = 1; i <= last; i++) {
      var record = rec(i);
      if (flags != 0) record = Uint8List.sublistView(record, 0, record.length - _trailingSize(record, flags));
      text.add(compression == 2 ? palmDocDecompress(record) : record);
    }
    final markup = _decodeText(text.toBytes(), encoding);
    final chapters = <({String title, String text})>[];
    for (final part in markup.split(RegExp(r'<mbp:pagebreak\s*/?>', caseSensitive: false))) {
      final (t, heading) = htmlToText(part);
      if (t.isNotEmpty) chapters.add((title: heading ?? 'Part ${chapters.length + 1}', text: t));
    }
    if (chapters.isEmpty) {
      throw EbookException('No readable text was found in this book. It may be DRM-protected or use an unsupported layout.');
    }
    ({Uint8List bytes, String ext})? cover;
    try {
      cover = _mobiCover(data, r0, bd, recordCount, rec);
    } catch (_) {
      cover = null;
    }
    return EbookContent(fullName, null, chapters, cover: cover);
  }

  static String _decodeText(Uint8List bytes, int encoding) =>
      encoding == 65001 ? utf8.decode(bytes, allowMalformed: true) : latin1.decode(bytes);
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';

const _ch1 = '<html><body><h1>The Beginning</h1><p>“Come in,” Alice said.</p><p>She opened the door slowly.</p></body></html>';
const _ch2 = '<html><body><h2>The Garden</h2><p>“No,” Bob replied.</p><p>The roses were red &amp; tall.</p><script>evil()</script></body></html>';

final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...utf8.encode('cover-image-bytes')]);
final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...utf8.encode('jpeg-bytes')]);
final gif = Uint8List.fromList(utf8.encode('GIF89a-gif-bytes'));

Uint8List makeEpub({bool drm = false, Uint8List? cover, String style = 'meta'}) {
  final a = Archive();
  void add(String name, String content) => a.addFile(ArchiveFile.bytes(name, utf8.encode(content)));
  add('mimetype', 'application/epub+zip');
  add('META-INF/container.xml',
      '<container><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>');
  if (drm) {
    add('META-INF/encryption.xml',
        '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></EncryptedData></encryption>');
  }
  var meta = '', extraItem = '', guide = '';
  if (cover != null) {
    a.addFile(ArchiveFile.bytes('OEBPS/images/front.png', cover));
    if (style == 'meta') {
      meta = '<meta name="cover" content="cvr"/>';
      extraItem = '<item id="cvr" href="images/front.png" media-type="image/png"/>';
    } else if (style == 'epub3') {
      extraItem = '<item id="x" href="images/front.png" media-type="image/png" properties="cover-image"/>';
    } else {
      add('OEBPS/cover.xhtml', '<html><body><img src="images/front.png" alt="c"/></body></html>');
      guide = '<guide><reference type="cover" title="Cover" href="cover.xhtml"/></guide>';
    }
  }
  add('OEBPS/content.opf',
      '<package><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>A Tiny Tale</dc:title><dc:creator>Someone</dc:creator>$meta</metadata>'
      '<manifest><item id="b" href="text/two.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="a" href="text/one.xhtml" media-type="application/xhtml+xml"/>'
      '<item id="css" href="s.css" media-type="text/css"/>$extraItem</manifest>'
      '<spine><itemref idref="a"/><itemref idref="b"/></spine>$guide</package>');
  add('OEBPS/text/one.xhtml', _ch1);
  add('OEBPS/text/two.xhtml', _ch2);
  return Uint8List.fromList(ZipEncoder().encode(a));
}

Uint8List _palmCompress(List<int> data) {
  final out = <int>[];
  for (final b in data) {
    if (b < 0x80 && !(b >= 1 && b <= 8)) {
      out.add(b);
    } else {
      out.addAll([1, b]);
    }
  }
  return Uint8List.fromList(out);
}

Uint8List makeMobi(String markup,
    {int compression = 2, int encryption = 0, int flags = 0, String name = 'Tiny Kindle Book', Uint8List? cover, List<Uint8List> extraImages = const []}) {
  final text = utf8.encode(markup);
  const size = 4096;
  final pieces = [for (var i = 0; i < text.length; i += size) text.sublist(i, i + size > text.length ? text.length : i + size)];
  final records = [
    for (final p in pieces) Uint8List.fromList([...(compression == 2 ? _palmCompress(p) : p), if (flags & 1 != 0) 0]),
  ];
  final images = [...extraImages, if (cover != null) cover];
  final nameBytes = utf8.encode(name);
  var exth = <int>[];
  if (cover != null) {
    final rec = ByteData(12)
      ..setUint32(0, 201)
      ..setUint32(4, 12)
      ..setUint32(8, extraImages.length);
    final head = ByteData(12)
      ..setUint32(4, 12 + 12)
      ..setUint32(8, 1);
    exth = [...'EXTH'.codeUnits, ...head.buffer.asUint8List(4), ...rec.buffer.asUint8List()];
  }
  final r0 = ByteData(16 + 232);
  r0.setUint16(0, compression);
  r0.setUint32(4, text.length);
  r0.setUint16(8, pieces.length);
  r0.setUint16(10, size);
  r0.setUint16(12, encryption);
  for (var i = 0; i < 4; i++) {
    r0.setUint8(16 + i, 'MOBI'.codeUnitAt(i));
  }
  r0.setUint32(20, 232);
  r0.setUint32(28, 65001);
  r0.setUint32(84, 16 + 232 + exth.length);
  r0.setUint32(88, nameBytes.length);
  r0.setUint32(108, images.isEmpty ? 0xFFFFFFFF : 1 + records.length);
  r0.setUint16(242, flags);
  final all = [Uint8List.fromList([...r0.buffer.asUint8List(), ...exth, ...nameBytes]), ...records, ...images];
  final pdb = ByteData(78 + 8 * all.length + 2);
  for (var i = 0; i < 8; i++) {
    pdb.setUint8(60 + i, 'BOOKMOBI'.codeUnitAt(i));
  }
  pdb.setUint16(76, all.length);
  var offset = 78 + 8 * all.length + 2;
  for (var i = 0; i < all.length; i++) {
    pdb.setUint32(78 + 8 * i, offset);
    pdb.setUint32(82 + 8 * i, 2 * i);
    offset += all[i].length;
  }
  return Uint8List.fromList([...pdb.buffer.asUint8List(), for (final r in all) ...r]);
}

const book = '<html><body><h1>Chapter One</h1><p>“Hello,” Alice said.</p><mbp:pagebreak/><h1>Chapter Two</h1><p>“Bye,” Bob replied.</p><p>Café “quoted” — done.</p></body></html>';

void main() {
  pdfCoverTests();
  test('EPUB: spine order, titles, entities, scripts ignored', () {
    final c = EbookTextExtractor.readBytes(makeEpub(), 'a.epub');
    expect((c.title, c.author), ('A Tiny Tale', 'Someone'));
    expect(c.chapters.map((x) => x.title), ['The Beginning', 'The Garden']);
    expect(c.chapters[1].text, isNot(contains('evil')));
    expect(c.chapters[1].text, contains('red & tall'));
    expect(c.chapters[0].text, startsWith('The Beginning\n\n“Come in,” Alice said.\n\nShe opened'));
  });

  test('EPUB with DRM or damaged zip gives a plain message', () {
    expect(() => EbookTextExtractor.readBytes(makeEpub(drm: true), 'd.epub'),
        throwsA(isA<EbookException>().having((e) => e.message, 'm', contains('DRM'))));
    expect(() => EbookTextExtractor.readBytes(Uint8List.fromList([1, 2, 3]), 'x.epub'), throwsA(isA<EbookException>()));
  });

  for (final ext in ['.mobi', '.azw', '.azw3']) {
    for (final cfg in [(2, 0), (1, 0), (2, 1)]) {
      test('Kindle $ext compression ${cfg.$1} flags ${cfg.$2}', () {
        final c = EbookTextExtractor.readBytes(makeMobi(book, compression: cfg.$1, flags: cfg.$2), 'k$ext');
        expect(c.title, 'Tiny Kindle Book');
        expect(c.chapters.map((x) => x.title), ['Chapter One', 'Chapter Two']);
        expect(c.chapters[0].text, contains('“Hello,” Alice said.'));
        expect(c.chapters[1].text, contains('Café “quoted” — done.'));
      });
    }
  }

  test('Kindle DRM, HUFF/CDIC and non-books are explained', () {
    expect(() => EbookTextExtractor.readBytes(makeMobi(book, encryption: 2), 'd.azw'),
        throwsA(isA<EbookException>().having((e) => e.message, 'm', contains('DRM'))));
    expect(() => EbookTextExtractor.readBytes(makeMobi(book, compression: 17480), 'h.mobi'),
        throwsA(isA<EbookException>().having((e) => e.message, 'm', contains('HUFF/CDIC'))));
    expect(() => EbookTextExtractor.readBytes(Uint8List(200), 'x.mobi'),
        throwsA(isA<EbookException>().having((e) => e.message, 'm', contains('does not look like'))));
  });

  test('PalmDoc back-references and space-char codes', () {
    final pair = 0x8000 | (3 << 3);
    expect(utf8.decode(EbookTextExtractor.palmDocDecompress(Uint8List.fromList([...'abc'.codeUnits, pair >> 8, pair & 0xFF]))), 'abcabc');
    expect(EbookTextExtractor.palmDocDecompress(Uint8List.fromList([0xC1])), [0x20, 0x41]);
  });

  test('pages keep chapter titles and every character', () {
    final text = List.generate(30, (i) => 'Paragraph $i ${'word ' * 60}').join('\n\n');
    final pages = EbookTextExtractor.chaptersToPages([(title: 'Long', text: text), (title: 'Short', text: 'Tiny.')]);
    expect(pages.length, greaterThan(3));
    expect(pages.first.title, 'Long (1)');
    expect(pages.last.title, 'Short');
    expect([for (var i = 0; i < pages.length; i++) pages[i].pageIdx], List.generate(pages.length, (i) => i));
    String squash(String s) => s.replaceAll(RegExp(r'\s'), '');
    expect(squash(pages.take(pages.length - 1).map((p) => p.text).join()), squash(text));
  });

  test('novel mode on an ebook: chapter titles survive chunking and merging; speakers are found', () {
    final pages = EbookTextExtractor.chaptersToPages(EbookTextExtractor.readBytes(makeEpub(), 'a.epub').chapters);
    final merged = mergeExtractions([ExtractionResult(pages: pages, ocrCandidatePageIndices: const [])]);
    final chunks = chunkLocalPages(merged.pages);
    expect(chunks.map((c) => c.pages.single.title), ['The Beginning', 'The Garden']);
    final plan = NovelBookPlan.analyze(merged.pages);
    expect(plan.characters.map((c) => c.name).toSet(), {'Alice', 'Bob'});
  });

  for (final style in ['meta', 'epub3', 'guide']) {
    test('EPUB front cover found via $style convention', () {
      final c = EbookTextExtractor.readBytes(makeEpub(cover: png, style: style), 'a.epub');
      expect(c.cover, isNotNull);
      expect(c.cover!.ext, '.png');
      expect(c.cover!.bytes, png);
    });
  }

  test('no cover, or an unsupported image, means no cover (and the book still reads)', () {
    expect(EbookTextExtractor.readBytes(makeEpub(), 'a.epub').cover, isNull);
    final withGif = EbookTextExtractor.readBytes(makeEpub(cover: gif), 'a.epub');
    expect(withGif.cover, isNull);
    expect(withGif.chapters, isNotEmpty);
  });

  for (final ext in ['.mobi', '.azw', '.azw3']) {
    test('Kindle $ext cover follows the EXTH offset, not just the first image', () {
      final c = EbookTextExtractor.readBytes(makeMobi(book, cover: jpg, extraImages: [png]), 'k$ext');
      expect(c.cover?.ext, '.jpg');
      expect(c.cover?.bytes, jpg);
      expect(EbookTextExtractor.readBytes(makeMobi(book), 'k$ext').cover, isNull);
    });
  }

  test('book ids drop ebook extensions', () {
    expect(sanitizeBookId('My Book.EPUB'), 'my-book');
    expect(sanitizeBookId('x.azw3'), 'x');
    expect(isEbookPath('/a/b.AZW'), isTrue);
    expect(isEbookPath('/a/b.pdf'), isFalse);
  });
}

void pdfCoverTests() {
  test('only sparse first pages look like a cover', () {
    expect(PageVisuals.looksLikeCover(''), isTrue);
    expect(PageVisuals.looksLikeCover('A Title\nBy Someone'), isTrue);
    expect(PageVisuals.looksLikeCover('Chapter 1. ${'body text ' * 30}'), isFalse);
  });
}

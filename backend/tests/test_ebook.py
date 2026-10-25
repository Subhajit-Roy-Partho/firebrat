import json
import os
import struct
import zipfile

import pytest
from fastapi.testclient import TestClient

from firebrat.pipeline import ebook
from firebrat.pipeline.novel import compile_novel
from server import config, job_runner
from server.main import app

CH1 = '<html><body><h1>The Beginning</h1><p>“Come in,” Alice said.</p><p>She opened the door slowly.</p></body></html>'
CH2 = '<html><body><h2>The Garden</h2><p>“No,” Bob replied.</p><p>The roses were red &amp; tall.</p><script>evil()</script></body></html>'


PNG = b'\x89PNG\r\n\x1a\n' + b'cover-image-bytes'
JPG = b'\xff\xd8\xff\xe0' + b'jpeg-bytes'
GIF = b'GIF89a' + b'gif-bytes'


def make_epub(path, drm=False, cover=None, style='meta'):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('mimetype', 'application/epub+zip')
        z.writestr('META-INF/container.xml',
                   '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
                   '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        if drm:
            z.writestr('META-INF/encryption.xml',
                       '<encryption><EncryptedData><EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>'
                       '</EncryptedData></encryption>')
        meta = extra_item = guide = ''
        if cover is not None:
            z.writestr('OEBPS/images/front.png', cover)
            if style == 'meta':      # EPUB 2
                meta = '<meta name="cover" content="cvr"/>'
                extra_item = '<item id="cvr" href="images/front.png" media-type="image/png"/>'
            elif style == 'epub3':   # EPUB 3
                extra_item = '<item id="x" href="images/front.png" media-type="image/png" properties="cover-image"/>'
            else:                    # <guide> reference to a cover page wrapping the image
                z.writestr('OEBPS/cover.xhtml', '<html><body><img src="images/front.png" alt="c"/></body></html>')
                guide = '<guide><reference type="cover" title="Cover" href="cover.xhtml"/></guide>'
        z.writestr('OEBPS/content.opf',
                   '<package xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
                   '<dc:title>A Tiny Tale</dc:title><dc:creator>Someone</dc:creator>' + meta + '</metadata>'
                   '<manifest><item id="b" href="text/two.xhtml" media-type="application/xhtml+xml"/>'
                   '<item id="a" href="text/one.xhtml" media-type="application/xhtml+xml"/>'
                   '<item id="css" href="s.css" media-type="text/css"/>' + extra_item + '</manifest>'
                   '<spine><itemref idref="a"/><itemref idref="b"/></spine>' + guide + '</package>')
        z.writestr('OEBPS/text/one.xhtml', CH1)
        z.writestr('OEBPS/text/two.xhtml', CH2)


def _palm_compress(data):
    """Valid PalmDoc stream using only literals (enough to exercise the reader)."""
    out = bytearray()
    for byte in data:
        if byte < 0x80 and not 1 <= byte <= 8:
            out.append(byte)
        else:
            out += bytes([1, byte])
    return bytes(out)


def make_mobi(path, markup, compression=2, encryption=0, flags=0, encoding=65001, name='Tiny Kindle Book', cover=None, extra_images=()):
    text = markup.encode('utf-8' if encoding == 65001 else 'cp1252')
    size = 4096
    pieces = [text[i:i + size] for i in range(0, len(text), size)] or [b'']
    records = []
    for p in pieces:
        r = _palm_compress(p) if compression == 2 else p
        records.append(r + (b'\x00' if flags & 1 else b''))
    header = struct.pack('>HHIHHHH', compression, 0, len(text), len(pieces), size, encryption, 0)
    mobi = bytearray(232)
    mobi[0:4] = b'MOBI'
    struct.pack_into('>I', mobi, 4, 232)
    struct.pack_into('>I', mobi, 12, encoding)
    images = list(extra_images) + ([cover] if cover is not None else [])
    first_image = 1 + len(records)
    struct.pack_into('>I', mobi, 92, first_image if images else 0xFFFFFFFF)
    struct.pack_into('>H', mobi, 226, flags)                           # extra record data flags
    exth = b''
    if cover is not None:                                              # EXTH record 201 = cover offset among images
        recs = struct.pack('>III', 201, 12, len(extra_images))
        exth = b'EXTH' + struct.pack('>II', 12 + len(recs), 1) + recs
    name_b = name.encode('utf-8')
    struct.pack_into('>II', mobi, 68, 16 + 232 + len(exth), len(name_b))
    r0 = header + bytes(mobi) + exth + name_b
    all_records = [r0] + records + images
    pdb = bytearray(78)
    pdb[0:len(name)] = name.encode('ascii')[:31]
    pdb[60:68] = b'BOOKMOBI'
    struct.pack_into('>H', pdb, 76, len(all_records))
    offset = 78 + 8 * len(all_records) + 2
    table = bytearray()
    for i, r in enumerate(all_records):
        table += struct.pack('>II', offset, 2 * i)
        offset += len(r)
    with open(path, 'wb') as f:
        f.write(bytes(pdb) + bytes(table) + b'\x00\x00' + b''.join(all_records))


BOOK = '<html><body><h1>Chapter One</h1><p>“Hello,” Alice said.</p><mbp:pagebreak/><h1>Chapter Two</h1><p>“Bye,” Bob replied.</p><p>Café “quoted” — done.</p></body></html>'


def test_epub_reads_spine_order_titles_and_ignores_scripts(tmp_path):
    p = tmp_path / 'a.epub'
    make_epub(p)
    title, author, chapters = ebook.read_epub(str(p))
    assert (title, author) == ('A Tiny Tale', 'Someone')
    assert [c[0] for c in chapters] == ['The Beginning', 'The Garden']      # spine order, not manifest order
    assert 'evil' not in chapters[1][1] and 'red & tall' in chapters[1][1]
    # the chapter heading is part of the text, so the narrator announces it
    assert chapters[0][1].startswith('The Beginning\n\n“Come in,” Alice said.\n\nShe opened')


def test_drm_epub_is_refused_clearly(tmp_path):
    p = tmp_path / 'drm.epub'
    make_epub(p, drm=True)
    with pytest.raises(ebook.EbookError, match='DRM'):
        ebook.read_epub(str(p))


@pytest.mark.parametrize('ext', ['.mobi', '.azw', '.azw3'])
@pytest.mark.parametrize('compression,flags', [(2, 0), (1, 0), (2, 1)])
def test_mobi_family_roundtrip(tmp_path, ext, compression, flags):
    p = tmp_path / f'k{ext}'
    make_mobi(p, BOOK, compression=compression, flags=flags)
    title, _author, chapters = ebook.read_ebook(str(p))
    assert title == 'Tiny Kindle Book'
    assert [c[0] for c in chapters] == ['Chapter One', 'Chapter Two']
    assert '“Hello,” Alice said.' in chapters[0][1]
    assert 'Café “quoted” — done.' in chapters[1][1]


def test_mobi_drm_and_unsupported_compression_are_explained(tmp_path):
    p = tmp_path / 'd.azw'
    make_mobi(p, BOOK, encryption=2)
    with pytest.raises(ebook.EbookError, match='DRM'):
        ebook.read_ebook(str(p))
    make_mobi(p, BOOK, compression=17480)
    with pytest.raises(ebook.EbookError, match='HUFF/CDIC'):
        ebook.read_ebook(str(p))
    (tmp_path / 'x.mobi').write_bytes(b'not a book' * 20)
    with pytest.raises(ebook.EbookError, match='does not look like'):
        ebook.read_ebook(str(tmp_path / 'x.mobi'))


def test_palmdoc_back_references():
    # "abc" then a copy of 3 bytes from distance 3 -> "abcabc"
    pair = (0x8000 | (3 << 3) | 0)  # distance 3, length 3
    assert ebook._palmdoc_decompress(b'abc' + bytes([pair >> 8, pair & 0xFF])) == b'abcabc'
    assert ebook._palmdoc_decompress(bytes([0xC1])) == b' A'              # space + char


def test_pages_keep_chapter_titles_and_all_text(tmp_path):
    text = '\n\n'.join(f'Paragraph {i} ' + 'word ' * 60 for i in range(30))
    pages = ebook.chapters_to_pages([('Long', text), ('Short', 'Tiny.')])
    assert len(pages) > 3 and [p['page_idx'] for p in pages] == list(range(len(pages)))
    assert pages[0]['title'] == 'Long (1)' and pages[-1]['title'] == 'Short'
    assert ''.join(p['text'].replace('\n', '').replace(' ', '') for p in pages[:-1]) == text.replace('\n', '').replace(' ', '')


def test_novel_mode_uses_chapter_titles_and_speakers(tmp_path):
    p = tmp_path / 'a.epub'
    make_epub(p)
    raw = {'pages': ebook.chapters_to_pages(ebook.read_epub(str(p))[2])}
    compiled = compile_novel(raw)
    assert [s['title'] for s in compiled['sections']] == ['The Beginning', 'The Garden']
    assert {c['name'] for c in compiled['character_roster']} == {'Alice', 'Bob'}


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(config, 'UPLOAD_DIR', str(tmp_path / 'up'))
    monkeypatch.setattr(config, 'OUTPUT_DIR', str(tmp_path / 'out'))
    monkeypatch.setattr(config, 'JOBS_DB_PATH', str(tmp_path / 'jobs.sqlite3'))
    monkeypatch.setattr(job_runner, 'enqueue', lambda *a, **k: None)
    with TestClient(app) as client:
        yield client


def test_upload_accepts_ebooks_and_rejects_bad_or_drm_ones(api, tmp_path):
    epub, mobi, drm = tmp_path / 'a.epub', tmp_path / 'k.azw3', tmp_path / 'd.epub'
    make_epub(epub)
    make_mobi(mobi, BOOK)
    make_epub(drm, drm=True)
    for path in (epub, mobi):
        r = api.post('/books/upload', files={'file': (path.name, path.read_bytes(), 'application/octet-stream')},
                     data={'content_mode': 'novel'})
        assert r.status_code == 200, r.text
        assert r.json()['filename'] == path.name
        saved = [f for f in os.listdir(config.UPLOAD_DIR) if f.endswith(path.suffix)]
        assert saved, 'ebook keeps its extension so convert.py picks the right reader'
    bad = api.post('/books/upload', files={'file': ('d.epub', drm.read_bytes(), 'application/epub+zip')})
    assert bad.status_code == 400 and 'DRM' in bad.json()['detail']
    assert api.post('/books/upload', files={'file': ('n.txt', b'hi', 'text/plain')}).status_code == 400


def test_convert_cli_extracts_an_epub_into_raw_pages(tmp_path):
    from firebrat.pipeline.ebook import run_ebook_extraction
    p = tmp_path / 'a.epub'
    make_epub(p)
    stats = run_ebook_extraction(str(p), str(tmp_path / 'pkg'), 'a')
    raw = json.loads(open(stats['raw_pages_json']).read())
    assert raw['page_count'] == 2 and raw['pages'][0]['title'] == 'The Beginning'
    from firebrat.pipeline.schema import RawPagesFile
    RawPagesFile.model_validate(raw)  # same schema the PDF extractor must satisfy


@pytest.mark.parametrize('style', ['meta', 'epub3', 'guide'])
def test_epub_front_cover_found_by_each_convention(tmp_path, style):
    p = tmp_path / 'a.epub'
    make_epub(p, cover=PNG, style=style)
    assert ebook.read_cover(str(p)) == (PNG, '.png')


def test_epub_without_cover_or_with_unsupported_image_has_none(tmp_path):
    p = tmp_path / 'a.epub'
    make_epub(p)
    assert ebook.read_cover(str(p)) is None
    make_epub(p, cover=GIF)
    assert ebook.read_cover(str(p)) is None


@pytest.mark.parametrize('ext', ['.mobi', '.azw', '.azw3'])
def test_kindle_cover_uses_exth_offset_not_just_the_first_image(tmp_path, ext):
    p = tmp_path / f'k{ext}'
    make_mobi(p, BOOK, cover=JPG, extra_images=(PNG,))      # PNG is image 0 (e.g. a logo); the cover is image 1
    assert ebook.read_cover(str(p)) == (JPG, '.jpg')
    make_mobi(p, BOOK)
    assert ebook.read_cover(str(p)) is None


def test_extraction_writes_cover_into_the_package_root_and_the_download_zip(tmp_path, monkeypatch):
    import zipfile as zf
    from firebrat.pipeline.ebook import run_ebook_extraction
    from server import storage
    monkeypatch.setattr(config, 'OUTPUT_DIR', str(tmp_path / 'out'))
    p = tmp_path / 'a.epub'
    make_epub(p, cover=PNG)
    pkg = tmp_path / 'out' / 'a'
    pkg.mkdir(parents=True)
    (pkg / 'cover.jpg').write_bytes(b'stale')                 # an old cover must not linger
    stats = run_ebook_extraction(str(p), str(pkg), 'a')
    assert stats['cover'] == '.png'
    assert (pkg / 'cover.png').read_bytes() == PNG and not (pkg / 'cover.jpg').exists()
    (pkg / 'manifest.json').write_text('{}')
    with zf.ZipFile(storage.get_or_build_zip('a')) as z:      # what the app downloads
        assert 'cover.png' in z.namelist()

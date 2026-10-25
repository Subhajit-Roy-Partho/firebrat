from firebrat.pipeline import cover


def test_only_sparse_first_pages_count_as_covers():
    assert cover.looks_like_cover('')
    assert cover.looks_like_cover('A Title\nBy Someone')
    assert not cover.looks_like_cover('Chapter 1. ' + 'body text ' * 30)


def test_render_never_raises_and_skips_text_pages(tmp_path):
    # A body-text first page is skipped before the PDF is even opened.
    assert cover.render_pdf_cover(str(tmp_path / 'missing.pdf'), str(tmp_path), 'x ' * 400) is None
    # An unreadable PDF (or no pymupdf installed) yields None instead of an error.
    (tmp_path / 'bad.pdf').write_bytes(b'not a pdf')
    assert cover.render_pdf_cover(str(tmp_path / 'bad.pdf'), str(tmp_path), 'Title') is None
    assert not (tmp_path / 'cover.png').exists()

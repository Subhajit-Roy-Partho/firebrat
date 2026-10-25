"""EPUB / MOBI / AZW reading: ebook file -> raw pages for the normal pipeline.

Ebooks are reflowable text, so there is no PDF to extract. This module reads the
text in reading order, splits it into page-sized chunks (each carrying its chapter
title) and writes the same raw_pages.json the PDF extractor produces, so novel
mode and the LLM compiler run unchanged. Pictures are not extracted and there is
no "source page" for an ebook.

Supported: EPUB 2/3; MOBI and AZW/AZW3 (Kindle) without DRM, PalmDoc-compressed
(the common case). DRM-protected or HUFF/CDIC-compressed files raise EbookError
with a plain explanation; remove DRM with your own tools first.
"""
import html
import json
import os
import posixpath
import re
import struct
import zipfile
from html.parser import HTMLParser
from xml.etree import ElementTree

EBOOK_EXTENSIONS = (".epub", ".mobi", ".azw", ".azw3")
_PAGE_CHARS = 1800
_BLOCK_TAGS = {"p", "div", "br", "li", "tr", "section", "article", "blockquote", "pre",
               "h1", "h2", "h3", "h4", "h5", "h6", "hr", "ul", "ol", "table", "aside", "figure",
               "mbp:pagebreak"}
_SKIP_TAGS = {"script", "style", "head", "svg", "nav"}
_HEADINGS = {"h1", "h2", "h3"}


class EbookError(ValueError):
    """The file cannot be converted; the message is safe to show the user."""


def is_ebook(path):
    return str(path).lower().endswith(EBOOK_EXTENSIONS)


class _Text(HTMLParser):
    """HTML -> plain text with blank lines between blocks; remembers the first heading."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.skip, self.heading, self._in_heading = [], 0, None, None

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag in _SKIP_TAGS:
            self.skip += 1
        if tag in _BLOCK_TAGS:
            self.parts.append("\n\n" if tag != "br" else "\n")
        if tag in _HEADINGS and self.heading is None:
            self._in_heading = []

    def handle_endtag(self, tag):
        tag = tag.lower()
        if tag in _SKIP_TAGS and self.skip:
            self.skip -= 1
        if tag in _BLOCK_TAGS:
            self.parts.append("\n\n")
        if tag in _HEADINGS and self._in_heading is not None:
            text = " ".join("".join(self._in_heading).split())
            if text:
                self.heading = text
            self._in_heading = None

    def handle_data(self, data):
        if self.skip:
            return
        self.parts.append(data)
        if self._in_heading is not None:
            self._in_heading.append(data)


def html_to_text(markup):
    """-> (text, first_heading_or_None). Paragraphs are separated by blank lines."""
    parser = _Text()
    parser.feed(markup)
    parser.close()
    raw = "".join(parser.parts).replace("\xa0", " ")
    paragraphs = [" ".join(p.split()) for p in re.split(r"\n\s*\n", raw)]
    return "\n\n".join(p for p in paragraphs if p), parser.heading


# ── EPUB ──────────────────────────────────────────────────────────────
def _local(tag):
    return tag.rsplit("}", 1)[-1]


def read_epub(path):
    """-> (title, author, [(chapter_title, text), ...]) in spine order."""
    try:
        zf = zipfile.ZipFile(path)
    except zipfile.BadZipFile as exc:
        raise EbookError("This EPUB is damaged or is not a real EPUB file.") from exc
    with zf:
        names = set(zf.namelist())
        if "META-INF/encryption.xml" in names:
            enc = zf.read("META-INF/encryption.xml").decode("utf-8", "replace")
            # Font obfuscation is harmless; anything else is real DRM.
            algorithms = re.findall(r'Algorithm="([^"]+)"', enc)
            if any("obfuscation" not in a and "fontobfuscation" not in a for a in algorithms):
                raise EbookError("This EPUB is protected by DRM and cannot be converted.")
        try:
            container = ElementTree.fromstring(zf.read("META-INF/container.xml"))
            opf_path = next(e.attrib["full-path"] for e in container.iter() if _local(e.tag) == "rootfile")
            opf = ElementTree.fromstring(zf.read(opf_path))
        except (KeyError, StopIteration, ElementTree.ParseError) as exc:
            raise EbookError("This EPUB has no readable package file.") from exc
        base = posixpath.dirname(opf_path)
        manifest, spine, title, author = {}, [], None, None
        for el in opf.iter():
            name = _local(el.tag)
            if name == "item":
                manifest[el.attrib.get("id")] = (el.attrib.get("href", ""), el.attrib.get("media-type", ""))
            elif name == "itemref":
                spine.append(el.attrib.get("idref"))
            elif name == "title" and title is None and (el.text or "").strip():
                title = el.text.strip()
            elif name == "creator" and author is None and (el.text or "").strip():
                author = el.text.strip()
        chapters = []
        for idref in spine:
            href, media = manifest.get(idref, ("", ""))
            if not href or ("html" not in media and "xml" not in media):
                continue
            member = posixpath.normpath(posixpath.join(base, href.split("#")[0]))
            member = member.replace("%20", " ")
            if member not in names:
                continue
            text, heading = html_to_text(zf.read(member).decode("utf-8", "replace"))
            if text:
                chapters.append((heading or f"Part {len(chapters) + 1}", text))
        if len(chapters) > 1 and len(chapters[0][1]) < 40:
            chapters.pop(0)  # a cover / title-page stub
        if not chapters:
            raise EbookError("No readable text was found in this EPUB.")
        return title, author, chapters


# ── MOBI / AZW / AZW3 (PalmDoc) ───────────────────────────────────────
def _palmdoc_decompress(data):
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        c = data[i]
        i += 1
        if c == 0 or 9 <= c <= 0x7F:
            out.append(c)
        elif 1 <= c <= 8:
            out += data[i:i + c]
            i += c
        elif c >= 0xC0:
            out.append(0x20)
            out.append(c ^ 0x80)
        else:  # 0x80-0xBF: a back-reference
            if i >= n:
                break
            c = (c << 8) | data[i]
            i += 1
            distance, length = (c >> 3) & 0x7FF, (c & 7) + 3
            if distance == 0 or distance > len(out):
                continue
            for _ in range(length):
                out.append(out[-distance])
    return bytes(out)


def _trailing_size(record, flags):
    """Bytes of trailing metadata to drop from a text record (see MOBI spec)."""
    size, f = 0, flags >> 1
    while f:
        if f & 1:
            pos, shift, value = len(record) - size, 0, 0
            while pos > 0:
                b = record[pos - 1]
                value |= (b & 0x7F) << shift
                shift += 7
                pos -= 1
                if b & 0x80 or shift >= 28:
                    break
            size += value
        f >>= 1
    if flags & 1 and len(record) - size - 1 >= 0:
        size += (record[len(record) - size - 1] & 3) + 1
    return size


def read_mobi(path):
    """-> (title, author, [(chapter_title, text), ...]) for .mobi/.azw/.azw3."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 80 or data[60:68] not in (b"BOOKMOBI", b"TEXtREAd"):
        raise EbookError("This does not look like a Kindle or MOBI book (it may be a different format with the wrong extension).")
    record_count = struct.unpack(">H", data[76:78])[0]
    offsets = [struct.unpack(">I", data[78 + 8 * i:82 + 8 * i])[0] for i in range(record_count)]
    offsets.append(len(data))
    rec = lambda i: data[offsets[i]:offsets[i + 1]]  # noqa: E731
    r0 = rec(0)
    compression, _u1, _length, text_records, _size, encryption, _u2 = struct.unpack(">HHIHHHH", r0[0:16])
    if encryption != 0:
        raise EbookError("This Kindle book is protected by DRM and cannot be converted. Remove the DRM with your own tools, or import a DRM-free copy.")
    if compression not in (1, 2):
        raise EbookError("This Kindle book uses an unsupported compression (HUFF/CDIC). Convert it to EPUB first, for example with Calibre.")
    flags, encoding, full_name = 0, 1252, None
    if r0[16:20] == b"MOBI":
        header_len = struct.unpack(">I", r0[20:24])[0]
        encoding = struct.unpack(">I", r0[28:32])[0]
        if header_len >= 228 and len(r0) >= 244:
            flags = struct.unpack(">H", r0[242:244])[0]
        off, length = struct.unpack(">II", r0[84:92]) if len(r0) >= 92 else (0, 0)
        if off and length and off + length <= len(r0):
            full_name = r0[off:off + length].decode("utf-8" if encoding == 65001 else "cp1252", "replace").strip() or None
    chunks = []
    for i in range(1, min(text_records, record_count - 1) + 1):
        record = rec(i)
        if flags:
            record = record[:len(record) - _trailing_size(record, flags)]
        chunks.append(_palmdoc_decompress(record) if compression == 2 else record)
    markup = b"".join(chunks).decode("utf-8" if encoding == 65001 else "cp1252", "replace")
    parts = re.split(r"<mbp:pagebreak\s*/?>", markup, flags=re.I)
    chapters = []
    for part in parts:
        text, heading = html_to_text(part)
        if text:
            chapters.append((heading or f"Part {len(chapters) + 1}", text))
    if not chapters:
        raise EbookError("No readable text was found in this book. It may be DRM-protected or use an unsupported layout.")
    return full_name, None, chapters


def read_ebook(path):
    lower = str(path).lower()
    if lower.endswith(".epub"):
        return read_epub(path)
    if lower.endswith((".mobi", ".azw", ".azw3")):
        return read_mobi(path)
    raise EbookError("Unsupported ebook format.")


# ── front cover ───────────────────────────────────────────────────────
def sniff_image(data):
    """Extension for image bytes the app can show as a cover, else None (e.g. GIF)."""
    if data[:3] == b"\xff\xd8\xff":
        return ".jpg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    return None


def _epub_cover(path):
    with zipfile.ZipFile(path) as zf:
        names = set(zf.namelist())
        container = ElementTree.fromstring(zf.read("META-INF/container.xml"))
        opf_path = next(e.attrib["full-path"] for e in container.iter() if _local(e.tag) == "rootfile")
        opf = ElementTree.fromstring(zf.read(opf_path))
        base = posixpath.dirname(opf_path)
        items, cover_id, guide_href = {}, None, None
        for el in opf.iter():
            name = _local(el.tag)
            if name == "item":
                items[el.attrib.get("id")] = el.attrib
            elif name == "meta" and el.attrib.get("name") == "cover":
                cover_id = el.attrib.get("content")
            elif name == "reference" and el.attrib.get("type") == "cover":
                guide_href = el.attrib.get("href")

        def member(href):
            m = posixpath.normpath(posixpath.join(base, href.split("#")[0])).replace("%20", " ")
            return m if m in names else None

        candidates = []
        if cover_id in items:                                         # EPUB 2 convention
            candidates.append(items[cover_id].get("href"))
        candidates += [i.get("href") for i in items.values()          # EPUB 3
                       if "cover-image" in (i.get("properties") or "").split()]
        if guide_href:                                                # cover page that wraps the image
            page = member(guide_href)
            if page:
                match = re.search(r'(?:src|href)\s*=\s*["\']([^"\']+\.(?:jpe?g|png|webp))["\']',
                                  zf.read(page).decode("utf-8", "replace"), re.I)
                if match:
                    candidates.append(posixpath.join(posixpath.dirname(guide_href), match.group(1)))
        candidates += [i.get("href") for i in items.values()          # last resort: anything named cover
                       if "image" in (i.get("media-type") or "") and "cover" in (i.get("href") or "").lower()]
        for href in candidates:
            m = member(href or "")
            if m:
                data = zf.read(m)
                ext = sniff_image(data)
                if ext:
                    return data, ext
    return None


def _mobi_cover(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 80 or data[60:68] not in (b"BOOKMOBI", b"TEXtREAd"):
        return None
    count = struct.unpack(">H", data[76:78])[0]
    offsets = [struct.unpack(">I", data[78 + 8 * i:82 + 8 * i])[0] for i in range(count)] + [len(data)]
    record = lambda i: data[offsets[i]:offsets[i + 1]]  # noqa: E731
    r0 = record(0)
    if r0[16:20] != b"MOBI":
        return None
    header_len = struct.unpack(">I", r0[20:24])[0]
    first_image = struct.unpack(">I", r0[108:112])[0] if len(r0) >= 112 else 0xFFFFFFFF
    cover_offset = None
    exth = 16 + header_len
    if r0[exth:exth + 4] == b"EXTH":
        n = struct.unpack(">I", r0[exth + 8:exth + 12])[0]
        pos = exth + 12
        for _ in range(n):
            if pos + 8 > len(r0):
                break
            rtype, rlen = struct.unpack(">II", r0[pos:pos + 8])
            if rtype == 201 and rlen >= 12:
                cover_offset = struct.unpack(">I", r0[pos + 8:pos + 12])[0]
            pos += max(rlen, 8)
    if first_image >= count:
        return None
    # The declared cover record first; otherwise the first usable image.
    order = ([first_image + cover_offset] if cover_offset is not None else []) + list(range(first_image, min(count, first_image + 12)))
    for index in order:
        if 0 <= index < count:
            blob = record(index)
            ext = sniff_image(blob)
            if ext:
                return blob, ext
    return None


def read_cover(path):
    """-> (image bytes, '.jpg'|'.png'|'.webp') or None. Never raises: a cover is cosmetic."""
    try:
        lower = str(path).lower()
        if lower.endswith(".epub"):
            return _epub_cover(path)
        if lower.endswith((".mobi", ".azw", ".azw3")):
            return _mobi_cover(path)
    except Exception:
        return None
    return None


# ── to raw pages ──────────────────────────────────────────────────────
def chapters_to_pages(chapters, page_chars=_PAGE_CHARS):
    """Groups paragraphs into page-sized chunks; each keeps its chapter title."""
    pages = []
    for title, text in chapters:
        pieces, current = [], ""
        for paragraph in text.split("\n\n"):
            while len(paragraph) > page_chars * 2:  # a wall of text with no breaks
                cut = paragraph.rfind(". ", 0, page_chars)
                cut = cut + 2 if cut > 0 else page_chars
                piece, paragraph = paragraph[:cut], paragraph[cut:]
                pieces.append(piece)
            if current and len(current) + len(paragraph) > page_chars:
                pieces.append(current)
                current = ""
            current = f"{current}\n\n{paragraph}" if current else paragraph
        if current:
            pieces.append(current)
        for k, piece in enumerate(pieces):
            suffix = f" ({k + 1})" if len(pieces) > 1 else ""
            pages.append({"page_idx": len(pages), "text": piece, "markdown": "", "title": f"{title}{suffix}",
                          "figures": [], "tables": [], "formulas": []})
    return pages


def run_ebook_extraction(path, pkg_dir, book_id):
    """Writes <pkg_dir>/raw/raw_pages.json like the PDF extractor. Returns stats + title/author."""
    title, author, chapters = read_ebook(path)
    pages = chapters_to_pages(chapters)
    raw = {"book_id": book_id, "source_pdf": os.path.basename(path), "page_count": len(pages),
           "pages": pages, "title": title, "author": author}
    out = os.path.join(pkg_dir, "raw", "raw_pages.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        json.dump(raw, f, ensure_ascii=False, indent=2)
    # The book's own front cover, when it has one: the app shows cover.* from the package root.
    cover = read_cover(path)
    for old in (".jpg", ".png", ".webp"):
        stale = os.path.join(pkg_dir, "cover" + old)
        if os.path.isfile(stale):
            os.remove(stale)
    if cover:
        with open(os.path.join(pkg_dir, "cover" + cover[1]), "wb") as f:
            f.write(cover[0])
    return {"cover": cover[1] if cover else None, "book_id": book_id, "page_count": len(pages), "chapters": len(chapters),
            "title": title, "author": author, "raw_pages_json": out}

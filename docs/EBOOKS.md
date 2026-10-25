# EPUB, MOBI and AZW books

Firebrat converts reflowable ebooks as well as PDFs, on the server and on the phone.

| Format | Supported | Notes |
|---|---|---|
| EPUB 2/3 | yes | Read in spine (reading) order; chapter titles come from the first heading. |
| MOBI, AZW, AZW3 | yes, DRM-free | PalmDoc-compressed (the common case). |
| DRM-protected EPUB or Kindle files | no | The upload is refused with a clear message. Remove DRM with your own tools first. |
| Kindle files using HUFF/CDIC compression | no | Convert them to EPUB first (for example with Calibre). |

What to expect:

- **Text only.** Pictures are not extracted, and an ebook has no source PDF, so the reader's "Source page" button is hidden.
- **Great for novels.** Novel mode keeps the prose word for word, finds speakers, and uses the book's chapter titles for sections (including character traits and web research, see [backend novels](BACKEND_NOVELS.md)).
- **Illustrated mode** works but has no figures to show; use it for text-heavy non-fiction.
- Long chapters are split into page-sized parts, titled "Chapter (1)", "Chapter (2)", and so on.

Server: upload through `POST /books/upload`, the web UI, the PWA, or `python backend/convert.py book.epub --content-mode novel`. A damaged or DRM-protected file is rejected at upload (HTTP 400) rather than failing later in the queue.

App: Conversion settings must be On-device or Server; tap **Convert a book** on the Conversions screen and choose the file.

Tested against EPUB and MOBI/AZW files built to the format specifications. If a particular Kindle file fails, please open an issue and say which Kindle store or tool produced it.

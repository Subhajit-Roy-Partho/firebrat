/// One page's extracted text, before LLM compilation. Mirrors the shape of
/// `raw_pages.json` pages server-side, minus figure/table/formula regions —
/// this v1 on-device extractor does text-layer extraction only (see
/// package README "Known limitations"); figures/tables/formulas are
/// authored by the compilation LLM recognizing them in the text, same as
/// the server pipeline already does for math (`docs/ARCHITECTURE.md`).
class RawPage {
  final int pageIdx; // 0-based
  final String text;

  const RawPage({required this.pageIdx, required this.text});
}

/// A group of consecutive pages sent to the compilation LLM as one request
/// — mirrors `CHUNK_PAGES`-sized chunking in `compile_llm.py`.
class PageChunk {
  final int chunkIdx;
  final List<RawPage> pages;

  const PageChunk({required this.chunkIdx, required this.pages});

  int get startPage => pages.first.pageIdx;
  int get endPage => pages.last.pageIdx;
}

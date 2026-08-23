import '../models/raw_page.dart';

/// Groups pages into fixed-size chunks for the compilation LLM — mirrors
/// `_chunk_raw_pages` / `CHUNK_PAGES` (default 10) in `compile_llm.py`.
List<PageChunk> chunkPages(List<RawPage> pages, {int chunkPages = 10}) {
  final chunks = <PageChunk>[];
  for (var start = 0; start < pages.length; start += chunkPages) {
    final end = (start + chunkPages < pages.length) ? start + chunkPages : pages.length;
    chunks.add(PageChunk(chunkIdx: chunks.length, pages: pages.sublist(start, end)));
  }
  return chunks;
}

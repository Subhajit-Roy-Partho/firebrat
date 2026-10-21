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

/// Bound local prompts by text length, including unusually dense pages.
/// Page numbers stay attached to every slice for source/visual alignment.
List<PageChunk> chunkLocalPages(List<RawPage> pages, {int maxChars = 2000}) {
  if (maxChars < 100) throw ArgumentError.value(maxChars, 'maxChars');
  final chunks = <PageChunk>[];
  for (final page in pages) {
    var remaining = page.text;
    while (remaining.isNotEmpty) {
      var end = remaining.length < maxChars ? remaining.length : maxChars;
      if (end < remaining.length) {
        final boundary = remaining.lastIndexOf(RegExp(r'\s'), end);
        if (boundary > maxChars ~/ 2) end = boundary + 1;
      }
      chunks.add(PageChunk(chunkIdx: chunks.length, pages: [
        RawPage(pageIdx: page.pageIdx, text: remaining.substring(0, end)),
      ]));
      remaining = remaining.substring(end);
    }
  }
  return chunks;
}

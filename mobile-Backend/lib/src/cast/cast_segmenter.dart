/// Deterministic quote/narration segmentation (port of
/// backend/firebrat_cast/segmenter.py). (page, idx) is a stable per-page key
/// shared by casting and narration, and no text is ever lost.
library;

import '../models/raw_page.dart';
import 'cast_models.dart';

final _quote = RegExp('“[^”]+”|"[^"\n]+"');
final _sentEnd = RegExp('[.!?]["\'”’)\\]…]?\\s+');
const kCastMaxSegLen = 350;

List<(bool, String)> _spans(String text) {
  final parts = <(bool, String)>[];
  var cursor = 0;
  for (final m in _quote.allMatches(text)) {
    if (m.start > cursor) parts.add((false, text.substring(cursor, m.start)));
    parts.add((true, m.group(0)!));
    cursor = m.end;
  }
  if (cursor < text.length) parts.add((false, text.substring(cursor)));
  final out = <(bool, StringBuffer)>[];
  var pending = '';
  for (final (isQuote, chunk) in parts) {
    if (!isQuote && chunk.trim().isEmpty) {
      if (out.isNotEmpty) {
        out.last.$2.write(chunk);
      } else {
        pending += chunk;
      }
      continue;
    }
    final c = pending.isEmpty ? chunk : pending + chunk;
    pending = '';
    out.add((isQuote, StringBuffer(c)));
  }
  if (pending.isNotEmpty && out.isNotEmpty) out.last.$2.write(pending);
  return [for (final (q, b) in out) if (b.isNotEmpty) (q, b.toString())];
}

List<String> _bound(String chunk, int limit) {
  if (chunk.length <= limit) return [chunk];
  final pieces = <String>[];
  var rest = chunk;
  while (rest.length > limit) {
    final window = rest.substring(0, limit);
    var cut = 0;
    for (final m in _sentEnd.allMatches(window)) {
      if (m.end > cut) cut = m.end;
    }
    if (cut == 0) {
      final gap = window.lastIndexOf(' ');
      cut = gap > 0 ? gap + 1 : limit;
    }
    pieces.add(rest.substring(0, cut));
    rest = rest.substring(cut);
  }
  pieces.add(rest);
  return pieces;
}

/// Splits one page's text into spans with idx starting at 0.
List<CastSeg> segmentPageText(int page, String text, {int limit = kCastMaxSegLen}) {
  final segs = <CastSeg>[];
  if (text.trim().isEmpty) return segs;
  var idx = 0;
  for (final (isQuote, chunk) in _spans(text)) {
    for (final piece in _bound(chunk, limit)) {
      segs.add(CastSeg(page, idx++, isQuote, piece));
    }
  }
  return segs;
}

List<CastSeg> segmentPages(List<RawPage> pages, {int limit = kCastMaxSegLen}) {
  final sorted = [...pages]..sort((a, b) => a.pageIdx.compareTo(b.pageIdx));
  return [for (final p in sorted) ...segmentPageText(p.pageIdx, p.text, limit: limit)];
}

int wordCount(String text) => RegExp(r'\S+').allMatches(text).length;

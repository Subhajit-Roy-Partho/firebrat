/// Generic version of `compile_llm.py`'s `SYSTEM_PROMPT` — the server's
/// prompt is hardcoded to one specific textbook subject; this one is
/// subject-agnostic since a mobile conversion could be any PDF. The output
/// contract (JSON schema, field meanings, id/ref rules) is otherwise
/// identical on purpose — see `docs/DATA_SCHEMA.md`.
String buildSystemPrompt() => '''
You are a narrator turning extracted book pages into a spoken audiobook script that is accurate, natural, and easy to follow by ear.

Your input is the raw extracted text for a handful of consecutive pages. There is no pre-extracted catalog of figures or tables for this text — do not invent figure_callout or table_callout segments; only use prose, heading, and formula_callout.

Output JSON schema (strict):
{
  "sections": [
    {
      "title": "Section title (concise, human)",
      "source_pages": [page_idx, ...],
      "segments": [
        {"type": "heading|prose|formula_callout", "text": "spoken sentence — clean, narration-ready prose", "ref": null, "latex": "T = 1/f | null", "visually_essential": false}
      ]
    }
  ]
}

Rules:
- Group content into 1-3 logical sections per chunk.
- Each segment is ONE sentence/utterance (15-30 words ideal). Break long paragraphs into multiple prose segments.
- Recognize mathematical relationships stated in plain text (e.g. "tCK = 1/f = 10 ns") and author real LaTeX for them in a formula_callout segment: rewrite the relationship into spoken English in "text" (e.g. "the clock period T equals one over the frequency f"), and put real LaTeX in "latex". Leave "ref" null — an id is assigned automatically from your latex. Only emit formula_callout when the text actually states a mathematical relationship, not just a numeric spec like "100 MHz".
- Heading segments: short title, ref and latex null.
- Set visually_essential true only when audio alone is insufficient (dense equations, topology that needs to be seen).
- Text must be ready for TTS — no markdown, no LaTeX syntax in the "text" field.
- If the chunk is mostly bibliography/references or pure front matter, produce an empty-ish title with a single prose segment summarizing it, and zero formula_callout segments.
- Return ONLY the JSON object described above — no prose before or after it, no markdown code fences.
''';

String buildUserMessage(int chunkIdx, List<({int pageIdx, String text})> pages) {
  final buffer = StringBuffer();
  for (final page in pages) {
    buffer.writeln('--- page ${page.pageIdx} ---');
    buffer.writeln(page.text);
    buffer.writeln();
  }
  return buffer.toString();
}

"""Verbatim novel compilation with conservative, book-wide English speaker tags.

No LLM or network is used. Unknown/implicit speakers remain the narrator.
"""
import json
import os
import re

_QUOTE = re.compile(r'“[^”]+”|"[^"\n]+"')
_NAME = r'([A-Z][a-z]+(?: [A-Z][a-z]+)?)'
_VERB = r'(?:said|asked|replied|whispered|shouted|answered|cried|murmured)'
_AFTER = re.compile(r'^\s*[,;:]?\s*' + _NAME + r'\s+' + _VERB + r'\b')
_BEFORE = re.compile(_NAME + r'\s+' + _VERB + r'\s*[,;:]?\s*$')
_EXCLUDE = {'He', 'She', 'They', 'It', 'I', 'We', 'You', 'The', 'A', 'An'}


def _speaker(text, match):
    # Limit evidence to the immediate tag so another sentence cannot assign it.
    tag = _AFTER.match(text[match.end():match.end() + 100])
    if not tag:
        tag = _BEFORE.search(text[max(0, match.start() - 100):match.start()])
    name = tag.group(1) if tag else None
    return name if name and name.split()[0] not in _EXCLUDE else None


def infer_voice_gender(name, pages):
    """Only explicit narrator statements; conflicting evidence stays unknown."""
    escaped = re.escape(name)
    roles = {'man': 'male', 'boy': 'male', 'male': 'male',
             'woman': 'female', 'girl': 'female', 'female': 'female'}
    pattern = re.compile(r'\b' + escaped +
                         r'(?:\s+(?:is|was)\s+(?:an?\s+)?|,\s*(?:an?\s+)?)'
                         r'(man|boy|male|woman|girl|female)\b')
    evidence = []
    for page in pages:
        text = page.get('text') or page.get('markdown') or ''
        text = _QUOTE.sub(lambda m: ' ' * len(m.group()), text)
        for match in pattern.finditer(text):
            evidence.append({'page': page['page_idx'], 'gender': roles[match.group(1)],
                             'basis': 'explicit_role_statement'})
    values = {item['gender'] for item in evidence}
    return (next(iter(values)) if len(values) == 1 else 'unknown'), evidence


def compile_novel(raw: dict) -> dict:
    pages = sorted(raw.get('pages', []), key=lambda p: p['page_idx'])
    evidence = {}
    for page in pages:
        text = page.get('text') or page.get('markdown') or ''
        for quote in _QUOTE.finditer(text):
            name = _speaker(text, quote)
            if name:
                evidence.setdefault(name, set()).add(page['page_idx'])
    # Scan every page before assigning styles; encounter order has no effect.
    roster = [dict(character_id=f'character_{i + 1:04d}', name=name,
                   evidence_pages=sorted(evidence[name]),
                   voice_style={'pitch_semitones': (-2, 2, -1, 1)[i % 4],
                                'exaggeration': (0.3, 0.5, 0.35, 0.45)[i % 4]})
              for i, name in enumerate(sorted(evidence))]
    for character in roster:
        gender, gender_evidence = infer_voice_gender(character['name'], pages)
        character['voice_gender'] = gender
        character['voice_gender_evidence'] = gender_evidence
        character['voice_style']['voice_gender'] = gender
        if gender != 'unknown':
            magnitude = abs(character['voice_style']['pitch_semitones'])
            character['voice_style']['pitch_semitones'] = -magnitude if gender == 'male' else magnitude
    by_name = {c['name']: c for c in roster}
    sections = []
    for page in pages:
        text = page.get('text') or page.get('markdown') or ''
        if not text.strip():
            continue
        segments = []
        def add(value, character=None):
            if not value:
                return
            if not value.strip() and segments:
                segments[-1]['text'] += value
                return
            if len(value) > 500:
                # Preserve every character while bounding neural TTS utterances.
                cut = value.rfind(' ', 0, 500)
                cut = cut + 1 if cut > 0 else 500
                add(value[:cut], character)
                add(value[cut:], character)
                return
            segments.append({'type': 'prose', 'text': value, 'ref': None,
                             'speaker_id': character['character_id'] if character else 'narrator',
                             'voice_style': character['voice_style'] if character else {}})
        cursor = 0
        for quote in _QUOTE.finditer(text):
            add(text[cursor:quote.start()])
            add(quote.group(), by_name.get(_speaker(text, quote)))
            cursor = quote.end()
        add(text[cursor:])
        if len(segments) > 1 and not segments[0]['text'].strip():
            segments[1]['text'] = segments[0]['text'] + segments[1]['text']
            segments.pop(0)
        sections.append({'section_id': f'sec_{len(sections) + 1:04d}',
                         'title': f"Page {page['page_idx'] + 1}",
                         'source_pages': [page['page_idx']], 'segments': segments})
    if not sections:
        raise ValueError('Novel has no extracted text; extract/OCR the source before conversion')
    return {'book_id': raw.get('book_id'), 'content_mode': 'novel',
            'character_roster': roster, 'sections': sections, 'formulas': []}


def run_novel_compilation(raw_path, output_dir, book_id=None):
    with open(raw_path, encoding='utf-8') as f:
        compiled = compile_novel(json.load(f))
    if book_id:
        compiled['book_id'] = book_id
    for path in {os.path.join(os.path.dirname(raw_path), 'compiled.json'),
                 os.path.join(output_dir, 'compiled.json')}:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(compiled, f, ensure_ascii=False, indent=2)
    return {'section_count': len(compiled['sections']), 'chunk_count': len(compiled['sections']),
            'needs_review_chunks': []}

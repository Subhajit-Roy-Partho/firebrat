"""Verbatim novel compilation with conservative, book-wide English speaker tags.

No LLM or network is used. Unknown/implicit speakers remain the narrator.
"""
import json
import os
import re

from firebrat.pipeline import character_traits as ct

_QUOTE = re.compile(r'“[^”]+”|"[^"\n]+"')
# An optional title ('Mr. Darcy', 'Lady Catherine') so the speaker is the whole name.
_TITLES = r'(?:(?:Mr|Mrs|Miss|Ms|Dr|Lady|Lord|Sir|Colonel|Captain|Major|Professor|Reverend|Uncle|Aunt)\.?\s+)?'
_NAME = r'(' + _TITLES + r'[A-Z][a-z]+(?: [A-Z][a-z]+)?)'
_VERB = r'(?:said|asked|replied|whispered|shouted|answered|cried|murmured|exclaimed|called|remarked|continued|added)'
# A tag can follow the quote ("Elizabeth said" / "said Mr. Darcy") or precede it.
_AFTER = re.compile(r'^\s*[,;:]?\s*' + _NAME + r'\s+' + _VERB + r'\b')
_AFTER_INVERTED = re.compile(r'^\s*[,;:]?\s*' + _VERB + r'\s+' + _NAME)
_BEFORE = re.compile(_NAME + r'\s+' + _VERB + r'\s*[,;:]?\s*$')
_BEFORE_INVERTED = re.compile(_VERB + r'\s+' + _NAME + r'\s*[,;:]?\s*$')
_EXCLUDE = {'He', 'She', 'They', 'It', 'I', 'We', 'You', 'The', 'A', 'An'}


def _speaker(text, match):
    # Limit evidence to the immediate tag so another sentence cannot assign it.
    after = text[match.end():match.end() + 100]
    before = text[max(0, match.start() - 100):match.start()]
    for pattern, source in ((_AFTER, after), (_AFTER_INVERTED, after)):
        tag = pattern.match(source)
        if tag:
            break
    else:
        for pattern in (_BEFORE, _BEFORE_INVERTED):
            tag = pattern.search(before)
            if tag:
                break
    name = tag.group(1) if tag else None
    return name if name and name.split()[0].rstrip('.') not in _EXCLUDE else None


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


def apply_traits(roster, researched, user_traits):
    """Layer user traits over researched ones, then derive each character's delivery.

    Researched gender only fills an `unknown` voice gender (explicit narrator
    statements in the book always win). Age/temperament shift pitch and
    expressiveness; pitch shifts also change speed, as documented for the
    existing styles.
    """
    for character in roster:
        traits = ct.merge(ct.lookup(character['name'], user_traits)[1] or ct.unknown(),
                          researched.get(character['name'], ct.unknown()))
        character['traits'] = traits
        style = character['voice_style']
        if character['voice_gender'] == 'unknown' and traits['gender'] != 'unknown':
            character['voice_gender'] = style['voice_gender'] = traits['gender']
            magnitude = abs(style['pitch_semitones'])
            style['pitch_semitones'] = -magnitude if traits['gender'] == 'male' else magnitude
            character['voice_gender_evidence'].append(
                {'page': None, 'gender': traits['gender'],
                 'basis': 'user' if traits['source'] == 'user' else 'web_research'})
        if ct.has_style(traits):
            semitones, exaggeration = ct.style_adjustments(traits)
            style['pitch_semitones'] = max(-6, min(6, style['pitch_semitones'] + semitones))
            if exaggeration is not None:
                style['exaggeration'] = exaggeration


def compile_novel(raw: dict, researched=None, user_traits=None) -> dict:
    pages = sorted(raw.get('pages', []), key=lambda p: p['page_idx'])
    evidence, line_counts, total, attributed = {}, {}, 0, 0
    for page in pages:
        text = page.get('text') or page.get('markdown') or ''
        for quote in _QUOTE.finditer(text):
            total += 1
            name = _speaker(text, quote)
            if name:
                attributed += 1
                line_counts[name] = line_counts.get(name, 0) + 1
                evidence.setdefault(name, set()).add(page['page_idx'])
    # Scan every page before assigning styles; encounter order has no effect.
    roster = [dict(character_id=f'character_{i + 1:04d}', name=name,
                   evidence_pages=sorted(evidence[name]), lines=line_counts[name],
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
    apply_traits(roster, researched or {}, user_traits or {})
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
                         'title': page.get('title') or f"Page {page['page_idx'] + 1}",
                         'source_pages': [page['page_idx']], 'segments': segments})
    if not sections:
        raise ValueError('Novel has no extracted text; extract/OCR the source before conversion')
    return {'book_id': raw.get('book_id'), 'content_mode': 'novel',
            'character_roster': roster, 'sections': sections, 'formulas': [],
            # How much dialogue a named speaker was found for; the rest is read by the narrator.
            'dialogue_stats': {'total': total, 'attributed': attributed}}


def write_character_roster(pkg_dir, compiled):
    """character_roster.json at the package root: what the app's "Cast & voices" screen
    shows so a reader can verify who was found. (compiled.json itself is not shipped.)"""
    roster = {
        'engine': 'chatterbox',
        'dialogue': compiled.get('dialogue_stats', {'total': 0, 'attributed': 0}),
        'characters': [
            {'name': c['name'], 'lines': c.get('lines', 0), 'evidence_pages': c['evidence_pages'],
             'voice_gender': c.get('voice_gender', 'unknown'), 'traits': c.get('traits', {}),
             'voice_style': c['voice_style']}
            for c in compiled['character_roster']],
    }
    if compiled.get('character_research'):
        roster['research'] = compiled['character_research']
    if compiled.get('unmatched_character_traits'):
        roster['unmatched_overrides'] = compiled['unmatched_character_traits']
    os.makedirs(pkg_dir, exist_ok=True)
    with open(os.path.join(pkg_dir, 'character_roster.json'), 'w', encoding='utf-8') as f:
        json.dump(roster, f, ensure_ascii=False, indent=2)


def run_novel_compilation(raw_path, output_dir, book_id=None, title=None,
                          research=False, trait_overrides=None, model=None):
    """`trait_overrides`: {character name: spec string} (see character_traits.parse_spec).
    `research`: look the book up on Wikipedia and let the LLM describe characters."""
    with open(raw_path, encoding='utf-8') as f:
        raw = json.load(f)
    user_traits = {}
    for name, spec in (trait_overrides or {}).items():
        _voice, traits = ct.parse_spec(spec)
        if traits:
            user_traits[name] = traits
    researched, report = {}, None
    if research:
        from firebrat import config
        names = [c['name'] for c in compile_novel(raw)['character_roster']]
        if not config.NANO_API_KEY:
            report = {'status': 'skipped', 'source': 'Wikipedia',
                      'reason': 'no LLM key is configured on this server (MODEL_API_KEY)'}
        else:
            from firebrat.pipeline.character_research import research_characters
            researched, report = research_characters(
                title or raw.get('title') or (book_id or '').replace('-', ' '), names,
                model or os.environ.get('FIREBRAT_SPARK_MODEL') or 'deepseek/deepseek-v4-flash')
    compiled = compile_novel(raw, researched=researched, user_traits=user_traits)
    matched = {ct.lookup(c['name'], user_traits)[0] for c in compiled['character_roster']}
    unmatched = [name for name in user_traits if name not in matched]
    if unmatched:
        compiled['unmatched_character_traits'] = unmatched
    if report is not None:
        compiled['character_research'] = report
    if book_id:
        compiled['book_id'] = book_id
    write_character_roster(output_dir, compiled)
    for path in {os.path.join(os.path.dirname(raw_path), 'compiled.json'),
                 os.path.join(output_dir, 'compiled.json')}:
        with open(path, 'w', encoding='utf-8') as f:
            json.dump(compiled, f, ensure_ascii=False, indent=2)
    return {'section_count': len(compiled['sections']), 'chunk_count': len(compiled['sections']),
            'needs_review_chunks': []}

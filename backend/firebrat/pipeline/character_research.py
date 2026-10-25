"""Web research for novel casting: Wikipedia + the operator's LLM.

Looks the book up on Wikipedia and has the configured LLM read the article's
character descriptions, giving each named speaker an age and temperament.

Privacy: only the book TITLE and the character NAMES (to Wikipedia and to the
LLM) and the public article (to the LLM) leave the machine. None of the book's
own text is sent. Every failure is non-fatal: the conversion just continues
without research and the reason is recorded in the roster.
"""
import json
import logging
import re
from urllib.parse import quote

import requests

from firebrat.pipeline import character_traits as ct

log = logging.getLogger(__name__)
_API = "https://en.wikipedia.org/w/api.php"
_HEADERS = {"User-Agent": "Firebrat/1.7 (https://github.com/Subhajit-Roy-Partho/firebrat)"}
_SYSTEM = ("You help cast an audiobook. Using ONLY the reference text, describe each listed character. "
           "A listed name may be a nickname, a title or a surname (for example 'Lizzy' is Elizabeth Bennet, and "
           "'Mr. Darcy' is Fitzwilliam Darcy): match it to the right person in the text. "
           "Answer with one JSON object mapping each name exactly as given to "
           '{"gender":"male|female|unknown","age":"child|young|adult|elder|unknown",'
           '"temperament":"calm|cheerful|stern|gruff|gentle|energetic|mysterious|unknown"}. '
           'Use "unknown" whenever the text does not say. No commentary, JSON only.')


def parse_traits_reply(reply, names):
    """Pull the JSON object out of a model reply; keep known characters only."""
    start, end = reply.find("{"), reply.rfind("}")
    if start < 0 or end <= start:
        return {}
    try:
        data = json.loads(reply[start:end + 1])
    except ValueError:
        return {}
    if not isinstance(data, dict):
        return {}
    by_lower = {n.lower(): n for n in names}
    out = {}
    for key, value in data.items():
        name = by_lower.get(str(key).strip().lower())
        if name is None or not isinstance(value, dict):
            continue
        traits = ct.from_json(value)
        if traits["gender"] != "unknown" or ct.has_style(traits):
            out[name] = traits
    return out


_HONORIFICS = {"mr", "mrs", "miss", "ms", "dr", "lady", "lord", "sir", "colonel", "captain", "major",
               "professor", "reverend", "uncle", "aunt", "the", "of", "de", "van", "von"}
BATCH_SIZE = 10


def _name_words(names, min_len=3):
    return {w.lower() for n in names for w in re.split(r"[\s.\-]+", n)
            if len(w) >= min_len and w.lower() not in _HONORIFICS}


def context_for(names, articles, max_chars=9000):
    """Paragraphs that mention these names (whole words only), from every article;
    falls back to the start of the first article when only aliases appear."""
    patterns = [re.compile(r"\b" + re.escape(w) + r"\b", re.I) for w in _name_words(names)]
    picked, size = [], 0
    for _title, _url, text in articles:
        for paragraph in re.split(r"\n+", text):
            if len(paragraph.strip()) > 20 and any(p.search(paragraph) for p in patterns):
                if size + len(paragraph) > max_chars:
                    return "\n".join(picked)
                picked.append(paragraph)
                size += len(paragraph)
    return "\n".join(picked) if picked else articles[0][2][:4000]


def _find_articles(title, names, session, limit=3):
    titles = []
    for query in (f'"{title}" novel', f'characters in "{title}"'):
        hits = session.get(_API, params={"action": "query", "list": "search", "format": "json",
                                         "srlimit": 3, "srsearch": query},
                           headers=_HEADERS, timeout=20).json().get("query", {}).get("search", [])
        titles += [h["title"] for h in hits if h["title"] not in titles]
    words = _name_words(names, min_len=4)
    found = []
    for page_title in titles[:5]:
        pages = session.get(_API, params={"action": "query", "prop": "extracts", "explaintext": 1,
                                          "format": "json", "titles": page_title},
                            headers=_HEADERS, timeout=30).json().get("query", {}).get("pages", {})
        extract = next(iter(pages.values()), {}).get("extract", "") if pages else ""
        # An unrelated article must not be used: it has to mention a speaker.
        if not extract or not any(w in extract.lower() for w in words):
            continue
        found.append((page_title, "https://en.wikipedia.org/wiki/" + quote(page_title.replace(" ", "_")), extract[:60000]))
        if len(found) >= limit:
            break
    return found


def research_characters(title, names, model, chat=None, session=None):
    """Returns ({name: traits}, report). Never raises. Characters are researched in
    batches, each given the paragraphs that mention them, so a large cast is covered."""
    report = {"status": "skipped", "source": "Wikipedia"}
    if not names:
        report["reason"] = "no named speakers were found"
        return {}, report
    try:
        session = session or requests.Session()
        articles = _find_articles(title, names, session)
        if not articles:
            report["reason"] = "no matching Wikipedia article mentions these characters"
            return {}, report
        report["articles"] = [a[0] for a in articles]
        report["urls"] = [a[1] for a in articles]
        if chat is None:
            from firebrat.llm_client import chat_completion

            def chat(messages):
                resp = chat_completion(messages, model, temperature=0, max_tokens=3000, retries=2, timeout=120)
                return resp["choices"][0]["message"]["content"] or ""
        traits, last_error = {}, None
        for start in range(0, len(names), BATCH_SIZE):
            batch = names[start:start + BATCH_SIZE]
            context = context_for(batch, articles)
            for attempt in range(2):
                system = _SYSTEM if attempt == 0 else _SYSTEM + " Reply with the JSON object and nothing else."
                try:
                    reply = chat([{"role": "system", "content": system},
                                  {"role": "user", "content": f"Characters: {', '.join(batch)}\n\nReference text:\n{context}"}])
                except Exception as exc:  # the client already retried rate limits
                    last_error = str(exc)
                    break
                parsed = parse_traits_reply(reply, batch)
                if parsed:
                    traits.update(parsed)
                    break
        if not traits:
            report["reason"] = last_error or "the model returned no usable character descriptions"
            return {}, report
        report["status"] = "applied"
        report["described"] = len(traits)
        missing = [n for n in names if n not in traits]
        if missing:
            report["not_described"] = missing
        return traits, report
    except Exception as exc:  # network, JSON, provider error: never fail the conversion
        log.warning("Character research skipped: %s", exc)
        report["reason"] = f"character research failed: {exc}"
        return {}, report

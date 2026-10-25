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


def _find_article(title, names, session):
    hits = session.get(_API, params={"action": "query", "list": "search", "format": "json",
                                     "srlimit": 3, "srsearch": f'"{title}" novel'},
                       headers=_HEADERS, timeout=20).json().get("query", {}).get("search", [])
    for hit in hits:
        page_title = hit["title"]
        pages = session.get(_API, params={"action": "query", "prop": "extracts", "explaintext": 1,
                                          "format": "json", "titles": page_title},
                            headers=_HEADERS, timeout=30).json().get("query", {}).get("pages", {})
        extract = next(iter(pages.values()), {}).get("extract", "") if pages else ""
        lower = extract.lower()
        # An unrelated article must not be used: it has to mention a speaker.
        if not extract or not any(n.lower() in lower for n in names):
            continue
        match = re.search(r"==\s*(Main )?[Cc]haracters?\s*==", extract)
        start = match.start() if match else 0
        return page_title, "https://en.wikipedia.org/wiki/" + quote(page_title.replace(" ", "_")), extract[start:start + 9000]
    return None


def research_characters(title, names, model, chat=None, session=None):
    """Returns ({name: traits}, report). Never raises."""
    report = {"status": "skipped", "source": "Wikipedia"}
    if not names:
        report["reason"] = "no named speakers were found"
        return {}, report
    try:
        session = session or requests.Session()
        found = _find_article(title, names, session)
        if found is None:
            report["reason"] = "no matching Wikipedia article mentions these characters"
            return {}, report
        article_title, url, text = found
        report.update(article=article_title, url=url)
        if chat is None:
            from firebrat.llm_client import chat_completion

            def chat(messages):
                resp = chat_completion(messages, model, temperature=0, max_tokens=1500, retries=1, timeout=120)
                return resp["choices"][0]["message"]["content"] or ""
        reply = chat([{"role": "system", "content": _SYSTEM},
                      {"role": "user", "content": f"Characters: {', '.join(names)}\n\nReference text:\n{text}"}])
        traits = parse_traits_reply(reply, names)
        if not traits:
            report["reason"] = "the model returned no usable character descriptions"
            return {}, report
        report["status"] = "applied"
        return traits, report
    except Exception as exc:  # network, JSON, provider error: never fail the conversion
        log.warning("Character research skipped: %s", exc)
        report["reason"] = f"character research failed: {exc}"
        return {}, report

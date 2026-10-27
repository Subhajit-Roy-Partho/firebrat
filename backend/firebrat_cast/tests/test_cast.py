"""Offline tests for cast.py (fake LLM backend; no network, GPU, or numpy)."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from firebrat_cast import cast as C
from firebrat_cast.llm import extract_json, extract_json_array
from firebrat_cast.segmenter import segment_pages


class FakeBackend:
    """Canned raw-text replies; generate_json parses like the real backends."""

    def __init__(self, texts):
        self.texts = list(texts)
        self.calls = []

    name = "fake"

    def generate_text(self, system, user, max_tokens=2048):
        self.calls.append((system[:20], user))
        if not self.texts:
            raise RuntimeError("fake backend out of replies")
        return self.texts.pop(0)

    def generate_json(self, system, user, schema_hint="", max_tokens=2048):
        return extract_json(self.generate_text(system, user, max_tokens))


PAGES = [
    {"page_idx": 0, "text": "\u201cI declare after all there is no enjoyment like reading!\u201d said Caroline Bingley."},
    {"page_idx": 1, "text": "Elizabeth Bennet smiled. \u201cBooks are delightful,\u201d she told Jane. \u201cShall we walk?\u201d"},
    {"page_idx": 2, "text": "The rain fell steadily on the windows. Nobody spoke for a while."},
]

ROSTER_REPLY = json.dumps({
    "narrator": {"description": "Warm mature storyteller, steady pace.", "accent": "british"},
    "characters": [
        {"name": "Caroline Bingley", "aliases": ["Caroline"], "gender": "female",
         "age": "young", "temperament": "proud", "accent": "british",
         "description": "Young female voice, high pitch, brisk clipped pace, haughty.", "importance": 5},
        {"name": "Lizzy", "aliases": [], "gender": "female", "age": "young",
         "temperament": "lively", "accent": "british",
         "description": "Young female voice, mid pitch, quick warm pace, teasing.", "importance": 9},
    ]})


def raw_file(directory, pages=None):
    path = os.path.join(directory, "raw_pages.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"book_id": "test-book", "pages": pages if pages is not None else PAGES}, f)
    return path


class RosterTest(unittest.TestCase):
    def test_merge_aliases_across_windows(self):
        win2 = json.dumps({"characters": [
            {"name": "Elizabeth Bennet", "aliases": ["Lizzy", "Eliza"], "gender": "female",
             "age": "young", "temperament": "witty", "accent": "british",
             "description": "Young female voice, bright mid pitch, lively pace, arch and witty.", "importance": 12}]})
        backend = FakeBackend([ROSTER_REPLY, win2])
        segs = segment_pages(PAGES)
        cache = C.ChunkCache(tempfile.mkdtemp())
        _, roster = C.roster_pass(C.make_windows(segs, size=20, overlap=5), backend, cache)
        names = [c["name"] for c in roster]
        self.assertIn("Lizzy", names)
        self.assertNotIn("Elizabeth Bennet", names)  # merged via alias
        lizzy = next(c for c in roster if c["name"] == "Lizzy")
        self.assertIn("Elizabeth Bennet", lizzy["aliases"])
        self.assertEqual(lizzy["importance"], 12)
        self.assertTrue(all(c["id"].startswith("char_") for c in roster))

    def test_regex_roster_without_backend(self):
        _, roster = C.roster_pass(C.make_windows(segment_pages(PAGES)), None,
                                 C.ChunkCache(tempfile.mkdtemp()))
        self.assertTrue(any(c["name"] == "Caroline Bingley" for c in roster))


class AttributionTest(unittest.TestCase):
    def chars(self):
        return [{"id": "char_001", "name": "Elizabeth Bennet", "aliases": ["Lizzy"],
                 "gender": "female", "age": "young", "temperament": "witty",
                 "accent": "british", "description": "Young female voice.", "importance": 9}]

    def test_valid_rows_and_vocab_enforcement(self):
        segs = segment_pages(PAGES)
        chunks = C.make_chunks(segs, target=10**9)
        n = sum(1 for s in chunks[0] if s["kind"] == "quote")
        rows = [[i, "char_001" if i == 0 else "someone-else",
                 "joy" if i == 0 else "ecstatic", "laughing out loud " + "x" * 100]
                for i in range(n)]
        backend = FakeBackend([json.dumps({"utterances": rows})])
        attrib = C.attribution_pass(chunks, self.chars(), backend,
                                    C.ChunkCache(tempfile.mkdtemp()))
        first = attrib[(0, 0)]
        self.assertEqual(first, ("char_001", "joy", ("laughing out loud " + "x" * 100)[:60]))
        second = attrib[(1, 1)]
        self.assertEqual(second[0], "narrator")  # unknown speaker id repaired
        self.assertEqual(second[1], "neutral")  # off-vocab emotion repaired

    def test_bare_array_shape_accepted(self):
        segs = segment_pages([PAGES[0]])
        chunks = C.make_chunks(segs)
        backend = FakeBackend(['[[0, "char_001", "anger", "coldly"]]'])
        attrib = C.attribution_pass(chunks, self.chars(), backend,
                                    C.ChunkCache(tempfile.mkdtemp()))
        self.assertEqual(attrib[(0, 0)], ("char_001", "anger", "coldly"))

    def test_bad_json_retries_then_falls_back(self):
        segs = segment_pages([PAGES[0]])  # quote tagged 'said Caroline Bingley'
        chunks = C.make_chunks(segs)
        backend = FakeBackend(["not json at all", "still {broken"])
        attrib = C.attribution_pass(chunks, self.chars(), backend,
                                    C.ChunkCache(tempfile.mkdtemp()))
        # 'Caroline Bingley' is not in the roster, so the regex tag maps to narrator
        self.assertEqual(attrib[(0, 0)], ("narrator", "neutral", ""))
        self.assertEqual(len(backend.calls), 2)  # initial + one repair retry

    def test_backend_failure_maps_regex_name_to_id(self):
        chars = [{"id": "char_007", "name": "Caroline Bingley", "aliases": [],
                  "gender": "female", "age": "young", "temperament": "", "accent": "british",
                  "description": "Young female voice.", "importance": 3}]

        class Boom:
            name = "boom"

            def generate_text(self, system, user, max_tokens=2048):
                raise RuntimeError("gpu exploded")

            def generate_json(self, system, user, schema_hint="", max_tokens=2048):
                raise RuntimeError("gpu exploded")

        attrib = C.attribution_pass(C.make_chunks(segment_pages([PAGES[0]])), chars,
                                    Boom(), C.ChunkCache(tempfile.mkdtemp()))
        self.assertEqual(attrib[(0, 0)][0], "char_007")

    def test_json_helpers_repair_trailing_commas(self):
        self.assertEqual(extract_json('{"a": 1,}'), {"a": 1})
        self.assertEqual(extract_json_array("```json\n[[0, \"x\"]]\n```"), [[0, "x"]])


class CastBookTest(unittest.TestCase):
    def test_end_to_end_and_cache_resume(self):
        tmp = tempfile.mkdtemp()
        raw_path = raw_file(tmp)
        out_path = os.path.join(tmp, "cast.json")
        cache_dir = os.path.join(tmp, "cache")
        n_quotes = sum(1 for s in segment_pages(PAGES) if s["kind"] == "quote")

        def replies():
            chunks = C.make_chunks(segment_pages(PAGES))
            out = [ROSTER_REPLY]
            for chunk in chunks:
                items = [s for s in chunk if s["kind"] == "quote"]
                if items:
                    out.append(json.dumps({"utterances": [[i, "narrator", "neutral", ""]
                                                         for i in range(len(items))]}))
            return out

        backend = FakeBackend(replies())
        meta = {"book_id": "test-book", "title": "Test", "author": "Anon"}
        first = C.cast_book(raw_path, out_path, backend, meta, cache_dir=cache_dir)
        calls_after_first = len(backend.calls)
        self.assertGreater(calls_after_first, 0)
        self.assertEqual(len(first["utterances"]), n_quotes)
        self.assertEqual(set(first), {"book_id", "title", "author", "llm", "narrator",
                                     "characters", "utterances", "page_mood"})
        # Second run reuses the cache: zero new LLM calls, identical result.
        second = C.cast_book(raw_path, out_path, backend, meta, cache_dir=cache_dir)
        self.assertEqual(len(backend.calls), calls_after_first)
        self.assertEqual(first, second)
        with open(out_path, encoding="utf-8") as f:
            self.assertEqual(json.load(f), first)


if __name__ == "__main__":
    unittest.main()

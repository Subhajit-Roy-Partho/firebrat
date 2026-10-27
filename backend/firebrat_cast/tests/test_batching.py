"""Batched LLM generation tests (fake backends; no GPU, network, or models)."""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from firebrat_cast import cast as C
from firebrat_cast.llm import extract_json, generate_many
from firebrat_cast.segmenter import segment_pages


PAGES4 = [
    {"page_idx": 0, "text": "\u201cI declare there is no enjoyment like reading!\u201d said Caroline Bingley."},
    {"page_idx": 1, "text": "\u201cBooks are delightful companions,\u201d said Elizabeth Bennet."},
    {"page_idx": 2, "text": "\u201cShall we walk into the garden?\u201d said Jane Bennet."},
    {"page_idx": 3, "text": "\u201cThe rain falls steadily outside.\u201d said Mr. Darcy."},
]

ROSTER_REPLY = json.dumps({
    "narrator": {"description": "Warm mature storyteller, steady pace.", "accent": "british"},
    "characters": [
        {"name": "Caroline Bingley", "aliases": [], "gender": "female",
         "age": "young", "temperament": "proud", "accent": "british",
         "description": "Young female voice, high pitch, brisk pace.", "importance": 5},
    ]})


class SeqFake:
    """Fake WITHOUT generate_text_batch (exercises the sequential fallback)."""

    name = "seq-fake"

    def __init__(self, texts):
        self.texts = list(texts)
        self.calls = []

    def generate_text(self, system, user, max_tokens=2048):
        self.calls.append(user)
        if not self.texts:
            raise RuntimeError("seq fake out of replies")
        return self.texts.pop(0)

    def generate_json(self, system, user, schema_hint="", max_tokens=2048):
        return extract_json(self.generate_text(system, user, max_tokens))


class BatchFake:
    """Fake WITH generate_text_batch; counts batch vs single calls."""

    name = "batch-fake"

    def __init__(self, texts, single_texts=None):
        self.texts = list(texts)
        self.single_texts = list(single_texts) if single_texts is not None else None
        self.batch_calls = 0
        self.single_calls = []

    def generate_text(self, system, user, max_tokens=2048):
        self.single_calls.append(user)
        if self.single_texts is not None:
            if not self.single_texts:
                raise RuntimeError("batch fake out of single replies")
            return self.single_texts.pop(0)
        if not self.texts:
            raise RuntimeError("batch fake out of replies")
        return self.texts.pop(0)

    def generate_text_batch(self, system, users, max_tokens=2048):
        self.batch_calls += 1
        out = []
        for _ in users:
            if not self.texts:
                raise RuntimeError("batch fake out of replies")
            out.append(self.texts.pop(0))
        return out

    def generate_json(self, system, user, schema_hint="", max_tokens=2048):
        return extract_json(self.generate_text(system, user, max_tokens))


def one_quote_chunks(pages):
    segs = segment_pages(pages)
    chunks = [c for c in C.make_chunks(segs, target=1)
              if any(s["kind"] == "quote" for s in c)]
    assert len(chunks) >= 2, "need at least two quote chunks for batch tests"
    return chunks


def chars():
    return [{"id": "char_001", "name": "Elizabeth Bennet", "aliases": ["Lizzy"],
             "gender": "female", "age": "young", "temperament": "witty",
             "accent": "british", "description": "Young female voice.", "importance": 9}]


def set_batch(n):
    old = os.environ.get("FIREBRAT_CAST_BATCH")
    if n is None:
        os.environ.pop("FIREBRAT_CAST_BATCH", None)
    else:
        os.environ["FIREBRAT_CAST_BATCH"] = n
    return old


def restore_batch(old):
    if old is None:
        os.environ.pop("FIREBRAT_CAST_BATCH", None)
    else:
        os.environ["FIREBRAT_CAST_BATCH"] = old


class BatchSizeTest(unittest.TestCase):
    def test_batch_size_parsing(self):
        old = set_batch("2")
        try:
            self.assertEqual(C._batch_size(), 2)
        finally:
            restore_batch(old)
        old = set_batch("0")
        try:
            self.assertEqual(C._batch_size(), 1)  # clamped >= 1
        finally:
            restore_batch(old)
        old = set_batch("bogus")
        try:
            self.assertEqual(C._batch_size(), 8)  # fallback on bad value
        finally:
            restore_batch(old)
        old = set_batch(None)
        try:
            self.assertEqual(C._batch_size(), 8)  # default
        finally:
            restore_batch(old)


class GenerateManyTest(unittest.TestCase):
    def test_uses_batch_when_present(self):
        fake = BatchFake(["a", "b", "c"])
        self.assertEqual(generate_many(fake, "sys", ["u1", "u2", "u3"]), ["a", "b", "c"])
        self.assertEqual(fake.batch_calls, 1)
        self.assertEqual(fake.single_calls, [])

    def test_sequential_fallback_without_batch_method(self):
        fake = SeqFake(["a", "b"])
        self.assertEqual(generate_many(fake, "sys", ["u1", "u2"]), ["a", "b"])
        self.assertEqual(len(fake.calls), 2)

    def test_empty_users(self):
        self.assertEqual(generate_many(SeqFake([]), "sys", []), [])


class BatchParityTest(unittest.TestCase):
    def test_attribution_batch_sizes_agree(self):
        old = set_batch("2")
        try:
            chunks = one_quote_chunks(PAGES4)
            n = len(chunks)

            def replies():
                return [json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
                        for _ in range(n)]

            a = C.attribution_pass(chunks, chars(), BatchFake(replies()),
                                   C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        old = set_batch("100")
        try:
            chunks = one_quote_chunks(PAGES4)
            n = len(chunks)

            def replies():
                return [json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
                        for _ in range(n)]

            b = C.attribution_pass(chunks, chars(), BatchFake(replies()),
                                   C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        self.assertEqual(a, b)

    def test_attribution_batch_matches_sequential_fake(self):
        chunks = one_quote_chunks(PAGES4)
        n = len(chunks)
        old = set_batch("2")
        try:
            batched = C.attribution_pass(
                chunks, chars(),
                BatchFake([json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
                           for _ in range(n)]),
                C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        seq = C.attribution_pass(
            chunks, chars(),
            SeqFake([json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
                     for _ in range(n)]),
            C.ChunkCache(tempfile.mkdtemp()))
        self.assertEqual(batched, seq)

    def test_roster_batch_matches_sequential(self):
        segs = segment_pages(PAGES4)
        windows = C.make_windows(segs, size=20, overlap=5)
        old = set_batch("2")
        try:
            _, roster_b = C.roster_pass(windows, BatchFake([ROSTER_REPLY] * len(windows)),
                                        C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        _, roster_s = C.roster_pass(windows, SeqFake([ROSTER_REPLY] * len(windows)),
                                    C.ChunkCache(tempfile.mkdtemp()))
        self.assertEqual(roster_b, roster_s)


class OrderTest(unittest.TestCase):
    def test_quotes_mapped_to_correct_chunks(self):
        chunks = one_quote_chunks(PAGES4)[:3]
        speakers = ["char_001", "narrator", "char_001"]
        emotions = ["joy", "sadness", "anger"]
        replies = [json.dumps({"utterances": [[0, sp, em, f"d{i}"]]})
                   for i, (sp, em) in enumerate(zip(speakers, emotions))]
        old = set_batch("10")  # all chunks in one batch
        try:
            attrib = C.attribution_pass(chunks, chars(), BatchFake(replies),
                                        C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        for chunk, sp, em, i in zip(chunks, speakers, emotions, range(3)):
            quote = next(s for s in chunk if s["kind"] == "quote")
            self.assertEqual(attrib[(quote["page"], quote["idx"])], (sp, em, f"d{i}"))


class FailingItemTest(unittest.TestCase):
    def test_bad_chunk_falls_back_without_losing_batch(self):
        chunks = one_quote_chunks(PAGES4)[:2]
        good = json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
        # Batch reply for chunk 1 is garbage; repair path also garbage.
        fake = BatchFake([good, "not json at all"], single_texts=["still {broken"])
        old = set_batch("10")
        try:
            attrib = C.attribution_pass(chunks, chars(), fake,
                                        C.ChunkCache(tempfile.mkdtemp()))
        finally:
            restore_batch(old)
        q0 = next(s for s in chunks[0] if s["kind"] == "quote")
        q1 = next(s for s in chunks[1] if s["kind"] == "quote")
        self.assertEqual(attrib[(q0["page"], q0["idx"])], ("char_001", "joy", "warmly"))
        # Chunk 1 fell back to regex/narrator rather than losing the batch.
        self.assertEqual(attrib[(q1["page"], q1["idx"])][0], "narrator")
        self.assertEqual(attrib[(q1["page"], q1["idx"])][1], "neutral")


class ResumeTest(unittest.TestCase):
    def test_second_run_makes_zero_llm_calls(self):
        old = set_batch("2")
        try:
            chunks = one_quote_chunks(PAGES4)
            n = len(chunks)
            cache_dir = tempfile.mkdtemp()
            fake = BatchFake([json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})
                              for _ in range(n)])
            first = C.attribution_pass(chunks, chars(), fake, C.ChunkCache(cache_dir))
            self.assertGreater(fake.batch_calls + len(fake.single_calls), 0)
            before = (fake.batch_calls, len(fake.single_calls))
            second = C.attribution_pass(chunks, chars(), fake, C.ChunkCache(cache_dir))
            self.assertEqual((fake.batch_calls, len(fake.single_calls)), before)
            self.assertEqual(first, second)
        finally:
            restore_batch(old)


class EnvBatchWidthTest(unittest.TestCase):
    def test_batch_one_means_one_call_per_chunk(self):
        old = set_batch("1")
        try:
            chunks = one_quote_chunks(PAGES4)[:3]
            n_uncached = sum(1 for c in chunks
                             if any(s["kind"] == "quote" for s in c))
            fake = BatchFake([json.dumps({"utterances": [[0, "narrator", "neutral", ""]]})
                              for _ in range(n_uncached)])
            C.attribution_pass(chunks, chars(), fake, C.ChunkCache(tempfile.mkdtemp()))
            self.assertEqual(fake.batch_calls, n_uncached)
        finally:
            restore_batch(old)


class NoBatchMethodTest(unittest.TestCase):
    def test_roster_and_attribution_work_without_generate_text_batch(self):
        segs = segment_pages(PAGES4)
        windows = C.make_windows(segs, size=20, overlap=5)
        _, roster = C.roster_pass(windows, SeqFake([ROSTER_REPLY] * len(windows)),
                                  C.ChunkCache(tempfile.mkdtemp()))
        self.assertTrue(any(c["name"] == "Caroline Bingley" for c in roster))
        chunks = one_quote_chunks(PAGES4)[:1]
        attrib = C.attribution_pass(
            chunks, chars(),
            SeqFake([json.dumps({"utterances": [[0, "char_001", "joy", "warmly"]]})]),
            C.ChunkCache(tempfile.mkdtemp()))
        quote = next(s for s in chunks[0] if s["kind"] == "quote")
        self.assertEqual(attrib[(quote["page"], quote["idx"])][0], "char_001")


if __name__ == "__main__":
    unittest.main()

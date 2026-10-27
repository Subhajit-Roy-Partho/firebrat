"""Offline tests for segmenter.py (stdlib + unittest only)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from firebrat_cast.segmenter import MAX_LEN, segment_pages


def pages(*texts):
    return [{"page_idx": i, "text": t} for i, t in enumerate(texts)]


class SegmenterTest(unittest.TestCase):
    def test_quote_narration_split(self):
        segs = segment_pages(pages('\u201cHello,\u201d Elizabeth said. \u201cHow are you?\u201d'))
        kinds = [s["kind"] for s in segs]
        self.assertEqual(kinds, ["quote", "narration", "quote"])
        self.assertEqual(segs[0]["text"], "\u201cHello,\u201d")
        self.assertIn("Elizabeth said", segs[1]["text"])

    def test_straight_quotes(self):
        segs = segment_pages(pages('He whispered "be quiet" and left.'))
        self.assertEqual([s["kind"] for s in segs], ["narration", "quote", "narration"])

    def test_lossless(self):
        text = '  \nIt was the best of times. "Indeed," she said, "quite the best."\n\nTail.  '
        segs = segment_pages(pages(text))
        self.assertEqual("".join(s["text"] for s in segs), text)

    def test_long_split_at_sentence_boundary(self):
        sent = "Word " * 60 + ". "  # ~300 chars per sentence
        text = sent + sent + sent
        segs = segment_pages(pages("Narration intro. " + text + "End bit here."))
        for s in segs:
            self.assertLessEqual(len(s["text"]), MAX_LEN, s["text"][:60])
        self.assertEqual("".join(s["text"] for s in segs),
                         "Narration intro. " + text + "End bit here.")
        self.assertTrue(any(s["text"].rstrip().endswith(".") for s in segs[:-1]))

    def test_long_single_token_never_hangs(self):
        segs = segment_pages(pages("x" * 900))
        self.assertEqual("".join(s["text"] for s in segs), "x" * 900)
        for s in segs:
            self.assertLessEqual(len(s["text"]), MAX_LEN)

    def test_stable_keys(self):
        segs = segment_pages(pages('A "one" b.', "", "  ", 'C "two" d "three".'))
        keys = [(s["page"], s["idx"]) for s in segs]
        self.assertEqual(len(set(keys)), len(keys))
        self.assertEqual([k for k in keys if k[0] == 0],
                         [(0, 0), (0, 1), (0, 2)])
        self.assertEqual([k for k in keys if k[0] == 3][0], (3, 0))

    def test_empty_pages_skipped(self):
        segs = segment_pages(pages("", "   ", "Some prose here."))
        self.assertEqual(len(segs), 1)
        self.assertEqual((segs[0]["page"], segs[0]["idx"]), (2, 0))


if __name__ == "__main__":
    unittest.main()

"""QwenVoiceEngine with a fake qwen_tts model (no GPU, no torch)."""
import json

import pytest

np = pytest.importorskip("numpy")

from firebrat_cast import tts_qwen
from firebrat_cast.tts_qwen import QwenVoiceEngine


class FakeModel:
    def __init__(self, kind, log):
        self.kind, self.log = kind, log

    def _wav(self, n):
        return np.full(int(24000 * n), 0.1, dtype=np.float32)

    def generate_voice_design(self, text, instruct, language=None, **kw):
        assert self.kind == "design"
        self.log.append(("design", list(text), list(instruct), kw))
        return [self._wav(8.0 if len(t) > 40 else 1.0) for t in text], 24000

    def create_voice_clone_prompt(self, ref_audio, ref_text=None, x_vector_only_mode=False):
        assert self.kind == "base"
        arr, sr = ref_audio
        self.log.append(("prompt", len(arr), sr, ref_text, x_vector_only_mode))
        return [("prompt", len(arr))]

    def generate_voice_clone(self, text, language=None, voice_clone_prompt=None, **kw):
        assert self.kind == "base" and len(voice_clone_prompt) == len(text)
        self.log.append(("clone", list(text), kw))
        return [self._wav(len(t) * 0.07) for t in text], 24000


def make(tmp_path, **kw):
    log = []

    def loader(name):
        log.append(("load", "design" if "VoiceDesign" in name else "base"))
        return FakeModel("design" if "VoiceDesign" in name else "base", log)

    eng = QwenVoiceEngine(model_loader=loader, batch_size=2, **kw)
    return eng, log


def test_voices_dir_is_optional_and_required_before_use(tmp_path):
    eng, _ = make(tmp_path)
    with pytest.raises(RuntimeError, match="bind_book"):
        eng.anchor("narrator")


def test_anchors_minted_in_one_design_batch_then_base_loaded_once(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("book-a", tmp_path / "a" / "voices", {"c1": "deep voice", "narrator": "warm"})
    eng.ensure_anchors(["narrator", "c1", "c1"])
    designs = [e for e in log if e[0] == "design"]
    assert len(designs) == 1 and len(designs[0][1]) == 2  # one batch, deduplicated
    assert "deep voice" in " ".join(designs[0][2])
    meta = json.loads((tmp_path / "a" / "voices" / "c1.json").read_text())
    assert meta["book_id"] == "book-a" and meta["ref_text"] == tts_qwen.DEFAULT_ANCHOR_TEXT
    out = eng.speak_many([{"text": "Hello there, my friend.", "speaker_id": "c1"},
                          {"text": "Hi.", "speaker_id": "narrator"},
                          {"text": "A third line of text.", "speaker_id": "c1"}], seed=7)
    assert len(out) == 3 and all(sr == 24000 and w.dtype == np.float32 for w, sr in out)
    assert [e[1] for e in log if e[0] == "load"] == ["design", "base"]
    clones = [e for e in log if e[0] == "clone"]
    assert [len(c[1]) for c in clones] == [2, 1]  # chunked by batch_size
    assert clones[0][2]["max_new_tokens"] >= 48
    prompts = [e for e in log if e[0] == "prompt"]
    assert len(prompts) == 2  # one cached prompt per speaker, not per line
    assert prompts[0][3] is None and prompts[0][4] is True  # x-vector only


def test_anchors_are_per_book(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("a", tmp_path / "a", {"char_001": "voice A"})
    eng.ensure_anchors(["char_001"])
    eng.bind_book("b", tmp_path / "b", {"char_001": "voice B"})
    eng.ensure_anchors(["char_001"])
    assert (tmp_path / "a" / "char_001.wav").is_file() and (tmp_path / "b" / "char_001.wav").is_file()
    assert json.loads((tmp_path / "a" / "char_001.json").read_text())["description"] == "voice A"
    assert json.loads((tmp_path / "b" / "char_001.json").read_text())["description"] == "voice B"
    assert len([e for e in log if e[0] == "design"]) == 2


def test_existing_anchor_is_reused(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("a", tmp_path, {})
    eng.ensure_anchors(["narrator"])
    n = len([e for e in log if e[0] == "design"])
    eng2, log2 = make(tmp_path)
    eng2.bind_book("a", tmp_path, {})
    eng2.ensure_anchors(["narrator"])
    assert n == 1 and not [e for e in log2 if e[0] == "design"]


def test_odd_length_anchor_is_reminted(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("a", tmp_path, {})
    eng.anchor_text = "short"  # fake model returns 1 s for short text -> out of range, then gives up
    eng.ensure_anchors(["narrator"])
    assert len([e for e in log if e[0] == "design"]) == 3
    assert (tmp_path / "narrator.wav").is_file()


def test_speak_rejects_empty_text(tmp_path):
    eng, _ = make(tmp_path)
    eng.bind_book("a", tmp_path, {})
    with pytest.raises(ValueError):
        eng.speak("   ", "narrator")


def test_design_mode_uses_emotion_instruct(tmp_path):
    eng, log = make(tmp_path, use_design_per_line=True)
    eng.bind_book("a", tmp_path, {"narrator": "warm"})
    eng.speak_many([{"text": "A long enough line to pass the fake duration checks.", "speaker_id": "narrator",
                     "emotion": "anger", "delivery": "through clenched teeth"}])
    instr = [e for e in log if e[0] == "design"][-1][2][0]
    assert "warm" in instr and "controlled anger" in instr and "clenched" in instr


def test_max_new_tokens_scales_with_text():
    assert tts_qwen.max_new_tokens_for(["x" * 10]) == 62 or tts_qwen.max_new_tokens_for(["x" * 10]) >= 48
    assert tts_qwen.max_new_tokens_for(["x" * 350]) > tts_qwen.max_new_tokens_for(["x" * 50])
    assert tts_qwen.max_new_tokens_for(["x" * 5000]) == 2048


def test_make_tts_engine_needs_no_voices_dir():
    from firebrat_cast import queue_runner as q

    eng = q.make_tts_engine("qwen")
    assert isinstance(eng, QwenVoiceEngine) and eng.voices_dir is None


def test_decoder_batching_patch_splits_calls():
    calls = []

    class Tok:
        def decode(self, items):
            calls.append(len(items))
            return [np.zeros(3, np.float32) for _ in items], 24000

    class Inner:
        speech_tokenizer = Tok()

    class Wrapper:
        model = Inner()

    w = Wrapper()
    tts_qwen.patch_decoder_batching(w, chunk=4)
    tts_qwen.patch_decoder_batching(w, chunk=4)  # idempotent
    wavs, fs = w.model.speech_tokenizer.decode([{}] * 10)
    assert calls == [4, 4, 2] and len(wavs) == 10 and fs == 24000
    tts_qwen.patch_decoder_batching(object())  # no tokenizer: no crash


def test_chunks_respect_row_and_token_budget(tmp_path):
    eng, _ = make(tmp_path)
    eng.batch_size, eng.token_budget = 4, 1000
    short = [{"text": "x" * 20} for _ in range(10)]          # 56 expected frames each
    assert [len(c) for c in eng._chunks(short)] == [4, 4, 2]
    long_ = [{"text": "x" * 600} for _ in range(5)]          # 810 expected frames -> 1 row per call
    assert [len(c) for c in eng._chunks(long_)] == [1] * 5
    mixed = short[:3] + long_[:1]
    assert [len(c) for c in eng._chunks(mixed)] == [3, 1]
    assert eng._chunks([]) == []


def test_oom_splits_the_batch(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("a", tmp_path, {})
    eng.ensure_anchors(["narrator"])
    base = eng._ensure("base")
    real = base.generate_voice_clone
    sizes = []

    def flaky(text, **kw):
        sizes.append(len(text))
        if len(text) > 2:
            raise RuntimeError("CUDA out of memory. Tried to allocate 2 GiB")
        return real(text=text, **kw)

    base.generate_voice_clone = flaky
    eng.batch_size = 8
    out = eng.speak_many([{"text": f"line number {i} here", "speaker_id": "narrator"} for i in range(6)])
    assert len(out) == 6 and sizes[0] == 6 and max(sizes[1:]) <= 3


class EmbModel(FakeModel):
    """Anchor wav amplitude encodes a 'voice id' that create_voice_clone_prompt turns into an embedding."""

    def generate_voice_design(self, text, instruct, language=None, **kw):
        self.log.append(("design", list(text), list(instruct), kw))
        wavs = []
        for ins in instruct:
            if any(t in ins for t in tts_qwen.CONTRAST_TRAITS):
                level = 0.7  # contrasting variant -> clearly different voice
            elif ins.startswith("voice C"):
                level = 0.3
            else:
                level = 0.1
            wavs.append(np.full(int(24000 * 8.0), level, dtype=np.float32))
        return wavs, 24000

    def create_voice_clone_prompt(self, ref_audio, ref_text=None, x_vector_only_mode=False):
        arr, _ = ref_audio
        level = round(float(arr[100]), 1)
        emb = np.zeros(4, np.float32)
        emb[0 if level == 0.1 else 1 if level == 0.3 else 2] = 1.0
        return [type("Item", (), {"ref_spk_embedding": emb})()]


def test_clashing_anchors_are_reminted_with_a_contrasting_trait(tmp_path):
    log = []

    def loader(name):
        return EmbModel("design" if "VoiceDesign" in name else "base", log)

    eng = QwenVoiceEngine(model_loader=loader)
    eng.bind_book("a", tmp_path, {"A": "voice A", "B": "voice B", "C": "voice C"})
    eng.ensure_anchors(["A", "B", "C"])
    metas = {c: json.loads((tmp_path / f"{c}.json").read_text()) for c in "ABC"}
    assert metas["A"]["variant"] == 0 and metas["C"]["variant"] == 0
    assert metas["B"]["variant"] >= 1 and any(t in metas["B"]["instruct"] for t in tts_qwen.CONTRAST_TRAITS)


def test_anchor_oom_is_minted_in_halves(tmp_path):
    eng, log = make(tmp_path)
    eng.bind_book("a", tmp_path, {})
    design = eng._ensure("design")
    real = design.generate_voice_design
    sizes = []

    def flaky(text, instruct, language=None, **kw):
        sizes.append(len(text))
        if len(text) > 2:
            raise RuntimeError("CUDA out of memory. Tried to allocate 3.48 GiB")
        return real(text=text, instruct=instruct, language=language, **kw)

    design.generate_voice_design = flaky
    eng.ensure_anchors(["narrator", "c1", "c2", "c3", "c4"])
    assert sizes[0] == 5 and max(sizes[1:]) <= 3
    assert all((tmp_path / f"{c}.wav").is_file() for c in ("narrator", "c1", "c2", "c3", "c4"))

"""Run one GPU stage (cast or synth) for a set of books in this process, then exit so the VRAM is freed.

Used by queue_runner with --llm-python / --tts-python so each stage can live in its own venv:
    python -m firebrat_cast.stage_proc cast-wave  --catalog C --root R --slugs a,b
    python -m firebrat_cast.stage_proc synth-wave --catalog C --root R --slugs a,b
"""
import argparse
import logging
import sys

from firebrat_cast import queue_runner as q


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser()
    p.add_argument("command", choices=("cast-wave", "synth-wave"))
    p.add_argument("--catalog", required=True)
    p.add_argument("--root", required=True)
    p.add_argument("--slugs", required=True)
    p.add_argument("--llm-backend", default="local")
    p.add_argument("--tts", default="qwen")
    a = p.parse_args(argv)
    cfg = q.RunnerConfig(catalog=a.catalog, root=a.root, llm_backend=a.llm_backend, tts=a.tts)
    wanted = a.slugs.split(",")
    wave = [e for e in q.load_catalog(a.catalog) if e["slug"] in wanted]
    failed: set = set()
    if a.command == "cast-wave":
        backend = q.make_llm_backend(a.llm_backend)
        backend.load()
        try:
            q.cast_wave(cfg, wave, backend, failed)
        finally:
            backend.unload()
    else:
        engine = q.make_tts_engine(a.tts)
        engine.load()
        try:
            q.synth_wave(cfg, wave, engine, failed)
        finally:
            engine.unload()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

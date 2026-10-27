# Android: on-device expressive narration, models, GPU/NPU findings

Written 2026-10-27 when resuming session 1324bb8d after its session limit. The original agent stopped before writing this; everything below is taken from its logs and the repo. Items marked **UNVERIFIED** were not run on a device.

## 1. State

- On-device **Expressive (experimental)** mode is wired end to end in code: `BookContentMode.expressive` -> `pipeline/expressive_conversion.dart` (`prepareExpressive`) -> `cast/*` (LLM casting) -> `tts/cast_narration_engine.dart` -> package with manifest `cast` key. The Flutter settings screen offers it (`conversion_settings_screen.dart`, `ExpressiveModelControls`).
- Tests: `mobile-Backend` `flutter test` 188 passed / 3 skipped; `frontend/firebrat_app` `flutter analyze` clean and `flutter test` 146 passed.
- **UNVERIFIED on a device:** the full expressive conversion (`integration_test/expressive_e2e_test.dart`) never completed on the Pixel 9a. The last benchmark run (bench6) also aborted with the phone locked.

## 2. Speech engines (Pixel 9a, Tensor G4, ~7.7 GB RAM; real-time factor, lower is faster)

| Setup | RTF |
|---|---|
| Kokoro fp32 / fp16 / int8, CPU | ~0.58-0.77 / ~0.60-0.79 / ~0.75-0.85 |
| Kokoro fixed-shape fp16 / int8, CPU | ~0.75-0.79 / ~1.3 |
| Kokoro, NNAPI, normal models | 0.6-0.99 (only ~44 of ~3,900 ops delegated) |
| Kokoro, NNAPI, fixed-shape | 3.8-4.6 (~66 ops delegated, 22-47 s NNAPI vs 5-11 s CPU) |
| Kokoro, XNNPACK (bench6, 4 threads) | slower than CPU: 5.6 (fp32 short) to >5 on fp16 mid text |

Conclusions: CPU is fastest; NNAPI/XNNPACK give no speedup; int8 is not faster than fp32/fp16 here; two NNAPI variants fail outright. **No usable GPU/NPU path exists for Kokoro through the bundled ONNX Runtime** (no QNN libs; dynamic shapes). Default is CPU; accelerated options stay selectable with CPU fallback and a truthful "Running on" status. Piper (VITS, libritts_r multi-speaker) is the second engine: many voices, ~0.1x per the code comment (**UNVERIFIED** here).

Native: `android/.../OrtBridge.kt` is the app's own ONNX Runtime bridge (per-provider control, per-op delegation counts). Benchmark code: `lib/src/tts/tts_benchmark.dart`, `frontend/firebrat_app/integration_test/tts_benchmark_test.dart`.

## 3. LLM casting quality (desktop llama.cpp eval, `cast/cast_eval.dart`, `tool/cast_eval_cli.dart`)

json1 = valid JSON first try, spk = speaker attribution accuracy, emoG = emotion match.

| model | json1 | spk | emoG | wall s |
|---|---|---|---|---|
| qwen3-8b-q4 | 1.00 | 0.51 | 0.58 | 396 |
| qwen3-4b-2507-q4 | 0.88 | 0.56 | 0.42 | 174 |
| qwen3.5-4b-q4 | 0.65 | 0.53 | 0.52 | 196 |
| ministral3-3b-q4 | 0.96 | 0.49 | 0.47 | 279 |
| gemma3n-e4b-q4 | 0.69 | 0.39 | 0.61 | 281 |
| 0.6-2B models | 0.00-0.65 | 0.17-0.28 | 0.26-0.48 | 55-265 |
| phi4-mini-q4 | failed to produce a roster | | | |

Recommendation: `qwen3-4b-2507-q4` is the best fit for a 7.7 GB phone; below ~3B attribution is poor and the regex fallback in the existing novel analyzer does as well. These are **desktop** numbers; tokens/s and memory on the phone are **UNVERIFIED**, and the catalog RAM/tier numbers have not yet been replaced with measured values.

## 4. Re-running

```sh
cd mobile-Backend && flutter test            # unit tests incl. cast engine with a fake LLM
cd frontend/firebrat_app && flutter analyze && flutter test
```
Device runs need a scratch copy with a `.debug` application id so the owner's real app (`com.firebrat.firebrat_app`) is never touched: copy the working tree (not git HEAD) to a scratch dir, add `applicationIdSuffix = ".debug"` to the debug buildType and a matching client entry in `google-services.json` **in the copy only**, `flutter build apk --debug --target-platform android-arm64`, `adb install -r`, then `flutter test integration_test/<file>.dart -d <serial>`. The e2e and eval tests read their inputs (EPUB, GGUF, Piper/Kokoro files, `e2e_config.json` last) from `/sdcard/Android/data/com.firebrat.firebrat_app.debug/files/e2e/`; see the header comment of each test. Keep the screen awake (`adb shell input keyevent KEYCODE_WAKEUP`, `svc power stayon usb`, revert afterwards).

## 5. Next steps

1. Run `expressive_e2e_test.dart` on the phone with qwen3-4b-2507 + Piper (and Kokoro) on `alice_excerpt.epub`; record time, memory and whether the Cast screen shows the roster.
2. Measure llama.cpp tokens/s and RAM for the catalog models on the phone and update the catalog tiers.
3. Measure Piper RTF on the phone; decide the default expressive engine.
4. Honest on-screen time estimate: `pipeline/expressive_estimate.dart` exists, verify it against step 1.

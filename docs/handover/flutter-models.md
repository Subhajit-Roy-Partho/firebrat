# Handover: Flutter on-device models, accelerators, download network policy (2026-10-26)

Scope: `mobile-Backend/**` and `frontend/firebrat_app/**` only. Nothing committed. No APK was built, no emulator or device was used.

## 1. What changed

### Models and voices
- **LLM catalog** (`mobile-Backend/lib/src/compilation/model_catalog.dart`): 8 existing models kept (same ids/files; default still `qwen3-1.7b`, 0 GPU layers) and 5 added:
  Llama 3.2 1B (Light), Qwen3 8B and Llama 3.1 8B (Powerful), Gemma 3 12B and Qwen3 14B (Desktop-class). New fields: `tier`, `minDeviceRamGb`, `license`, `licenseUrl`, `runtime`, `acceleration`, `sha256`.
  Sizes and SHA-256 come from Hugging Face LFS metadata (bartowski GGUF Q4_K_M, read 2026-10-26). Only architectures the pinned llama.cpp already loads (Qwen3, Llama 3.x, Gemma 3, Phi-4-mini) are offered; Qwen3.5/hybrid architectures were NOT added because loading could not be verified.
- **TTS catalog** (`mobile-Backend/lib/src/models/tts_model_catalog.dart`): Kokoro-82M `int8` (default, verified on a Pixel 9a earlier), `fp16` (163 MB, Balanced), `fp32` (326 MB, Powerful); plus 5 extra voices (Sky, Emma, Isabella, George, Lewis; British voices included), 11 voices in total. All from the same pinned HF revision (`f46687f7...`) the stock downloader uses, with SHA-256. `KokoroAssets` (`tts/kokoro_assets.dart`) downloads the extras with Range resume + checksum.
- Automatic character casting still draws from the original six voices (so conversions of old books stay reproducible); the new voices are selectable as narrator, male preset, female preset, or per-character override.
- `ModelDownloader` now takes any `DownloadableAsset`, verifies SHA-256 on fresh downloads only (an existing file within 2% is still accepted, so user-imported GGUFs are never deleted).

### Device capability, recommendation, warnings
- `models/device_capabilities.dart`: `DeviceCapabilities` (RAM, ABIs, API level, ORT providers) -> tier; `assessFit()` returns good/tight/too-large plus plain text ("needs about 16 GB RAM but this phone has 4 GB"); `recommendLlm()` picks the largest model that fits with margin and never above the phone's tier (unknown RAM -> safe default). The app probes with `device_info_plus` (`lib/services/device_probe.dart`; failure -> unknown -> treated as low-end, no scary warnings).
- Storage: the UI states download size and "keep at least X GB free". Free space is NOT measured (no existing plugin; not added). Stated as text only.

### Accelerator selector (Auto / GPU-NPU / CPU) with CPU fallback
- `tts/accelerator.dart`: `AcceleratorPreference` -> `planAccelerators()` (always ends in CPU) -> `AcceleratedSession` (tries each back end in order; if a run fails on an accelerator it closes the session, switches to CPU and retries once; CPU errors are real errors).
- `FirebratKokoroTts` now builds its ORT session through it (NNAPI / XNNPACK / CPU providers) and falls back to the int8 model when a chosen variant is not downloaded. After a narration it writes `<kokoro dir>/last_run.json` (`status`, `backend`, `requested`, `notes`, `realtime_factor`); the settings screen shows "Running on: ..." from it and the pipeline reports it in progress text.
- **Auto** resolves to CPU for the default model (identical to before). It tries NNAPI only for the fp16 model on Android 10+ with a Balanced-or-better phone. **GPU / NPU** = NNAPI first (XNNPACK if no NNAPI), then CPU.
- Saved settings migrate: legacy `cpu` -> CPU, legacy `nnapi` -> GPU/NPU, missing -> Auto (= CPU for the default model). New settings keys: `conversion.ttsModelId`, `download.networkPreference`. `ConversionRequest` JSON gained optional `ttsModelId`, `deviceRamMb`, `androidSdk` (old JSON still loads).
- LLM: `OnDeviceCompiler` worker now retries with 0 GPU layers if a GPU load fails, and reports "language model running on: GPU/CPU".

### Download network preference ("Download over")
- Pure policy: `mobile-Backend/lib/src/network/download_network_policy.dart` (`NetworkPolicy.decide(preference, network, sizeBytes) -> allow | wait | ask`). Gate/resume logic: `network_gate.dart` (`NetworkGate.waitUntilAllowed`, `runGated`). Default for everyone is Wi-Fi and cellular (no restriction); ask threshold 50 MB; offline + unrestricted keeps the old behaviour (attempt and fail), restricted modes wait.
- App: `lib/services/app_network_gate.dart` (connectivity_plus ^7.3.1 added; resolves cleanly), setting UI `DownloadNetworkSetting` at the bottom of Conversion settings (3 radio choices, Wi-Fi recommendation, live "Network: Wi-Fi/Cellular/Offline" chip, also next to LLM and Kokoro downloads).
- Enforced in: LLM model downloads (`model_download_providers.dart`, pause + resume via Range/.part), Kokoro model variants and extra voices (`kokoro_model_controls.dart`), server book downloads (`download_manager.dart`; new `waiting` phase shown in cards and notification), Drive upload and download (`drive_sync_service.dart`, so every caller is covered; download pauses/resumes with Range, upload waits before starting), community "Add to my library" (`community_screen.dart`; waits before starting with a visible message, because `dio.download` cannot resume), and the conversion start (`on_device_pipeline_run_provider.dart` waits for missing models before the background service starts). "Ask" shows a dialog with the size (Wait for Wi-Fi / Download now); declining keeps waiting instead of failing.
- `download_task_handler.dart` needed no change: it is only a keep-alive notification shell, the transfers run on the main isolate and are gated there.

## 2. Research findings (what was checked, with sources)

**Why Kokoro was CPU-only.** `FirebratKokoroTts` (adapted from pinned `flutter_kokoro_tts 0.0.1`) already asked for `OrtProvider.NNAPI` when settings said `nnapi`, otherwise CPU. The `flutter_onnxruntime` 1.8.5 Android plugin (read from the pub cache) calls `addNnapi()` / `addXnnpack(mapOf())` on `onnxruntime-android:1.23.0`; QNN is in the Dart enum but that AAR does not ship the Qualcomm QNN libraries, so QNN is not usable. There is no GPU provider for ONNX Runtime on Android other than NNAPI (which may use GPU/NPU/DSP but is a vendor-driver lottery).
- ONNX Runtime NNAPI EP docs: https://onnxruntime.ai/docs/execution-providers/NNAPI-ExecutionProvider.html (Android 8.1+, 9+ recommended, per-operator restrictions).
- ONNX Runtime fixed-shape guide ("NNAPI does not support dynamic input shapes"): https://onnxruntime.ai/docs/tutorials/mobile/helpers/make-dynamic-shape-fixed.html. Kokoro's `input_ids` length varies per sentence, so most of the graph would fall back to CPU per node. Expect little or no speedup, possibly a slowdown, plus extra session-creation time.
- **Conclusion: true Kokoro GPU/NPU acceleration is NOT achievable with the current packages in a verified way.** What was delivered instead: a working, honest NNAPI/XNNPACK request path with automatic CPU fallback, a visible "running on" status, an fp16 model (the variant NNAPI handles best), and Auto = CPU for the verified default.

**sherpa-onnx.** pub.dev has `sherpa_onnx` (2.0.1 at the time of research, with per-ABI android packages). Its C++ provider parser accepts `cpu`, `xnnpack`, `nnapi` (https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/sherpa-onnx/csrc/provider.cc); I found no `qnn` there. It would give Piper/VITS, Matcha and Kokoro models, but it ships its own `libonnxruntime.so` which will collide with the one in `onnxruntime-android` pulled by `flutter_onnxruntime`/`flutter_kokoro_tts` (duplicate native library packaging errors on Android) and I cannot verify an APK build on this laptop by rule. Also its acceleration story is the same NNAPI/XNNPACK. **Not added.** Next step if wanted: replace `flutter_onnxruntime` + `flutter_kokoro_tts` with sherpa-onnx wholesale in a branch and build on CI. Search result for context: a third-party React Native wrapper claims NNAPI/XNNPACK/QNN/Core ML (https://www.mintlify.com/xdcobra/react-native-sherpa-onnx), not evidence for the Flutter package.

**Piper/VITS/Matcha via plain ORT.** Needs a different phonemizer pipeline/phoneme maps; not verifiable here, so not offered (the catalog only lists what the current runtime loads).

**LLM GPU.** The existing llama.cpp build already offloads layers to Vulkan (slider = layers). No new runtime added (MediaPipe/LiteRT-LM have a different model format and no verified Dart package here). The large models are CPU-bound on phones in practice.

**Licences** (permissive preferred): Kokoro-82M weights Apache-2.0; Qwen3 family Apache-2.0; SmolLM2 Apache-2.0; Phi-4-mini MIT. NOT OSI/permissive: Llama 3.1/3.2 (Meta community licences) and Gemma 3 (Gemma Terms of Use, use restrictions and notice duties). They are labelled in the UI; ship/redistribute decisions are the owner's. Models are downloaded by the user from Hugging Face, not bundled in the app. espeak-ng (the phonemizer in `flutter_kokoro_tts`) is GPL-3.0; that pre-existing dependency is worth a licence review before a Play Store release (not changed here).

## 3. Verification (commands and results)
- `cd mobile-Backend && flutter analyze` -> only 4 pre-existing infos in old tests (none in new code). `flutter test --exclude-tags live` -> 142 passed, 3 skipped (existing). New: `model_catalog_test.dart`, `accelerator_test.dart`, `network_policy_test.dart` (catalog fields/unique ids/tier ordering, recommendation, fit warnings, settings migration incl. old `ConversionRequest` JSON, accelerator plans, `AcceleratedSession` fallback with a fake runtime, network policy table, waiting-then-resume and mid-transfer pause with a fake connectivity stream).
- `cd frontend/firebrat_app && flutter pub get && flutter analyze` -> No issues. `flutter test` -> all 146 passed (includes every previously existing test plus the new `download_network_test.dart`: connectivity mapping, default preference for existing users, saved-settings migration, settings widget).
- Dependencies added (all `pub get` resolve): app `connectivity_plus ^7.3.1`, `device_info_plus ^13.1.0` (was already a transitive/overridden dependency); package `crypto ^3.0.6`. `pubspec_overrides.yaml` untouched.
- `dart format` was run only on new files.

## 4. NOT verified on a device (only analysis/unit tests)
- Whether NNAPI is faster, slower or crashes for Kokoro fp16/fp32/int8 on any phone; the fp16/fp32 variants have never been run (input dtypes assumed same as int8: int64 ids, float32 style/speed). Please benchmark: set Speech accelerator to GPU/NPU, run a short book, read "Running on" and `realtime_factor` in `last_run.json`, compare with CPU.
- The new voices' sound, and the big LLMs' memory behaviour (a 9 GB model on a 16 GB phone may still be killed; `minDeviceRamGb` values are estimates).
- The Android connectivity events, the cellular dialog, the notification text, Drive pause/resume on a real network change, foreground-service behaviour while "waiting".
- Known limits: connectivity_plus gives the transport only (no Android "metered" flag, so a metered hotspot looks like Wi-Fi); the stock Kokoro base pack (~110 MB, pinned package downloader) can only be gated before it starts, not paused mid-file; community downloads restart from zero if interrupted (existing behaviour); free storage is not measured; models missing at conversion start are gated once up front, a later network change during the background service is not paused.
- UI is analysed and widget-tested at narrow width for the settings screen, not visually reviewed on a device.

## 5. Next steps
1. Benchmark Kokoro on one or two real phones (CPU vs GPU/NPU, int8 vs fp16); if NNAPI helps, let Auto pick it for more models, if not, hide the option behind an "experimental" label.
2. Consider sherpa-onnx in a throwaway branch for Piper/Matcha voices and QNN-capable builds, with an APK build on CI to settle the duplicate libonnxruntime question.
3. Optional: read free storage (add a plugin) and the metered flag (small Kotlin method channel) for tighter warnings.
4. Review espeak-ng GPL and Llama/Gemma licence terms before store release.

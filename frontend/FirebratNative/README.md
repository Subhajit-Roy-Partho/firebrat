# Firebrat for iPhone and iPad

Native SwiftUI app on `swift-native`, bundle `com.firebrat.native`, iOS 17+.
Open `FirebratNative.xcodeproj`, select the FirebratNative scheme and an iPhone
or iPad simulator, then Run. Physical-device installs require your Apple signing
team. Dependencies download from pinned official release URLs on the first build.

Offline reading is the default: importing and playing an existing ZIP/TAR.GZ book
never requires a server or account. Settings offers **Offline**, **Server**, and
**On this device**. Preferences and books are stored in this app's own sandbox;
matching Flutter preference names do not synchronize the apps.

## Implemented

- Atomic local package import and server download; streaming ZIP/gzip/TAR extraction
  with checksum, size and path checks, PAX/GNU long names and nested package roots.
- Reader with timed highlighting, figures/formula images/tables, tap-to-seek,
  chapter navigation, saved playback position, speed, delayed autoplay, Focus,
  image zoom, original PDF, lock-screen controls and background audio.
- PDF conversion on the device: PDFKit text, Vision OCR for scanned pages,
  original page images for illustrated books, bounded speech chunks, real audio
  timestamps, source PDF, and a library-compatible manifest.
- Novel mode scans the whole extracted book for explicit named dialogue,
  conservatively infers gender from prose, and supports narrator/male/female
  choices and per-character overrides. Ambiguous speakers use the narrator.
- Apple installed English voices or Kokoro neural speech: Default, Bella, Nicole,
  Sarah, Adam, Michael. Kokoro downloads an approximately 103 MB model once,
  checks SHA-256, then runs locally on CPU with two threads. No stock voice is
  silently substituted when Kokoro fails. Keep the app open during conversion.
- Server PDF/ZIP upload with illustrated/novel type, queue/progress, retry and
  completed-book download. Google and email authentication use Firebase; tokens
  are stored in Keychain and refreshed before authenticated API calls.
- Firebase Apple app registered in project `firebrat-8c597`. Public client config
  is bundled, including its callback URL scheme. No paid hosting was enabled.

## Parity limits

Native conversion defaults to verbatim extracted text. Optional llama.cpp rewriting
supports Qwen3 0.6B, Qwen3 1.7B and Gemma 3 1B (Q4_K_M), with verified model
downloads. Coverage and numeric checks retain the original passage when rewriting
fails or drops content; the conversion report and UI flag passages needing review.
Illustrations are whole source pages, rather than semantic figure crops.
Equation-aware rewriting, cloud/Drive library sync and resumable background
conversion are still separate work. Novel inference is a heuristic, not perfect
literary character identification; review the generated cast and use overrides.
Server conversion uses the existing backend models and richer compilation.
A simulator cannot establish iPhone GPU speed, energy use, heat or speaker quality.

## Validation and measurements

On 2026-10-21, Xcode 27 / iOS 26.3, iPhone 17 Pro simulator on this Mac:

| Check | Result |
|---|---|
| Final iPhone simulator suite | 13 tests passed, 253.2 seconds total |
| iPad simulator suite before LLM additions | 6 tests passed, about 124 seconds |
| Illustrated PDF + Apple speech | Passed, 1 page, 17.694 s audio, source layout retained |
| Scanned PDF + Vision OCR | Passed, expected circuit facts present, 17.694 s audio |
| Novel + Apple speech | Passed, 2 pages, 21.006 s audio, Alice/Bob cast |
| Novel + Kokoro | Passed, 18.147 s audio, Bella/Sarah/Michael; UI test 65.1 s including first model setup |
| Nested archive import, playback, source PDF, offline settings | Passed |
| 32 MiB streaming archive fixture | Passed, about 40.4 MiB peak RSS in standalone extractor test |
| Corrupt ZIP/gzip and traversal fixtures | Rejected |

These are small, original test documents, not full-book quality benchmarks.
Kokoro timing includes download/setup/UI overhead and is not an inference-speed
comparison with Apple speech. Generated WAVs are checked for nonzero signal,
24 kHz mono audio, bounded segment times, expected source facts and cast metadata.
Listening quality needs human review; a passing signal check is not a quality score.
The import fixture is silent test audio, not a narration demonstration.

Reproduce:

```sh
python3 scripts/make_fixtures.py /tmp/firebrat-apple-fixtures
# Copy fixtures to the installed simulator app's Documents folder.
xcodebuild -project FirebratNative.xcodeproj -scheme FirebratNative \
  -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID' \
  -derivedDataPath /tmp/firebrat-apple-build CODE_SIGNING_ALLOWED=NO test
python3 scripts/verify_outputs.py /path/to/simulator/app/data
```

Fixture generation needs reportlab and pdftoppm. UI tests expose fixture-only
buttons in DEBUG builds through test launch environment variables. They add no
production authentication bypass. The loopback preview script disables heavy
conversion workers; it validates transport and reader flows, not server neural
conversion. Live Google account sign-in and physical-device conversion remain unverified;
connected iPad testing is being prepared separately.

## Dependency provenance

`Packages/SherpaOnnxIOS` vendors the unmodified Apache-2.0 Swift wrapper from
Sherpa-ONNX v1.13.8 (revision `11afbd009a7f8c08f4bcf2fc1b265d0df4670fbf`).
Its small iOS-only manifest pins official Sherpa and ONNX Runtime 1.28.2 binaries
with upstream SHA-256 checksums. This avoids downloading unused Mac artifacts,
whose framework symlinks fail validation in this Xcode environment.
Kokoro model URL and verified digest are in `Stores/KokoroRuntime.swift`.

## Apple model measurements (2026-10-21)

These are **simulator CPU measurements on the Mac**, not iPad performance or
battery measurements. Four inference threads, cached Q4_K_M weights, context 2048,
greedy decoding, one original illustrated circuit page, 384-token cap. Times
include local model generation/setup as recorded by the wrapper; downloads and
speech generation are excluded. One final run per model is shown; repeated runs
varied, so these do not establish a general model ranking.

| Model | Download bytes | Prompt / generated tokens | Final generation time | Coverage result |
|---|---:|---:|---:|---|
| Qwen3 0.6B | 484,220,320 | 98 / 33 | 7.631 s | Rejected: paraphrased text omitted literal diagram labels; original retained |
| Qwen3 1.7B | 1,282,439,584 | 98 / 32 | 28.258 s | Accepted by coverage guard; circuit facts and 3 V label retained |
| Gemma 3 1B | 806,058,496 | 89 / 37 | 5.129 s | Rejected: spelled numeric label “3 V” as words; conservative numeric check retained original |

Gemma was faster on this tiny fixture, but the numeric rejection is a guard
limitation rather than evidence of a wrong voltage. Qwen 1.7B acceptance is not a
proof of semantic correctness. All rewritten books require human review. Whole
books, energy use and thermals have not been benchmarked here.

A simulator Metal attempt reached the 120-second generation deadline. The UI
test completed through source-text fallback, so it was **not successful GPU
inference**. Simulator builds now explicitly use CPU, even when Metal is
requested; a separate test verifies that behavior. Physical-device Metal is
opt-in and still needs measurement.

The first Qwen 0.6B cold download stalled and exceeded the UI test deadline. Its
partial file was resumed on the Mac, SHA-256 verified, and seeded into the test
simulator. Thus the final inference pass does not validate a fresh cold download
for that model. A dedicated progress/cancellation-aware download session is now
used, but interrupted downloads are not yet resumable in the app.

All six Kokoro presets generated actual audio in a six-character novel fixture:
Default, Bella, Nicole, Sarah, Adam and Michael. Named male/female assignments and
per-character voice selections were checked. This is a functional check, not a
perceptual quality score. The approved listening sample uses actual Kokoro speech.

## Runtime and releases

`Packages/LlamaIOS` pins llama.cpp b11797. Its official build script creates both
physical iOS and simulator slices; `scripts/build_llama_runtime.sh` verifies the
source archive and packages the runtime. The binary is a release asset rather
than a committed framework. See the package manifest for its URL and checksum.
Third-party license notices are bundled with the app.

Release packaging uses `scripts/package_unsigned_ipa.sh`. An unsigned IPA cannot
be installed directly on an iPad: it must be signed and provisioned first.
The PWA at https://subhajit-roy-partho.github.io/firebrat/ needs no signing and
uses server conversion only. Original website documentation lives under its
Documentation link.

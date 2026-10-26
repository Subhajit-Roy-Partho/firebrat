# Android offline conversion update — 26 October 2026

The observed Play 1.7.2 crash was an ONNX JNI class lookup failure: R8 removed TensorInfo. The Android release now keeps ai.onnxruntime classes, and CI examines the finished bundle's DEX class definitions before uploading. This observed crash was not an out-of-memory failure from the 99-layer LLM setting.

Kokoro now defaults to two intra-operation CPU threads and one inter-operation thread. Settings offer one, two or four threads. CPU is the default; NNAPI is experimental and shown only when the installed runtime exposes it. Unsupported session creation falls back to CPU. This is not a measured GPU speedup claim. The LLM GPU layer slider does not control Kokoro.

Conversion settings include a separate Kokoro asset download and verification control. Supported Q4_K_M GGUF files may be imported from storage; the importer validates size, metadata, architecture, tensor bounds and completeness before replacing the selected model. Catalog download sizes were corrected.

Novel conversion offers optional local character research using the selected downloaded model, with no cloud fallback. It scans extracted book text and requests quoted evidence. Uncertain traits remain unknown; uncertain speakers use the narrator. The LLM is disposed before speech synthesis. This is conservative casting, not a guarantee that every line in a novel is attributed correctly. Character voice overrides remain available. Standalone titles such as Mr or Colonel no longer become characters when PDF line breaks truncate a speech tag.

Validation: Flutter analysis clean; 106 app tests; 98 backend tests with three existing skips; three added local evidence/casting tests. The initial fixed debug build generated Pride and Prejudice narration without the original fatal error. Full-book completion and an acceleration comparison are not established by these tests.

GitHub's Play bundle workflow now uploads to the Alpha testing track. Its service account has access to Firebrat only, with testing-release and read-only information permissions. The API access preflight succeeded after this permission was granted. Select draft to stage a bundle or completed to submit the testing release for review. This does not release to production.

# TASK — Community library, expressive multi-voice audiobooks, server accounts (handover)

Written 2026-10-26 (America/Phoenix, MST) so ANY agent can resume without the chat history.
The older root `TASK.md` is the original build checklist (PDF -> audiobook). This file covers the 2026-10-26 work stream.
Read, in order: this file -> `AGENTS.md` (environment gotchas + the addendum at its top) -> `backend/firebrat_cast/README.md`,
`SPEC.md`, `INTEGRATION.md`, `INTEGRATION2.md` (the contracts) -> `community/SPEC.md`, `community/README.md`.

## 0. Rules of the road (from the owner; follow them)
- **Git identity:** commit/push only as the default user `Subhajit-Roy-Partho`. Never set `git config user.name/email`, never add
  Claude/Co-Authored-By/"Generated with" lines to commits, PRs or tags. Work happens on branch **`community-library`**
  (pushed to `origin`). **Do not merge to `master`, do not push to `main`/tags, do not publish Docker images** unless the owner says so (the owner asked on 2026-10-27 to merge everything to the default branch `master`, and on 2026-10-28 to push completed work to it; Docker/tags remain off-limits)
  (the Docker CI workflow triggers on pushes to `main` and version tags only; the default branch is `master`).
- **Only Claude agents** do the work. opencode is NOT used any more (its orchestrator hands work to sub-agents that keep running after the
  session ends and collide with other writers). If you find leftover opencode sessions, leave them alone.
- **One writer per file.** Parallel agents get exclusive directories (see section 4). Never edit another agent's area.
- **Personal laptop:** keep heavy compute on the GPU server (`ssh docker`, see 2). Do not run model/GPU/Docker image builds on the Mac.
- **ASU AI-governance policy applies** (organization instructions): only public-domain / non-sensitive text goes through models;
  review outputs before publishing; confirm before any outward-facing action (Internet Archive upload, Firestore writes/rules deploy,
  GitHub Pages publish, merging, Docker Hub). Secrets never go in logs, chat, commits or the server.
- **Confirm before outward-facing/hard-to-reverse actions**; report outcomes faithfully (say when something was not tested).
- Scratchpad (`/private/tmp/claude-501/.../scratchpad`) is volatile: it was wiped by a session restart and files were lost. Keep anything
  durable inside the repo.

## 1. What this work stream is
1. **Firebrat Community** — a static website (`community/`, Vite + vanilla JS + Firebase Auth/Firestore) hosting copyright-free audiobooks.
   Files live on the **Internet Archive**; Firestore holds the listings, ratings, comments, reports, bug reports, copyright takedown notices.
   Integrated into the PWA ("Discover" tab) and the Flutter Android app (Community screen).
2. **Expressive multi-voice audiobook pipeline** (`backend/firebrat_cast/`): LLM casts characters (roster, speaker attribution, emotion),
   Qwen3-TTS gives each character a distinct voice, output is the standard Firebrat package so every client plays it unchanged.
3. **Server integration + accounts (IAM) + device-controlled settings**: new upload mode `content_mode=cast`, scheduler that batches GPU
   phases, admin roles and settings/queue control from the PWA and Android app.
4. **First content**: the top 10 Gutenberg audiobooks converted with the new pipeline and published to the Internet Archive + Firestore.

## 2. Environments and how to operate them
### Mac (this repo)
`/Users/subhajitrouy/Documents/Github/firebrat`, branch `community-library`. Tools present: node/npm, flutter (stable 3.47), python3.11
(pytest works for `backend/firebrat_cast` and most of `backend/tests`; some tests need the serve env: pydub, firebase_admin, pypdf are NOT installed locally
-> 4 known pre-existing failures), docker CLI without a running daemon, gh, Playwright chromium in `~/Library/Caches/ms-playwright`.
macOS filesystem is case-insensitive (`Task.md` == `TASK.md`; do not overwrite the root TASK.md). `find -newermt "-5 minutes"` does not work on macOS; use `-mmin`.
Internet Archive S3 keys are in the owner's `~/.zshrc` as `internetArchiveS3key` / `internetArchiveS3secret` (use `zsh -ic '...'` to load them; never print them).

### GPU server (`ssh docker`)
- SSH alias `docker` (HostName docker-ssh.navraj.me via cloudflared, **login user `roy`**; `subho@docker` is refused). Always `ssh -o BatchMode=yes docker '...'`.
  Never run a foreground command longer than ~100 s: use `tmux new-session -d -s <name> "..."` and poll logs. Do not `pkill -f '<pattern>'` with a pattern that matches your own
  ssh command line (use the `[x]pattern` trick). Connections drop on long foreground commands.
- Hardware: aarch64, NVIDIA RTX 4080 16 GB, 93 GB RAM, driver 580.82 (CUDA 13.0), nvcc 12.6 present (not on PATH). Do not update drivers (ARM servers are unstable).
- GPU quirk: CUDA fails with MPS error 805 unless `CUDA_MPS_PIPE_DIRECTORY=/tmp/firebrat-no-mps` is exported. Always export it (plus `HF_HOME=$HOME/.cache/huggingface`,
  `HF_HUB_OFFLINE=1`, `PYTHONUNBUFFERED=1`). The shell profile sets `HF_HOME` to a non-existent `/scratch/...`; override it.
- The existing Firebrat server lives in `~/Github/firebrat` (branch `codex/play-store` with the owner's UNCOMMITTED changes) — **do not touch it**. Review server public URL
  `https://firebrat-review-server.rohu-hexatonic.ts.net` (uploads need the Play-reviewer Firebrat login; do not use it for bulk work; it must only show the public-domain review shelf).
- Our work dir: `~/community-books/` (src/ EPUBs, out/<slug>/ per-book packages + raw/ + cast cache, jobs/<slug>/state.json+log, code/firebrat_cast = deployed copy of
  `backend/firebrat_cast`, catalog10.json, autorun.sh, benchall.sh, relink_figures.py, logs, bin/ffmpeg symlink).
  Deploy code with `rsync -aq --delete --exclude __pycache__ --exclude tests backend/firebrat_cast docker:community-books/code/`.
- venvs (all under `~/community-books/`): `venv-llm` (torch 2.11+cu128, transformers 5.21, bitsandbytes, flash-linear-attention, pymupdf; for Qwen3.5 in-process / relink),
  `venv-qwen` (torch 2.11, `qwen-tts` 0.1.1 for Qwen3-TTS), `venv-vllm` (vLLM 0.32, torch 2.13+cu132; **must set `VLLM_USE_FLASHINFER_SAMPLER=0`**), plus the repo's
  `~/Github/firebrat/.venvs/{extract,tts,serve}`. Orchestrator python for `firebrat_cast` = `.venvs/extract/bin/python` with
  `PYTHONPATH=$HOME/community-books/code:$HOME/Github/firebrat/backend`.
- Models in the HF cache (all downloaded): `Qwen/Qwen3.5-9B` (LLM+vision, 18 GB bf16), `Qwen/Qwen3.5-4B`, `Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign`, `Qwen/Qwen3-TTS-12Hz-1.7B-Base`,
  Chatterbox (`ResembleAI/chatterbox`), Qwen3-4B-Instruct (the owner's local LLM service model).
- **The owner's local Qwen3-4B service (`llm_server.py`, port 8080) is STOPPED** to free VRAM. Restore with `bash ~/community-books/restart_llm.sh` (reads `llm_env.sh`) once the GPU
  work is done, then tell the owner. It was in tmux `firebrat-llm` window 0 (not restarted).
- Verified facts about the models on this GPU: Qwen3.5-9B **FP8 via transformers corrupts the vision tower** (use bitsandbytes 8-bit with `llm_int8_skip_modules=["visual","lm_head"]`);
  vLLM serving 9B with `--quantization fp8 --max-model-len 8192 --gpu-memory-utilization 0.90 --max-num-seqs 8` (CUDA graphs ON) gives ~152 tok/s aggregate for 8 parallel
  requests vs 2.3 tok/s for in-process bnb8 (hence vLLM for casting). The vLLM vision output is only partly reliable on diagrams (got NAND/NOR wrong for inverters).
  In-process Qwen3.5-9B bf16 (18 GB) does not fit; 27B/35B do not fit.

## 3. DONE (verified unless marked otherwise)
### 3.1 Community website + app/PWA integration (branch `community-library`, pushed)
- `community/`: Vite site. Home (search, category/language/license filters, sort), book page (stars, comments, "How this audio was made" provenance card, download, chapter player,
  report comment/book, bug report, copyright takedown), 4-step submit wizard (route A paste IA URL / route B upload to IA with the user's own S3 keys, local manifest read), favorites, about, legal
  (copyright/terms/privacy/takedown form), admin screen, hash router, mini-player, PWA manifest + service worker, embed mode (`?embed=1`).
  20 helper tests (`npm test`). Design decision (verified): `archive.org/download` has no CORS headers, so the chapter list is read from the submitter's LOCAL manifest and stored in Firestore
  (`chapters`, `packageFile`); audio streams via `<audio src>` from `https://archive.org/download/<id>/<zip>/<inner path>`.
- `firebase/firestore.rules` + `firestore.indexes.json` + `firebase.json`: rules for books/ratings (aggregate verified with getAfter)/comments/reports/bugs/takedowns/admins/favorites. **NOT deployed, NOT run in the emulator.**
- GitHub Pages (branch `gh-pages`, published 2026-10-26): PWA rebuilt with a "Discover" tab (iframe of the site, lazy, same-origin auth) and the site at `/firebrat/community/`.
  Live: https://subhajit-roy-partho.github.io/firebrat/ and /community/ . Until rules are deployed the library shows "You need to sign in" and no books.
- Flutter: `lib/screens/community_screen.dart`, `lib/utils/community_helpers.dart` (+test), entry in `library_screen.dart`; downloads only from `https://archive.org` hosts.
- Takedown counter-notice contact = GitHub issue link (no personal email published).
- PWA header Community link replaced by the Discover tab; `backend/server/static/pwa` rebuilt (generated; do not hand-edit).
- Commits on `community-library` (ahead of `origin/master` by 5): site+rules+app, PWA Discover tab, firebrat_cast+relink+Docker, interface fixes, batching/bounded-chunks.

### 3.2 firebrat_cast pipeline (`backend/firebrat_cast/`, deployed copy on the server; 89+ offline tests pass)
- Modules: `fetch.py` (Gutenberg EPUB -> clean text; also `source_path` for uploads), `segmenter.py`, `llm.py` (LocalHFBackend with `generate_text_batch`, OpenAICompatBackend with 4 threads, `generate_many`),
  `cast.py` (roster pass over 3500-word windows + attribution pass over 600-word/30-quote chunks, per-chunk disk cache, batch size env `FIREBRAT_CAST_BATCH`=8, regex fallbacks,
  `OSError` caught so one bad HTTP reply never kills a book), `compile_cast.py`, `tts_engine.py`/`tts_qwen.py`/`tts_chatterbox.py`, `textnorm.py`, `audio_utils.py`, `synth.py`, `packager.py`,
  `gpu.py` (lock + wait for VRAM, never kills processes), `stage_proc.py` (run cast-wave/synth-wave in its own process/venv), `queue_runner.py` (older wave runner), `scheduler.py` (phase scheduler, see 3.4).
- Lessons baked in: bnb8 skip-visual loading; attribution prompts must stay < ~5k tokens (8k context); FP8 transformers path is broken for Qwen3.5.
- `backend/scripts/relink_figures.py` — relinks orphan figures/tables to sections using real PDF captions (+ optional VLM confirmation; flatten alpha; bnb8 loading).
- `backend/scripts/ia_upload.py` — Internet Archive S3 uploader (keys from env, 0600 header file, refuses to overwrite). Dry run only so far.
- `backend/firebrat_cast/catalogs/community_top10.json` — the approved 10-book catalog.
- Docker: `backend/docker/Dockerfile` has opt-in `WITH_CAST=1` (adds `/opt/venvs/cast-llm`, `/opt/venvs/cast-tts`); `.github/workflows/docker-publish.yml` GPU variant sets it. **Image NEVER built or tested** (no Docker daemon locally; building is CI-only).

### 3.3 Digital Design book repaired (server)
`~/Github/firebrat/backend/output/digital-design-and-computer-architecture`: figures were extracted (597) but only 74 linked. `relink_figures.py --min-px 80 --apply` linked by caption label:
515 sections now have figures (was 76), 184 have tables (was 26), 556/597 figures linked; section 236 (`sec_0248`, "3.2 Latches and Flip-Flops") now carries Figure 3.1 (`fig_0149`).
Backup: `manifest.json.bak`. Phones must delete + re-download the book. Not yet visually checked in the app.

### 3.4 Scheduler (built + tested offline, NOT yet deployed/running)
`firebrat_cast/scheduler.py`: inbox `<root>/inbox/<slug>.json`; CPU prefetch any time; **LLM phase** starts a managed vLLM server, casts ALL waiting books together, stops vLLM and verifies VRAM;
**audio phase** synthesizes the cast books one at a time shortest-first and zips each; books arriving during audio wait until the audio snapshot finishes (owner's rule); retries/isolation; status file `scheduler_status.json`.
CLI: `python -m firebrat_cast.scheduler run|submit|status`.

### 3.5 Server/PWA/Android integration wave 1 (verified on the Mac)
`content_mode=cast` accepted by the server (`jobs.py`, `routes/jobs.py`, `job_runner.py`, `cast_bridge.py`, `routes/settings.py` -> `cast_available`, `main.py` supervisor, `schema.py` additive `cast`),
PWA option (`core.mjs`, `main.js`, `index.html`) and Android option (`api_client.dart`, `conversions_screen.dart`, providers). Tests: backend cast tests pass, PWA 6/6, Flutter analyze clean + 119 tests.
Fixed a launcher/scheduler flag mismatch (`--cast-python`). Not exercised end-to-end against a live server.

### 3.7 Accounts (IAM), admin settings, queue control — wave 2 (built by three Claude agents, verified on the Mac 2026-10-26 ~22:50)
- Backend (`backend/server/iam.py`, `server_settings.py`, `routes/admin.py`, `auth.py` `require_role`, `models.py`, `cast_bridge.py` `build_env()`, `jobs.py` `owner_uid`, `firebrat_cast/catalog.py`, scheduler hot-reload + `priority.json` + cancel flags): everything is OFF unless `FIREBRAT_IAM=1`.
  Setup code printed once to the server log (hash stored, lockout, 410 after an admin exists); `FIREBRAT_ADMIN_EMAILS`; invites claimed on first verified-email sign-in; last-admin protection; audit log; owner scoping
  (with IAM on, pre-IAM jobs/books with empty `owner_uid` are admin-only: deliberate). Tests: `cd backend && python3 -m pytest tests firebrat_cast/tests -q` -> 270 passed, 2 skipped, 4 failed = the known missing-module gaps (pydub, firebase_admin, pypdf).
  "As built" endpoint shapes are at the end of `backend/firebrat_cast/INTEGRATION2.md`. Not enforced: `limits.max_cast_chars`; cancel/priority act between books/stages, they do not interrupt a running stage.
- PWA (`frontend/firebrat_pwa`): `/me`, first-run setup screen, role-aware upload, Settings > Server administration (users, models, run pattern, queue). `npm test` 20/20, `npm run build` ok (output regenerated in `backend/server/static/pwa`). Signed-in flows only unit-tested; hand-off: `docs/handover/pwa.md`.
- Android (`frontend/firebrat_app`): same features, one merged implementation (`lib/models/server_admin.dart`, `lib/screens/server_admin_screen.dart`, `server_setup_screen.dart`, `state/server_admin_providers.dart`, `api_client.dart`). `flutter analyze` clean, `flutter test` 138/138. Hand-off: `docs/handover/android.md`.
- Backend hand-off: `docs/handover/backend.md`. NOTHING here has run against a live server, live Firebase tokens, the scheduler process or a device.
- Decisions applied: quiet hours = window with NO new GPU phase; settings file `<data>/server_settings.json` exported to the scheduler as `FIREBRAT_SETTINGS_FILE`; defaults `max_books_per_llm_phase`=4, `shortest_first`, `batched`.

### 3.8 Phone debugging + Focus-mode fix (2026-10-26, Pixel 9a, adb over USB)
- Bug: Focus ("zoomed in") mode showed no picture for figures/tables linked at section level (relinked by caption) because it only followed the narrated segment's ref. Fix in `lib/state/reader_providers.dart`
  (`ReaderState.currentVisual` falls back to the section's first linked figure/table) + `lib/widgets/figure_gallery.dart` (thumbnails `BoxFit.contain` on white). Test: `test/focus_fallback_test.dart`. Verified on the device with a 31-section cut of the Digital Design book. Commit `7150aee`.
- How the on-device debug build was done (no data loss): clean `git worktree` of HEAD; copy the owner's gitignored `android/app/google-services.json` and untracked `pubspec_overrides.yaml` into it; add `applicationIdSuffix = ".debug"` to the debug buildType and a duplicate client entry
  with package `com.firebrat.firebrat_app.debug` in that worktree's google-services.json (local only, never committed); `flutter build apk --debug --target-platform android-arm64`; `adb install -r` (side by side with the signed release app).
  A small test package (manifest sections 232-262 + their audio/figures zip, built on the server) was pushed to `/sdcard/Download` and imported via the app's import button. The full book download from the review server is ~0.7 MB/s (1.2 GB = ~30 min).
- The `.debug` app is still installed on the phone; the screen timeout was set to 30 minutes by the owner. Owner's real app is untouched. The Android phone ID: `adb devices` shows `55201JEBF00569` (Pixel 9a, Android 17, ~7.7 GB RAM).

### 3.9 On-device models, accelerators and download network (Flutter agent, tests only, NOT yet tried on a device)
- `mobile-Backend/`: LLM catalog now 13 models with tiers (Light/Balanced/Powerful/Desktop-class), min RAM, licence, SHA-256 (added Llama 3.2 1B, Qwen3 8B, Llama 3.1 8B, Gemma 3 12B, Qwen3 14B; Qwen3.5 left out: llama.cpp support unconfirmed); Kokoro int8 (default)/fp16/fp32 + 5 extra voices; `device_capabilities.dart`, `accelerator.dart`
  (Auto / GPU-NPU (NNAPI -> XNNPACK -> CPU) / CPU with automatic CPU fallback and "Running on" status), `network/network_gate.dart` (Wi-Fi only / Wi-Fi+cellular default / ask on cellular > 50 MB; waiting-for-Wi-Fi + auto-resume).
- Kokoro on GPU: NOT achievable with the current plugin (`flutter_onnxruntime` bundles no QNN; NNAPI does not handle dynamic shapes, expect little/no gain); `sherpa_onnx` not added (own libonnxruntime.so would clash). Honest result in the hand-off.
- App: settings UI (`kokoro_model_controls.dart`, `model_choice_widgets.dart`), `app_network_gate.dart`, `device_probe.dart`, `connectivity_plus` dependency. `flutter analyze` clean, `flutter test` 146 pass; mobile-Backend 142 pass (3 skipped). Hand-off: `docs/handover/flutter-models.md`.
- Risks: no device benchmark for NNAPI/fp16/fp32; RAM figures are estimates; `connectivity_plus` cannot see the metered flag; espeak-ng (inside the Kokoro package) is GPL-3.0 and Llama/Gemma have non-permissive licences: review before a store release.

### 3.6 opencode bridge
`~/.claude/mcp/opencode-bridge/server.mjs` (MCP: opencode_start/status/result/cancel/list; plain `worker` agent, private instance) pushed to `Subhajit-Roy-Partho/opencode-config` branch `claude` (`claude-bridge/`). Superseded by "Claude agents only".

## 4. IN PROGRESS right now (as of 2026-10-26 ~22:35 MST)
### 4.1 Server: audiobook run (tmux on `docker`)
- `cb-vllm`: vLLM serving Qwen3.5-9B FP8 on port 8100 (served name `qwen3.5-9b`). `cb-auto`: `~/community-books/autorun.sh` casts all 10 books through it, then kills vLLM, then synthesizes
  each book with Qwen3-TTS (`stage_proc synth-wave`, venv-qwen) and zips it. Log: `~/community-books/autorun.log`; per-book `jobs/<slug>/log.txt`.
- Cast results so far: Alice, Dorian Gray, Frankenstein, Anne of Green Gables done (4/10); remaining: Sherlock Holmes, Pride and Prejudice, Dracula, Jane Eyre, Little Women, Crime and Punishment.
  Measured: Alice 26.7k words in 3m17s; Frankenstein 84k words in 3m37s.
- **The Qwen3-TTS synthesis code has NEVER run on the real model.** It may fail on first use (read `autorun.log`). The first synthesized book defines the real speed (estimate 1-3 h for a 3-hour book, unverified).
- Order in autorun: all casts first, then audio. The scheduler (3.4) is the better design but is not deployed; switching later is safe because casts/synths resume from disk.

### 4.2 Wave-2 review (all three agents finished; code committed to `community-library`)
The remaining step is a security review of `backend/server/iam.py` / `auth.py` / `routes/admin.py` (setup-code handling, role enforcement, invite claim, owner scoping) and a signed-in end-to-end check against a live backend with `FIREBRAT_IAM=1` (not done). Findings from a review go in a follow-up commit.

## 5. TO DO (detailed, in priority order)
1. **Finish the 10 books (owner priority).** Watch `autorun.log`. After casting: verify the first TTS output by LISTENING to a sample (distinct voices per character, emotion, no clipped sentences, natural pauses) before spending hours on all books. Tune
   `tts_qwen.py` anchors/instructions (VoiceDesign anchor + Base clone vs per-line design; A/B documented in its docstring) if it sounds off. Expected zips: `~/community-books/out/<slug>.zip` + `built.json`. Fix bugs in `backend/firebrat_cast` on the Mac, rsync, rerun (resumable).
2. **Restore the owner's local LLM service** after GPU work: `bash ~/community-books/restart_llm.sh` in tmux `firebrat-llm`; verify `curl localhost:8080/v1/models`; tell the owner.
3. **Publish the books** (ask the owner first; it is public): from the Mac copy each zip (`scp docker:community-books/out/<slug>.zip .`), `zsh -ic 'python3 backend/scripts/ia_upload.py backend/firebrat_cast/catalogs/community_top10.json <slug> <zip>'`; confirm
   the item at `https://archive.org/details/<slug>` and that `https://archive.org/download/<slug>/<slug>.zip/manifest.json` resolves. Then create the Firestore `books/<slug>` documents (fields per `community/SPEC.md`; `provenance.attested=true`, `license=public-domain`, narration engine `qwen3-tts`, models
   `Qwen3.5-9B` (casting) and `Qwen3-TTS-12Hz-1.7B`; `chapters` from the manifest sections; `submitterUid` = the owner's uid). Needs the owner's `! npx firebase-tools login` first.
4. **Deploy Firestore** (ask first): `firebase deploy --only firestore:rules,firestore:indexes --project firebrat-8c597`; create `admins/<owner uid>`; run the rules in the Firestore emulator (never done); verify rating aggregate rule, comment counter rule, takedown without auth.
5. **Security review + live check of wave 2** (section 4.2): review IAM code, then try it for real on a scratch server instance with `FIREBRAT_IAM=1` (bootstrap, invite, role enforcement, upload as viewer/user, admin settings/queue from the PWA and app). Re-run `cd backend && python3 -m pytest tests firebrat_cast/tests -q`, `cd frontend/firebrat_pwa && npm test && npm run build`, `cd frontend/firebrat_app && flutter analyze && flutter test` after any fix.
6. **Deploy scheduler + integration to the server** only with the owner's approval (the owner's server checkout has uncommitted work and Play reviewers use it): needs `FIREBRAT_CAST_ENABLED=1`, `FIREBRAT_CAST_ROOT`, `FIREBRAT_CAST_LLM_PY`, `FIREBRAT_CAST_TTS_PY`, `FIREBRAT_CAST_VLLM_BIN`, optionally `FIREBRAT_IAM=1` (+ `FIREBRAT_ADMIN_EMAILS`); then smoke-test an EPUB upload with `content_mode=cast` from the PWA and the app.
7. **Figure linking in the main pipeline** so new books do not need `relink_figures.py` (compile stage should attach figures by PDF captions); also re-run the vision confirmation on the Digital Design book for a spot-check and look at a few sections in the app.
8. **Community site hardening**: Firestore emulator tests; rate limiting is impossible without Functions (document); name a DMCA agent if operating in the US; real IA upload from the submit page (route B) is untested; consider an IA-item existence checker and auto-flagging after N reports.
9. **Docker**: validate the `WITH_CAST` Dockerfile in CI on a branch/workflow_dispatch (NOT on `main` without the owner's OK); the GPU image grows by several GB; vLLM wheels need CUDA 13.0/12.9 on the host driver.
10. **Merge**: when the books are done and the owner agrees, open a PR `community-library` -> `master` (clean merge verified), or merge as instructed. Merging does not publish Docker (workflow watches `main`).
11. **Phone test of 3.9** (ask the owner first): install a debug build as in 3.8, benchmark Kokoro CPU vs GPU/NPU and int8 vs fp16 on the Pixel 9a, try the Wi-Fi-only rule (turn Wi-Fi off), larger LLMs, and the Community screen.
12. **Later**: deep links `firebrat://community/book/<id>` in the Android manifest; second wave of books (Count of Monte Cristo, Brothers Karamazov, Hound of the Baskervilles); batching `generate` calls in-process is implemented but vLLM is preferred.

## 6. Known issues / gotchas
- Four backend tests fail on the Mac only because pydub/firebase_admin/pypdf are not installed (pre-existing).
- `backend/jobs.sqlite3` and `.pytest_cache` are gitignored artifacts of test runs.
- Untracked files that belong to the owner (leave alone): `assets/tutorial-video/youtube-metadata.md`, `docs/DEVELOPMENT.md`, `frontend/firebrat_app/pubspec_overrides.yaml`.
- `firebase_options.dart`/`community/src/firebase-config.js` contain the public Firebase web config (not secrets).
- vLLM first start needs `--gpu-memory-utilization <= 0.90` (only ~14.1 of 15.6 GiB is free) and `VLLM_USE_FLASHINFER_SAMPLER=0`; FlashInfer otherwise JIT-links a CUDA 12 lib that does not exist.
- The first Chatterbox pilot (Yellow Wallpaper) was abandoned; do not publish old-pipeline audio.
- The owner's opinion on speed: they dislike polling and want unattended runs; use tmux + log files and report concisely.

## 7. Handover files from agents
Each agent writes `docs/handover/<area>.md` when it finishes (what was done, what is left, test results, gotchas). The lead merges the essentials back into this file.

## 8. STATUS UPDATE 2026-10-27 (supersedes sections 4 and 5 where they differ)
- **Audio stage works** (Qwen3-TTS, per-character voices, batched; ~5-10x real time). Details, measurements and commands: `docs/handover/synth-debug.md`.
- **Bug found and fixed after the first builds:** `textnorm` expanded title abbreviations as prefixes ("Stop" -> "Saintop", "Revived" -> "Reverendived"). 2,297/2,496 sections were affected, so every finished book was rebuilt (fix `bd8efbd`; old zips quarantined in `~/community-books/old-bad-textnorm/`, never upload them). Books Alice/Frankenstein/Dorian/Anne/Sherlock were rebuilt first; Pride and Prejudice, Dracula, Jane Eyre, Little Women, Crime and Punishment follow (two tmux workers `cb-synth`, `cb-synth2`; check `~/community-books/autorun-synth.log`).
- **Community site:** Firestore rules now have emulator tests (`cd community && npm run test:rules`, 5 pass). NOT yet done and needing the owner's login/consent: `firebase login`, rules/indexes deploy, `admins/<uid>`, Internet Archive upload of the rebuilt zips (keys `internetArchiveS3key/secret` are set in the Mac's `~/.zshrc`), Firestore `books/*` documents, real DMCA address in `community/src/views/legal.js`.
- **Android on-device expressive mode:** wired and unit-tested; phone runs show Qwen3-4B on CPU is far too slow (~0.5 tok/s); GPU offload and a release build were never tried. See `docs/handover/android-expressive-gpu.md`.
- **Git:** `community-library` merged to `master` on 2026-10-27 at the owner's request (see git log).

## 9. STATUS UPDATE 2026-10-28 (supersedes section 8 where they differ; maintained live — update the checkboxes as work lands)

### 9.1 Done
- [x] **Git state:** `master` == `origin/master`; `community-library` is merged (47d656d); `release/1.7.2` has nothing `master` lacks. `flutter-mac` still has 3 commits `master` lacks (Android heap-OOM fix, unsigned-IPA CI job, v2 icons): not merged, owner has not asked.
- [x] **CI repair** (`7218a41`): backend tests failed in CI because `firebase-admin` was missing from the CI pip line and `backend/env/serve-environment.yml`. Added to both. (That commit carries a Claude `Co-Authored-By` trailer; the owner said on 2026-10-28 to leave it.)
- [x] **iOS:** release build (`flutter build ios --release --no-codesign`) works. Simulator failed because ML Kit (`google_mlkit_text_recognition`, used only by the Android-only OCR fallback) has no arm64 simulator slice; and Firebase crashed at launch on iOS (Android-only `firebase_options.dart`). `lib/main.dart` now initialises Firebase only on Android. Simulator-only workaround: an untracked `pubspec_overrides.yaml` stubbing ML Kit (deleted again; do not commit one).
- [x] **Android startup bug** (`181ed3a`): `audio_handler` crashed at launch with "cannot add items while items are being added from addStream"; replaced `pipe()` with plain listeners. Verified on the Pixel 9a.
- [x] **Firestore deployed** to `firebrat-8c597`: rules + indexes live; `admins/4A0W465aufgeoTlzBbIRyWuafBU2` (the owner's Firebase uid) created. `subhajit-roy-partho.github.io` is an authorised Auth domain.
- [x] **Community ledger:** `users/{uid}/uploads/{bookId}` (user -> book -> Internet Archive link) with rules + emulator test (`1816f54`).
- [x] **Server QA of all 10 rebuilt books** (`qa_targeted.py` + `qa_package.py`, faster-whisper): WER 0.000-0.039. Three "bitrate 93-95 kb/s" flags (Crime and Punishment sec_0242, Sherlock sec_0012, Dorian sec_0246) are low VBR readings on speech, not defects. All 10 are cleared for upload.
- [x] **Internet Archive identifiers:** bare slugs `dracula-stoker` and `jane-eyre-bronte` already belong to other uploaders, so every item uses the `firebrat-<slug>` prefix (`ia_upload.py`, `5c9c3bf`). Stored as `archiveId` in Firestore.
- [x] **Licensing decision (owner, 2026-10-28): generated audio + packages are CC BY 4.0**; the source texts are public domain. Applied in `ia_upload.py` (item `licenseurl` + description), `community/scripts/seed_launch_books.py` (`license: cc-by`) and the declaration page (`7443b13`).
- [x] **Legal declaration page** `#/legal/declaration` (footer "Legal declaration"): sources table, per-country caveat, AI-voice disclosure, CC BY licence, Internet Archive role, privacy, takedown process, no-warranty, honest statement that **no DMCA agent is designated**. Not legal advice; has not had a lawyer's review. Cover images come from each Gutenberg EPUB; their rights status is not independently verified.
- [x] **Seeding tool** `community/scripts/{chapters.mjs,seed_launch_books.py}`: writes `books/<slug>` + the upload ledger using the site's own `buildChapters`/`validateChapters`; checks the IA item and byte size first; will not overwrite an existing book.
- [x] **Takedown contact:** no personal email is published (in-site form + GitHub-issue counter-notice). The old "REPLACE-ME" placeholder is gone; `community/README.md` step 3 updated.
- [x] **Phone:** debug build installed as `com.firebrat.firebrat_app.debug` (same recipe as 3.8, temp gradle/google-services edits reverted); launches with no errors, empty library + Community entry visible.

### 9.2 Done later on 2026-10-28 (verified)
- [x] **CI green** on `639d312`: backend (193 tests), Flutter analyze + tests, pipeline smoke, debug APK. Cause of the red runs: `test_zip_upload_merges_pdfs` assumed uploads are stored as `<book_id>.pdf` (they are `<job_id>.pdf` since `5c62922`), `test_upload_model_override_echoed` raced a background job at temp-dir teardown, and `_wait_for` was a hard 5 s. Play Store workflow failures (Oct 26) are the Play Console service-account permission error, not code.
- [x] **Site published** to `gh-pages:/community/` (`24b7d0e`): https://subhajit-roy-partho.github.io/firebrat/community/ ; anonymous reads of published books work from the Pages origin; chapter-list button styling fixed (`463b782`).
- [x] **Uploaded to the Internet Archive as `firebrat-<slug>` (CC BY 4.0, sizes verified):** Alice, Frankenstein, Anne of Green Gables, Dracula, Jane Eyre, Crime and Punishment.
- [x] **Seeded to Firestore** (`books/<slug>` + `users/<uid>/uploads/<slug>`) for those six: library lists them on the site and in the app.
- [x] **Phone (Pixel 9a, `.debug` build) verified:** launches clean (no FATAL/Exception/ANR in logcat); Community screen lists the six books (no more `permission-denied`); detail sheet shows provenance + CC-BY licence + licence URL; "Add to my library" downloaded Alice (125 MB) from the Archive and imported it (93 sections, 2h 38m, cover shown); reader plays it (00:07/01:42, text highlight in sync, active speech `AudioTrack`). NOT tested: sign-in (needs the owner's credentials), importing a local file, the other books' playback, long-run background playback / lock-screen controls.
- [x] **Test sweep:** `flutter analyze` clean; `flutter test` 146 pass (app) and 192 pass (mobile-Backend); backend pytest 193 pass + `firebrat_cast` 138 pass; community 20 + PWA 20 pass; Firestore rules emulator 6/6 (`npx -y firebase-tools@13 emulators:exec --config ../firebase.json --only firestore --project demo-firebrat-rules "node --test test/rules.test.mjs"`; `npm run test:rules` needs a global `firebase` CLI).

### 9.3 Superseded: batch 2 finished (all 10 books uploaded to the Archive as `firebrat-<slug>` and seeded). Original note:
- [x] **Uploads, batch 2** (Mac, `ia_upload.py`, one at a time): Little Women, Pride and Prejudice, Sherlock Holmes, Dorian Gray. Then seed them: `python3 community/scripts/seed_launch_books.py <catalog10.json> <zips dir> 4A0W465aufgeoTlzBbIRyWuafBU2 <slugs...>`.

### 9.4 To do
1. [ ] Confirm batch 2 on archive.org, seed the four books, re-check the site and the app list (10 books).
2. [ ] Phone: sign-in on the debug build and the remaining untested items above (owner's credentials needed for sign-in).
3. [ ] Optional, owner's call: merge `flutter-mac` into `master`; designate a DMCA agent; lawyer review of the declaration; Firebase iOS app (`GoogleService-Info.plist`) for iOS sign-in/push/Firestore; restore the Qwen3-4B service on the server (`bash ~/community-books/restart_llm.sh`) if still stopped.
4. [ ] Carried over from section 5: security review + live check of wave-2 IAM (5), scheduler deployment (6), figure linking in the main pipeline (7), Docker `WITH_CAST` validation in CI (9), on-device GPU/NPU benchmarks (11), deep links (12).

### 9.5 Gotchas learned 2026-10-28
- IA S3 `PUT` returns only after the Archive finishes processing: curl can sit at 0% CPU for minutes after the last byte is sent. Check bytes sent (`nettop -P -p <pid>`), not the log.
- Never use `pgrep -f '<pattern>'` inside a shell whose own command line contains `<pattern>`: it matches itself and waits forever (this stalled the batch-2 upload chain for ~75 min).
- Another Claude session's background jobs (QA loop on the server, rsync to this Mac) survive after that session ends; check `ps` before starting duplicates.
- Session transcripts live in both `~/.claude/projects/...` and `~/.claude-personal/projects/...`.
- BSD `sed -i` and `\n` in replacements do not work on macOS; use Python for multi-line edits.

### 9.6 Release 1.8.0 (2026-10-28, owner-requested)
- [x] **Features (`431e1cc`, site on gh-pages `d755ff3`):** duplicate uploads of one book are grouped under one banner (title minus subtitle/article + author surname, `community/src/works.js` and `lib/utils/work_grouping.dart`; best-rated first; shows submitter and stars); sorts Highest rated (default) / Newest / Most ratings / Longest / Title; Author and Uploader filters; real covers (`cover.jpg`, falling back to `cover.png`, then a gradient); book page lists other versions + more by the author + Share. **App Community screen** (`community_service.dart`, `widgets/community_detail_sheet.dart`): Google sign-in prompt, 1-5 star rating, public reviews (post/delete own/report), bookmark + "Saved" filter, copy link. Phone-verified (Pixel 9a): list, covers incl. PNG fallback, filters, sheet, sign-in prompt and Google account chooser. NOT verified: signed-in rate/review/bookmark (needs the owner to pick the account).
- [x] **Version 1.8.0+33** (`e31f3e0`), Play notes in `frontend/firebrat_app/distribution/whatsnew/whatsnew-en-US`. CI green before tagging.
- [x] **Tag `v1.8.0`** -> run 40749218561: GitHub Release with APK, AAB, unsigned iOS IPA and server installers.
- [x] **Play Console:** `flutter-release.yml` dispatched with `appbundle` + `completed` -> run 40749250281: service-account access check OK (the old "caller does not have permission" error is gone) and the upload to the Alpha track succeeded. What happens next is Google's review in Play Console (not visible from here).
- [ ] **Open:** owner's decision on "share books through Drive from the personal library" (needs a definition: share link for others to import, publish to Community with Drive as the host, or other); sleep timer and position bookmarks (not in app or web); owner to try signed-in rating/reviews/bookmarks on the phone.

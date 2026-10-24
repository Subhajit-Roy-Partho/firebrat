# Review server verification — 2026-10-23

## Deployment

The authorized SSH target is `docker`, not `ringtail`. The server checkout is
`/home/roy/Github/firebrat`, on `codex/play-store`. This is an ARM64 Ubuntu 24.04
container with an NVIDIA RTX 4080 (16 GB), driver 580.82.09, and Python 3.12.
No paid API, hosting, or billing was enabled.

Three isolated environments are used: `.venvs/serve`, `.venvs/extract`, and
`.venvs/tts`. GPU wheels are PyTorch 2.9.1/cu128; extraction uses torchvision
0.24.1, speech uses torchaudio 2.9.1. ARM64 wheels for the originally pinned
PyTorch version were unavailable. Dependencies were installed with an explicit
local override; this is a tested deployment variant, not a change to every
installer's dependency pins. Marker remains 1.9.3; Chatterbox remains 0.1.7,
transformers 5.2.0 in the speech environment, and setuptools <81.

The inherited shared NVIDIA MPS socket failed with CUDA error 805. Setting
`CUDA_MPS_PIPE_DIRECTORY=/tmp/firebrat-no-mps` for Firebrat allows a direct GPU
connection without stopping or altering other users' workloads. A real CUDA
tensor operation passed, and both the language and speech models loaded on GPU.

Runtime environment settings are in `runtime/server.env` (not versioned), logs
in `logs/`, and services run in named tmux sessions. The API binds to loopback
port 8000; Qwen binds to loopback port 8080. These tmux sessions survive SSH
disconnects, but do not establish reboot/startup supervision. Tailscale Funnel now supplies the stable HTTPS hostname documented below.
Persistent service supervision is still required after a host reboot for reviewer
availability. Do not treat an SSH tunnel or a temporary tunnel as permanent
hosting.

Qwen/Qwen3-4B-Instruct-2507 runs locally in FP16 with an 8192-token context.
Server defaults select the local provider with one page per compilation chunk.
Speech is generated locally with Chatterbox and the existing narrator reference.
The first run downloads open model weights; later conversion does not need an
LLM API. Authentication still contacts Firebase/Google and is not an offline
server feature.

## Access

A dedicated Firebase email/password reviewer account was created and fresh
sign-in verified. Its password is stored only in the ignored, permission-limited
`secrets/play-reviewer.json` on the development Mac. Never commit this file or
publish credentials in release notes. Authenticated `/jobs` returned HTTP 200;
`/health` returned HTTP 200.

Set `GOOGLE_CLOUD_PROJECT=firebrat-8c597` (or `FIREBASE_PROJECT_ID`) for keyless
Firebase token verification. Google signing keys, audience, expiry, issued-at,
issuer, subject, and authentication time are validated. No service-account key
is needed for this path. Push sending still requires separate credentials;
polled conversion status remains available without them.

The deployed `FIREBRAT_ALLOWED_USER_IDS` restricts mutations to the dedicated
reviewer UID. Add explicitly authorized owner UIDs as a comma-separated list
when required. An empty setting preserves the existing shared-server policy.
Reads remain public by design: expose only the public-domain review shelf.
Do not upload private books to a publicly reachable instance of this deployment.

## Illustrated fixture and findings

The same three-page input is prepared for server and Android testing:
`peter-rabbit-review.pdf`, the opening three story pages of Beatrix Potter's
*The Tale of Peter Rabbit* (1902), with original illustrations.

- Original text and illustrations: https://www.gutenberg.org/ebooks/14838
- PDF edition: https://mlw.media.mit.edu/assets/TheTaleofPeterRabbit.pdf
- Full original PDF, excerpt, attribution, preview, and local test evidence:
  ignored `tmp/review-readiness/`.

Extraction found all three pages, readable text on every page, and three
illustrations. Cold extraction including initial model loading/downloading took
about 187 seconds. Qwen compilation took 38.9 seconds, produced three sections,
and flagged no failed/review chunks. Manual comparison found the narrative
facts retained, although dialogue was paraphrased; this is not proof of
word-for-word fidelity.

The initial model output omitted every figure reference despite extracting the
images. The compiler now anchors an omitted illustration to existing prose only
when a section covers exactly one page with exactly one figure and no explicit
visual reference. It preserves spoken text and does not guess across multiple
pages/figures. More complex layouts still require explicit model alignment and
must be checked on their own fixtures. Cached speech metadata is refreshed when
visual references change, preserving valid audio and timestamps.

Other real deployment failures fixed during the test:

1. Symlinked Python executables in separate virtual environments were resolved
   to the same base interpreter, incorrectly blocking the speech handoff.
2. Firebase Admin SDK token verification attempted to load absent application
   credentials, rejecting a valid reviewer login. Explicit keyless verification
   now uses Google's public signing keys with Firebase claim checks.

Targeted authentication, illustration alignment, and package consistency checks:
**16 passed**. Speech completion, exported package verification, Android local
conversion, and actual playback/picture checks must be recorded below before
claiming end-to-end review readiness.

## Completed server round trip

The authenticated reviewer uploaded the same three-page PDF through
`POST /books/upload`, rather than invoking the converter directly. Job
`0b25fdc0a9f5404c` completed from 18:33:30 to 18:35:30 UTC, with local provider,
one-page chunks, illustrated mode, no error, and zero review flags. Its final
book ID is `peter-rabbit-review-2`; the duplicate initial CLI fixture was moved
out of the served output directory. The result has three sections, three
figures, and 27.84 seconds of narration (speech sampling varies between runs).
The first run's package was also decoded structurally: all assets existed,
all three sections referenced their correct page figure, and every segment
range was positive and within its section duration. Visual inspection confirmed
the first extracted illustration matches the source rabbits-under-tree image.

The full lightweight backend suite passed **57 tests**; the subsequent optional
push-credential handling change passed **11 authentication tests**. Missing
push credentials now return a clean no-op before attempting to send.

## Android follow-up (23 October 2026)

The owner reconnected and unlocked the Pixel 9a. Its original 1.2 GB textbook
was preserved. Real-device checks passed for the three library layouts,
source-PDF opening/slider navigation, a single reader drawer button,
section autoplay and the correct changing original-page illustration.
Kokoro produced non-silent narration on the device; a subjective listening
assessment is not inferred from audio metrics.

The first fully offline sample run took approximately 6m31s. A fixed-extraction
fresh run took 5m16s, but source comparison exposed a changed pronoun and a
summary. Version 1.6.3's ordinary-prose fidelity guard corrected those pages
using source text. A cached replay recorded fallback pages [1, 2] (zero-based),
three sections, three correct picture references and 35.64 seconds of 24 kHz
Kokoro audio. RMS values were 2734/2906/2630 with zero clipped samples. The replay
ran with connectivity restored by the owner, so it is not labeled a new
network-disabled or fresh-inference benchmark. Initial offline verification
remains separate evidence.

End-of-book reader controls return to Play and replay works. An additional
system-notification state discrepancy was fixed and requires final physical
verification. Analyzer and 37 frontend tests passed; 51 mobile-backend tests
passed. The signed release workflow is run 40044478806. Device installation
preserves application data. Final Play-signed Google login, on-phone server
round trip and foreground-service demonstrations remain checklist items until
explicitly verified; do not equate passing unit tests with those live checks.

## Public HTTPS through Tailscale Funnel

Live URL (verified 2026-10-23):
https://firebrat-review-server.rohu-hexatonic.ts.net

The owner authenticated the dedicated `firebrat-review-server` Tailscale node.
Official ARM64 Tailscale 1.104.2 was installed under `runtime/tailscale/` after
verifying the vendor SHA-256 checksum. It runs without root and without changing
host networking, using userspace networking in tmux session `firebrat-tailscale`.
State, certificates, and node keys are local runtime data, never Git content.
The runtime directory is permission-limited; do not delete its state to redeploy
application code, because that would discard the authenticated node identity.

Daemon launch (from the server checkout):

```sh
runtime/tailscale/tailscaled --tun=userspace-networking \
  --statedir=/home/roy/Github/firebrat/runtime/tailscale/data \
  --state=/home/roy/Github/firebrat/runtime/tailscale/state \
  --socket=/home/roy/Github/firebrat/runtime/tailscale/tailscaled.sock
```

Funnel configuration:

```sh
runtime/tailscale/tailscale --socket=runtime/tailscale/tailscaled.sock funnel --bg 8000
runtime/tailscale/tailscale --socket=runtime/tailscale/tailscaled.sock funnel status
# Disable only this public HTTPS proxy:
runtime/tailscale/tailscale --socket=runtime/tailscale/tailscaled.sock funnel --https=443 off
```

An explicit `--statedir` is necessary: without it the isolated daemon could not
store/request its HTTPS certificate (`no TailscaleVarRoot`). With it, certificate
issuance succeeded and Funnel configuration survived the daemon restart.
The background Funnel configuration persists, but the daemon, API, and model
still need to be started after a host/container reboot. The current tmux setup
survives SSH disconnects, not a full reboot. Keep all three services available
throughout Google review.

Verification over HTTPS: `/health` and the public sample `/books` returned 200;
`/jobs` returned 401 anonymously and 200 with the dedicated reviewer Firebase
token. A direct request to a public Funnel relay IP with the correct hostname
and TLS verification also returned 200, avoiding reliance on the Mac's private
Tailscale DNS route. The service does not require reviewers to install Tailscale.
Only the public-domain sample shelf is exposed. Existing authenticated mutation
restrictions remain in place. No paid hosting or billing was enabled.

## Play release handoff (23 October 2026, 17:52 Arizona)

Internal release **1.6.3+26** is published and shown as available to internal
testers (not reviewed). Signed workflow 40044478806 succeeded, and all 28
64-bit libraries in the AAB passed the native-alignment checker. No public
production rollout occurred. Existing internal tester enrollment is unchanged.

Data safety is saved; App content now shows only the foreground-service
permission declaration outstanding. That form requires public demonstration
video URLs for DATA_SYNC (network downloads and local conversion) and
MEDIA_PLAYBACK. Do not substitute an unrelated URL or claim it is complete.
A private raw playback recording includes the owner's home wallpaper and is
**not approved for public release**; make a clean demonstration or redact it
before publishing any review evidence. The phone locked after installation of
the final notification correction; final verification and the demonstration
are waiting for unlock. The original stay-awake value 0 was restored, and
Wi-Fi/mobile data were confirmed enabled with airplane mode off.

Play's app-signing SHA-1 is
`4C:7F:E7:C0:B5:53:D0:8E:49:A7:4B:AD:D8:34:A9:2D:85:23:53:DE`.
Registration in Firebase is pending the specific owner approval requested in
chat. This differs from the already registered debug certificate. Preserve the
reviewer account and the owner's library; never uninstall or clear app data to
switch signing channels without a verified backup and explicit user direction.

# Firebrat Server — guided desktop setup

Native installers manage three isolated Python 3.11 environments in your user
folder. No Docker, administrator account or system Python is required. The
launcher opens a private setup page in your usual browser. **Language-model APIs
are optional; speech is always synthesized on this computer with Chatterbox.**

## Install and convert

1. Download the installer matching your computer from the GitHub release.
   macOS: open the DMG and drag **FirebratServer.app** to Applications. Linux:
   `chmod +x Firebrat-Server-*.run`, then run that file as your normal user.
   Linux builds target x86-64, Ubuntu 22.04 or newer / compatible glibc systems.
2. Open Firebrat Server. Choose a local Ollama model or your own
   OpenAI-compatible LLM API base URL, exact model ID and API key. Save setup.
   For local LLMs, install [native Ollama](https://ollama.com/download) first.
3. Click **Install dependencies**, then **Start server**. Initial setup and model
   downloads need internet and substantial disk space (allow 20–40 GB). The
   first conversion downloads the PDF extraction and Chatterbox voice weights.
   Keep internet available until that first conversion completes.
4. Choose a PDF and **Illustrated** or **Novel**, then Convert. The local setup
   page does not require a Firebase account. It sends the selected PDF only to
   this computer. Local mode sends compilation requests to loopback Ollama;
   API mode sends extracted book text to the provider you configured. No speech
   or voice reference audio is sent to an API.
5. Open the library link, or connect your phone as described below. Refresh its
   library when conversion finishes, then download the book for offline playback.

Desktop and authenticated phone uploads share the existing server job queue,
which runs one conversion at a time. A per-launch secret protects the desktop
bridge; it is disabled in ordinary server starts. Local Ollama models get a
`firebrat-...` alias with a 16K context for the two-page pipeline chunks.
The wizard handles one submitted desktop conversion at a time. Keep the launcher and computer
running; closing the browser tab does not stop the server. Stop/Quit terminates
only processes started by this launcher and keeps books, settings and models.
Reopening the app returns to the existing setup page. The launcher does not
install a system daemon or start automatically on login.

macOS downloads are **unsigned/not notarized**: the current project has no
Developer ID distribution certificate. Do not disable Gatekeeper for them.
A signed/notarized public distribution remains future release work; building
from the published source is another option. No Apple membership purchase is
performed by this installer.

## GPU support and model starting points

Native Ollama uses supported NVIDIA/AMD GPUs on Linux and Metal on Apple
silicon. This installer leaves that selection to Ollama. Speech uses CUDA when
available in the installed PyTorch build, otherwise CPU. CPU-only mode installs
CPU PyTorch wheels on Linux. AMD/ROCm speech and Mac MPS speech are not claimed;
those use local CPU synthesis. CUDA requires a driver compatible with the
installed PyTorch wheels. If GPU initialization fails, choose CPU-only setup.
CPU and automatic profiles have separate environments, so switching does not
silently reuse an incompatible PyTorch installation.

These are conservative **starting estimates**, not PC benchmark guarantees.
Quantized model download size is not peak RAM/VRAM: leave room for context,
extraction, the operating system and local voice generation. Try 2–3 pages first.
Smaller models can omit facts; review the output, especially equations/figures.

| Computer | Start with | Notes |
|---|---|---|
| 8 GB RAM / CPU-only laptop | LLM API, with local CPU voice; optionally Qwen3 1.7B | Local extraction and speech can still be slow; keep other heavy apps closed |
| 16 GB Apple silicon | `qwen3:4b-instruct`, or 1.7B for less memory | Native Ollama can use Metal; voice stays on CPU |
| 32 GB Apple silicon | `qwen3:8b`; test 14B if enough free memory | Prefer smaller chunks over exhausting unified memory |
| NVIDIA 6 GB VRAM | `qwen3:1.7b`, CPU voice if memory is tight | Reserve memory for TTS and context |
| NVIDIA 8–12 GB VRAM | `qwen3:4b-instruct` | A practical technical-book starting point |
| NVIDIA 16 GB VRAM | `qwen3:8b` | More headroom improves reliability; not proven better on every book |
| NVIDIA 24+ GB / 64+ GB unified RAM | `qwen3:14b`; optionally Gemma 3 12B/27B | Check licensing, available memory and a representative page sample |
| CPU-only desktop, 32+ GB RAM | Qwen3 4B/8B if patient, or an LLM API | Speech stays local even when compilation uses an API |

Gemma 3 4B/12B/27B are alternatives in the selector, not declared winners over
Qwen. This project has measured only specific models/fixtures (see the root and
Apple READMEs); generic PC recommendations above are capacity estimates. Ollama's
published model sizes: [Qwen3](https://ollama.com/library/qwen3/tags),
[Gemma 3](https://ollama.com/library/gemma3/tags).

For an LLM API, choose a capable instruction model with chat/completions support
and at least a 16K context window. Prefer your provider's larger instruction tier
for dense technical material; use its exact current model ID. Both pipeline
routing tiers use that ID, so the installer does not silently select another paid
model. Your provider's normal LLM fees apply only when you convert. Test a small
book slice before a full book. Local speech has no per-minute speech API fee.

## Private phone/web access: Tailscale recommended

Install Tailscale on the PC and phone and join the same tailnet. On the PC:

```sh
tailscale serve --bg http://127.0.0.1:8000
```

Use the printed `https://...ts.net` URL as Firebrat's server address. Or open
`https://...ts.net/pwa/` on the phone. Tailscale Serve provides private HTTPS
inside your tailnet; **do not use Funnel** unless you deliberately want a public
service. No router port-forwarding is needed. Your PC must stay awake and the
server must remain running. Follow your tailnet's access rules; members allowed
to reach this service can read its served books.

The launcher management UI uses a different random **loopback-only** port and a
per-session token. Share port 8000, not the launcher port. Never publish the
setup URL or its token. The backend also binds only to loopback by default.

The PWA can also be opened at
https://subhajit-roy-partho.github.io/firebrat/ with the private HTTPS server URL
entered in Settings. Server/phone uploads and job management require Firebase
sign-in. Browser sign-in hosted on your own `ts.net` hostname also requires that
hostname in your Firebase authorized domains; public GitHub Pages already has
its hostname configured for this project's client. Desktop conversion through
the launcher does not need sign-in. Reading completed public server books does
not need sign-in.

[Headscale](https://headscale.net/), [NetBird](https://netbird.io/) or another
WireGuard mesh VPN can serve the same purpose; configure private reachability
and valid HTTPS for the browser/PWA. HTTP alone can prevent PWA service workers
and offline saves. This installer does not change your VPN or firewall settings.
Sources: [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve),
[Ollama OpenAI compatibility](https://docs.ollama.com/api/openai-compatibility),
[Ollama GPU guidance](https://docs.ollama.com/gpu).

## Files, credentials and removal

macOS data: `~/Library/Application Support/Firebrat Server/`.
Linux data: `~/.local/share/firebrat-server/`.
The Linux `.run` app itself is extracted to
`~/.local/share/firebrat-launcher/<version>/` (or `XDG_DATA_HOME`).

Settings/API keys are in a private `launcher-settings.json` with mode 0600, under a 0700
folder. Secrets are not returned by the status endpoint. `server.log` contains
setup/conversion diagnostics; the launcher does not print API keys. Keep your
user folder private. Books are under `books/`, PDFs under `uploads/`, Python
runtimes under `python/` and `envs/`, and Hugging Face weights under `models/`.
A launcher-owned Ollama process stores weights under `ollama-models/`; an already
running Ollama service keeps using its own configured model storage.

Quit before uninstalling. Removing the app does not remove your books or keys.
To remove those too, back up what you need and remove the data folder yourself.
No developer `.env`, private voice recording or private book is packaged.

## Build / validation

On the target OS, with Python 3.11:

```sh
python -m pip install -r installer/server/requirements-launcher.txt pytest
python -m pytest installer/server/tests -q
python installer/server/build.py --output /tmp/firebrat-server-installer --version preview
```

The build verifies SHA-256 of official uv and Tectonic archives, bundles the
tracked backend source and licenses, and creates a DMG or Linux `.run`/tarball
with SHA-256 companions. GitHub Actions builds Apple silicon, Intel Mac and
Linux x86-64 separately; this is not a single cross-compiled binary.
Tectonic renders formulas locally with TeX/amsmath and PyMuPDF rasterization,
without a system TeX/Ghostscript installation. Its first font/package download
needs internet; cached rendering works offline afterward.

Automated launcher tests check private settings, token/origin/Host protection,
streaming PDF upload limits, child-process stopping and local CPU/CUDA selection.
They do not establish GPU speed or neural conversion quality on an untested PC.

### Linux Docker installer

Download `Firebrat-Server-Docker-Linux.sh` from the server release, then run:

```sh
bash Firebrat-Server-Docker-Linux.sh cpu
# NVIDIA GPU: install the host driver and NVIDIA Container Toolkit first
bash Firebrat-Server-Docker-Linux.sh gpu
```

The script downloads `subhajitroy/firebrat:desktop-cpu` or `:desktop-gpu`, opens the same browser setup screen, and runs as your own user without privileged mode. Docker Engine must already be installed. Linux host networking is used so the manager, Ollama, and backend remain on this PC's loopback interface. This launcher is intended for a single local user; do not share its private setup URL. The phone connects to the backend through Tailscale Serve on port 8000, not to the setup screen.

Data lives in `~/.local/share/firebrat-server-docker`, including configuration, models, uploads, finished books, and logs. Keep it when replacing containers. Set `FIREBRAT_DATA` before first launch to choose another directory. Stop with `docker stop firebrat-desktop`; resume with `docker start firebrat-desktop` and run the script again to reopen the setup screen. To update, stop and remove **only the container**, then rerun the script; the data directory remains. Changing between CPU/GPU requires replacing the container. `FIREBRAT_IMAGE` can pin an immutable release tag such as `subhajitroy/firebrat:server-v0.1.0-desktop-cpu` instead of the moving desktop tag.

These images contain the Python runtimes, extraction, formula tools, Ollama, and local Chatterbox speech engine. Model weights download on first use; complete one conversion online before expecting offline use. Both CPU and GPU images keep voice synthesis local even when you choose a remote LLM API. The GPU image needs NVIDIA hardware and the Container Toolkit; CPU is the fallback for other Linux machines. Docker Desktop on macOS does not provide Apple Metal acceleration: use the native macOS installer and native Ollama there.

Images are built and smoke-tested by GitHub Actions before publication. Import/startup checks do not constitute an actual NVIDIA hardware benchmark. Source builds are also possible with `backend/docker/Dockerfile.desktop`, using the matching backend image as `BASE_IMAGE`.

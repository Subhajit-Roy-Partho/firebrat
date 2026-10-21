# Third-party components

The launcher bundles Python and PyInstaller's runtime under their respective
licenses, python-multipart (Apache-2.0), uv 0.13.4 (MIT/Apache-2.0) and Tectonic
0.17.0 (MIT). Upstream license texts for bundled tools are included in licenses/.
PyInstaller includes its bootloader exception permitting distribution of bundled
applications under their own licenses. See https://pyinstaller.org/ and
https://github.com/Kludex/python-multipart.

uv installs Python and separate extraction/voice/server dependencies on first
setup. Those packages and model weights retain their own licenses. Ollama is
installed separately from https://ollama.com/download. Model downloads are not
bundled in the installer. Review model licenses before redistributing weights.
The installer never bundles developer credentials, voice reference clips or books
from the developer's library.

The Linux desktop Docker images additionally bundle Ollama 0.40.8 under its MIT license; its license is included at `/usr/share/doc/ollama/LICENSE` inside the image. Native installers require a separate Ollama installation.

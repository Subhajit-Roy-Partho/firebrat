"""Per-user native backend manager. The administrative UI only binds to loopback."""
from __future__ import annotations
import atexit
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

LOCAL_MODELS = ("qwen3:1.7b", "qwen3:4b-instruct", "qwen3:8b", "qwen3:14b", "gemma3:4b", "gemma3:12b", "gemma3:27b")
BUNDLE = Path(getattr(sys, "_MEIPASS", Path(__file__).parent))
MAX_UPLOAD = 500 * 1024 * 1024


def hardware():
    ram = 0
    try:
        if sys.platform == "darwin":
            ram = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]))
        else:
            ram = os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE")
            limit = Path("/sys/fs/cgroup/memory.max")
            if limit.exists() and limit.read_text().strip().isdigit():
                ram = min(ram, int(limit.read_text()))
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    gpu = []
    try:
        text = subprocess.check_output(["nvidia-smi", "--query-gpu=name,memory.total,driver_version", "--format=csv,noheader,nounits"], text=True, timeout=5)
        for line in text.splitlines():
            name, memory, driver = line.rsplit(",", 2)
            gpu.append({"name": name.strip(), "gib": round(int(memory.strip()) / 1024, 1), "driver": driver.strip()})
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    gib = round(ram / 1024**3, 1)
    if gpu:
        budget = max(g["gib"] for g in gpu)
        model = "qwen3:1.7b" if budget < 8 else "qwen3:4b-instruct" if budget < 16 else "qwen3:8b" if budget < 24 else "qwen3:14b"
    elif platform.machine() == "arm64" and sys.platform == "darwin":
        model = "qwen3:1.7b" if gib < 12 else "qwen3:4b-instruct" if gib < 32 else "qwen3:8b" if gib < 64 else "qwen3:14b"
    else:
        model = "qwen3:1.7b" if gib < 32 else "qwen3:4b-instruct" if gib < 64 else "qwen3:8b"
    return {"os": platform.system(), "architecture": platform.machine(), "ram_gib": gib, "nvidia": gpu, "suggested_model": model}


def validate_config(data, previous=None):
    previous = previous or {}
    mode = data.get("mode", "local")
    if mode not in {"local", "api"}:
        raise ValueError("Choose a local model or your LLM API.")
    model = str(data.get("model", "")).strip()
    endpoint = str(data.get("endpoint", "")).strip().rstrip("/")
    key = str(data.get("api_key", ""))
    if mode == "local":
        if model not in LOCAL_MODELS:
            raise ValueError("Choose one of the downloadable local models.")
        endpoint, key = "http://127.0.0.1:11434/v1", "local"
    else:
        url = urlsplit(endpoint)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
            raise ValueError("Enter your provider's HTTPS API base URL, usually ending in /v1.")
        if not model or len(model) > 200:
            raise ValueError("Enter the exact model ID supported by your provider.")
        if not key and endpoint == previous.get("endpoint"):
            key = previous.get("api_key", "")
        if not key:
            raise ValueError("Enter your API key. It is kept only in your private local configuration.")
    if any("\n" in value or "\r" in value for value in (endpoint, model, key)):
        raise ValueError("Configuration values must fit on one line.")
    accelerator = data.get("accelerator", "auto")
    if accelerator not in {"auto", "cpu"}:
        raise ValueError("Choose automatic CUDA detection or CPU.")
    return {"mode": mode, "model": model, "endpoint": endpoint, "api_key": key, "accelerator": accelerator}


def receive_upload(handler, destination):
    """Bounded streaming multipart parsing; never load an entire PDF into RAM."""
    from python_multipart import MultipartParser
    from python_multipart.multipart import parse_options_header
    length = int(handler.headers.get("Content-Length", "0"))
    if length <= 0 or length > MAX_UPLOAD:
        raise ValueError("Choose a PDF smaller than 500 MB.")
    content_type, options = parse_options_header(handler.headers.get("Content-Type", ""))
    if content_type != b"multipart/form-data" or b"boundary" not in options:
        raise ValueError("Choose a PDF file.")
    state = {"headers": {}, "name": b"", "value": b"", "file": None, "seen": False, "bytes": 0}
    def begin(): state.update(headers={}, name=b"", value=b"", file=None)
    def field(data, start, end):
        state["name"] += data[start:end]
        if len(state["name"]) > 1024: raise ValueError("Upload header is too long.")
    def value(data, start, end):
        state["value"] += data[start:end]
        if len(state["value"]) > 8192: raise ValueError("Upload header is too long.")
    def header_end():
        state["headers"][state["name"].lower()] = state["value"]
        state["name"], state["value"] = b"", b""
    def headers_done():
        _, params = parse_options_header(state["headers"].get(b"content-disposition", b""))
        if len(state["headers"]) > 32: raise ValueError("Too many upload headers.")
        if params.get(b"name") == b"book":
            if state["seen"]: raise ValueError("Choose one PDF at a time.")
            if not params.get(b"filename", b"").lower().endswith(b".pdf"): raise ValueError("Choose a PDF file.")
            state["seen"] = True
            state["filename"] = params.get(b"filename", b"book.pdf").decode("utf-8", "replace").replace("\\", "/").rsplit("/", 1)[-1]
            state["file"] = destination.open("wb")
    def part_data(data, start, end):
        if state["file"]:
            state["bytes"] += end - start
            state["file"].write(data[start:end])
    def part_end():
        if state["file"]: state["file"].close(); state["file"] = None
    parser = MultipartParser(options[b"boundary"], {"on_part_begin": begin, "on_header_field": field, "on_header_value": value, "on_header_end": header_end, "on_headers_finished": headers_done, "on_part_data": part_data, "on_part_end": part_end})
    try:
        remaining = length
        while remaining:
            block = handler.rfile.read(min(65536, remaining))
            if not block: raise ValueError("Upload was interrupted.")
            parser.write(block); remaining -= len(block)
        parser.finalize()
        part_end()
        if not state["seen"] or not state["bytes"]: raise ValueError("Choose a nonempty PDF.")
        with destination.open("rb") as book:
            if b"%PDF-" not in book.read(1024): raise ValueError("This file is not a PDF.")
        return Path(state["filename"]).stem[:180] or "New book"
    except Exception:
        part_end(); destination.unlink(missing_ok=True); raise


class Controller:
    def __init__(self, root=None, bundle=BUNDLE):
        default = Path.home() / ("Library/Application Support/Firebrat Server" if sys.platform == "darwin" else ".local/share/firebrat-server")
        self.root = Path(root or default); self.root.mkdir(parents=True, exist_ok=True); self.root.chmod(0o700)
        self.hardware_info = hardware()
        self.bundle = Path(bundle)
        self.config_path = self.root / "launcher-settings.json"
        self.config = json.loads(self.config_path.read_text()) if self.config_path.exists() else {}
        self.stage, self.error = "Ready for setup", ""
        self.children = []; self.process_lock = threading.Lock(); self.work_lock = threading.Lock()
        self.api = None; self.active_book = None; self.closing = False
        self.server_token = secrets.token_urlsafe(32)
        self.preinstalled = os.environ.get("FIREBRAT_DESKTOP_PREINSTALLED") == "1"
        self.source = Path("/app/backend") if self.preinstalled else self.bundle / "backend"
        self.bin = self.bundle / "bin"
        self.log_path = self.root / "server.log"
        self.ready_stamp = self.root / "runtime-ready.json"
    def python(self, env):
        if self.preinstalled: return str(Path("/opt/venvs") / env / "bin/python")
        profile = "cpu" if self.config.get("accelerator") == "cpu" else "auto"
        return str(self.root / "envs" / (env + "-" + profile) / "bin/python")
    def requirement_file(self, name):
        profile = "cpu" if self.config.get("accelerator") == "cpu" else "auto"
        locked = self.bundle / f"requirements-{name}-{profile}.txt"
        return locked if locked.is_file() else self.bundle / f"requirements-{name}.txt"
    def runtime_ready(self):
        if self.preinstalled: return all(Path(self.python(n)).is_file() for n in ("extract", "tts", "serve"))
        digest = hashlib.sha256(b"".join(self.requirement_file(name).read_bytes() for name in ("extract", "tts", "serve"))).hexdigest()
        try: return json.loads(self.ready_stamp.read_text()).get("requirements") == digest and all(Path(self.python(n)).is_file() for n in ("extract", "tts", "serve"))
        except (OSError, ValueError): return False
    def save(self, data):
        if not self.work_lock.acquire(blocking=False): raise ValueError("Wait for the current operation to finish.")
        try:
            if self.api and self.api.poll() is None: raise ValueError("Stop the server before changing its setup.")
            config = validate_config(data, self.config)
            fd = os.open(self.config_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f: json.dump(config, f)
            self.config = config
            defaults = self.root / "server/settings.json"
            defaults.parent.mkdir(exist_ok=True)
            defaults.write_text(json.dumps({"default_provider": "local" if config["mode"] == "local" else "nanogpt", "default_chunk_pages": 2}))
        finally: self.work_lock.release()
    def environment(self):
        # Never inherit a different project's keys or notification credentials.
        env = {k:v for k,v in os.environ.items() if not k.startswith(("NANO_", "MODEL_", "FIREBRAT_", "TELEGRAM_", "UV_"))}
        env.pop("PYTHONHOME", None)
        env.pop("HF_HUB_CACHE", None)
        original_library_path = env.pop("LD_LIBRARY_PATH_ORIG", None)
        if original_library_path: env["LD_LIBRARY_PATH"] = original_library_path
        else: env.pop("LD_LIBRARY_PATH", None)
        env.update(UV_CACHE_DIR=str(self.root / "cache/uv"), UV_PYTHON_INSTALL_DIR=str(self.root / "python"),
                   PYTHONPATH=str(self.source), HF_HOME=str(self.root / "models"),
                   FIREBRAT_EXTRACT_PY=self.python("extract"), FIREBRAT_CONVERT_PY=self.python("extract"),
                   FIREBRAT_TTS_PY=self.python("tts"), FIREBRAT_DESKTOP_TOKEN=self.server_token,
                   FIREBRAT_LOCAL_LLM_URL="http://127.0.0.1:11434/v1", FIREBRAT_OUTPUT_DIR=str(self.root / "books"),
                   FIREBRAT_UPLOAD_DIR=str(self.root / "uploads"), FIREBRAT_JOBS_DB=str(self.root / "server/jobs.sqlite3"),
                   FIREBRAT_EXTRACT_BATCH_PAGES="2", FIREBRAT_MAX_CONCURRENT_JOBS="1",
                   FIREBRAT_TTS_DEVICE="auto" if self.config.get("accelerator") == "auto" else "cpu",
                   FIREBRAT_HOST="127.0.0.1", FIREBRAT_PORT="8000", PYTHONUNBUFFERED="1",
                   GOOGLE_CLOUD_PROJECT="firebrat-8c597", OLLAMA_MODELS=str(self.root / "ollama-models"), OLLAMA_HOST="127.0.0.1:11434", OLLAMA_NO_CLOUD="1",
                   NANO_API_URL=self.config.get("endpoint", ""), MODEL_API_KEY=self.config.get("api_key", ""),
                   FIREBRAT_SPARK_MODEL=self.runtime_model(), FIREBRAT_DEEPSEEK_MODEL=self.runtime_model())
        env["PATH"] = str(self.root / "bin") + os.pathsep + str(self.bin) + os.pathsep + env.get("PATH", "")
        if self.config.get("accelerator") == "cpu": env.update(CUDA_VISIBLE_DEVICES="", TORCH_DEVICE="cpu")
        return env
    def spawn(self, argv, env=None):
        with self.process_lock:
            if self.closing: raise ValueError("The launcher is shutting down.")
            with self.log_path.open("ab") as log:
                p = subprocess.Popen(argv, env=env or self.environment(), stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            self.children.append(p)
        return p
    def run(self, argv, env=None):
        p = self.spawn(argv, env)
        if p.wait() != 0: raise RuntimeError("This step failed. Open server.log for details; your API key is not logged by the launcher.")
    def background(self, function):
        if not self.work_lock.acquire(blocking=False): raise ValueError("An operation is already running.")
        def work():
            try: self.error = ""; function()
            except Exception as e: self.error = str(e); self.stage = "Action needed"
            finally: self.work_lock.release()
        threading.Thread(target=work, daemon=True).start()
    def setup(self):
        if not self.config: raise ValueError("Save your setup first.")
        if self.api and self.api.poll() is None: raise ValueError("Stop the server before setup.")
        if self.preinstalled:
            self.stage = "Tools are installed in the image. First conversion downloads model weights."
            return
        uv = str(self.bin / "uv")
        for name in ("serve", "extract", "tts"):
            self.stage = "Installing " + {"serve":"library tools", "extract":"PDF extraction tools", "tts":"local voice generation"}[name] + " — first setup downloads several GB"
            target = Path(self.python(name)).parent.parent
            target.parent.mkdir(parents=True, exist_ok=True)
            if not Path(self.python(name)).is_file():
                if target.exists(): shutil.rmtree(target)
                self.run([uv, "--no-config", "venv", "--managed-python", "--python", "3.11", str(target)])
            cmd = [uv, "--no-config", "pip", "install", "--python", self.python(name), "-r", str(self.requirement_file(name))]
            if "--hash=" in self.requirement_file(name).read_text(): cmd.append("--require-hashes")
            if sys.platform == "linux" and self.config.get("accelerator") == "cpu": cmd += ["--torch-backend", "cpu"]
            self.run(cmd)
        self.stage = "Preparing local audio and formula tools"
        ffmpeg = subprocess.check_output([self.python("serve"), "-c", "import imageio_ffmpeg;print(imageio_ffmpeg.get_ffmpeg_exe())"], env=self.environment(), text=True).strip()
        tools = self.root / "bin"; tools.mkdir(exist_ok=True)
        link = tools / "ffmpeg"; link.unlink(missing_ok=True); link.symlink_to(ffmpeg)
        self.run([self.python("extract"), "-c", "from firebrat.pipeline.formulas import render_latex_to_png;import sys;sys.exit(0 if render_latex_to_png(r'\\frac{1}{2}=0.5',sys.argv[1]) else 1)", str(self.root / "formula-check.png")])
        digest = hashlib.sha256(b"".join(self.requirement_file(name).read_bytes() for name in ("extract", "tts", "serve"))).hexdigest()
        self.ready_stamp.write_text(json.dumps({"requirements": digest}))
        self.stage = "Installed. First conversion downloads extraction and voice weights; keep internet on until it completes."
    @staticmethod
    def responds(url):
        try:
            with urllib.request.urlopen(url, timeout=2) as r: return r.status == 200
        except (OSError, urllib.error.URLError): return False
    def prepare_llm(self):
        if self.config.get("mode") != "local": return
        ollama = shutil.which("ollama")
        if not ollama and Path("/Applications/Ollama.app/Contents/Resources/ollama").is_file(): ollama = "/Applications/Ollama.app/Contents/Resources/ollama"
        if not ollama: raise ValueError("Install native Ollama from ollama.com/download, then choose Start again.")
        if not self.responds("http://127.0.0.1:11434/api/tags"):
            self.stage = "Starting your local model runtime"
            p = self.spawn([ollama, "serve"])
            for _ in range(60):
                if self.responds("http://127.0.0.1:11434/api/tags"): break
                if p.poll() is not None: raise ValueError("Ollama could not start. Check server.log.")
                time.sleep(1)
            else: raise ValueError("Ollama did not become ready.")
        self.stage = "Checking the selected local LLM"
        present = subprocess.run([ollama, "show", self.config["model"]], env=self.environment(),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15)
        if present.returncode != 0:
            self.stage = "Downloading the selected local LLM — first use needs internet"
            self.run([ollama, "pull", self.config["model"]])
        modelfile = self.root / "Ollama.Modelfile"
        modelfile.write_text("FROM " + self.config["model"] + "\nPARAMETER num_ctx 16384\n")
        self.run([ollama, "create", self.runtime_model(), "-f", str(modelfile)])
    def start(self):
        if not self.config: raise ValueError("Save your setup first.")
        if not self.runtime_ready(): raise ValueError("Run Install dependencies first.")
        if self.api and self.api.poll() is None: return
        if self.responds("http://127.0.0.1:8000/health"): raise ValueError("Port 8000 is already in use. Stop that server first.")
        self.prepare_llm()
        self.stage = "Starting your library server"
        self.api = self.spawn([self.python("serve"), "-m", "uvicorn", "server.main:app", "--host", "127.0.0.1", "--port", "8000"])
        for _ in range(60):
            if self.responds("http://127.0.0.1:8000/health"): self.stage = "Server ready — choose a PDF below"; return
            if self.api.poll() is not None: break
            time.sleep(1)
        raise ValueError("Server did not start. Check server.log.")
    def runtime_model(self):
        model = self.config.get("model", "")
        return "firebrat-" + model.replace(":", "-") if self.config.get("mode") == "local" else model
    def desktop_request(self, route, data=None):
        request = urllib.request.Request("http://127.0.0.1:8000" + route,
                    data=json.dumps(data).encode() if data is not None else None,
                    headers={"Content-Type":"application/json", "X-Firebrat-Desktop-Token":self.server_token})
        with urllib.request.urlopen(request, timeout=10) as response: return json.load(response)
    def convert(self, path, content_mode, title):
        if content_mode not in {"illustrated", "novel"}: raise ValueError("Choose illustrated or novel.")
        if not self.api or self.api.poll() is not None: raise ValueError("Start the server first.")
        job = self.desktop_request("/desktop/jobs", {"path":str(path), "title":title,
                    "content_mode":content_mode, "provider":"local" if self.config["mode"] == "local" else "nanogpt"})
        self.active_book = job["book_id"]
        while True:
            if not self.api or self.api.poll() is not None: raise ValueError("Server stopped during conversion; partial work is kept.")
            job = self.desktop_request("/desktop/jobs/" + job["job_id"])
            self.stage = "Converting your book: " + (job.get("stage") or job["state"])
            if job["state"] == "failed": raise ValueError(job.get("error") or "Conversion failed. Check server.log and the book folder.")
            if job["state"] == "done":
                review = job.get("needs_review_count", 0)
                self.stage = "Book ready — refresh the library on your phone" + (f". Review {review} flagged passages." if review else "")
                return
            time.sleep(1)
    def stop(self):
        with self.process_lock:
            self.closing = True
            for child in reversed(self.children):
                if child.poll() is None:
                    try: os.killpg(child.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
            for child in self.children:
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    try: os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError: pass
            self.children.clear(); self.api = None; self.closing = False
        self.stage = "Server stopped — your books and models are kept"
    def status(self):
        progress = None
        if self.active_book:
            path = self.root / "books" / self.active_book / "status.json"
            try: progress = json.loads(path.read_text())
            except (OSError, ValueError): pass
        config = {k:v for k,v in self.config.items() if k != "api_key"}
        return {"stage": self.stage, "error": self.error, "busy": self.work_lock.locked(), "server": bool(self.api and self.api.poll() is None), "installed": self.runtime_ready(), "config": config, "progress": progress, "hardware": self.hardware_info, "models": LOCAL_MODELS, "data_folder": str(self.root)}


class Handler(BaseHTTPRequestHandler):
    def setup(self):
        super().setup()
        self.connection.settimeout(60)
    def log_message(self, *args): pass
    def send(self, status, data, content_type="application/json"):
        data = data if isinstance(data, bytes) else json.dumps(data).encode()
        self.send_response(status); self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("X-Content-Type-Options", "nosniff"); self.end_headers(); self.wfile.write(data)
    def allowed(self):
        expected = f"127.0.0.1:{self.server.server_port}"
        origin = self.headers.get("Origin")
        return self.headers.get("Host") == expected and (not origin or origin == "http://" + expected)
    def authorized(self): return self.allowed() and secrets.compare_digest(self.headers.get("X-Firebrat-Token", ""), self.server.token)
    def do_GET(self):
        if not self.allowed(): return self.send(403, {"error":"Open the launcher using its own address."})
        if self.path in {"/", "/app.js", "/style.css"}:
            name = {"/":"index.html", "/app.js":"app.js", "/style.css":"style.css"}[self.path]
            return self.send(200, (self.server.controller.bundle / "ui" / name).read_bytes(), {"index.html":"text/html; charset=utf-8", "app.js":"text/javascript", "style.css":"text/css"}[name])
        if not self.authorized(): return self.send(403, {"error":"Reopen Firebrat Server to manage it."})
        if self.path == "/status": return self.send(200, self.server.controller.status())
        return self.send(404, {})
    def do_POST(self):
        if not self.authorized(): return self.send(403, {"error":"Reopen Firebrat Server to manage it."})
        c = self.server.controller
        try:
            if self.path == "/convert":
                if c.work_lock.locked(): raise ValueError("Wait for the current operation to finish.")
                mode = self.headers.get("X-Book-Mode", "illustrated")
                if mode not in {"illustrated", "novel"}: raise ValueError("Choose illustrated or novel.")
                uploads = c.root / "uploads"; uploads.mkdir(exist_ok=True)
                path = uploads / ("book-" + uuid.uuid4().hex + ".pdf")
                title = receive_upload(self, path)
                try: c.background(lambda: c.convert(path, mode, title))
                except Exception: path.unlink(missing_ok=True); raise
            else:
                length = int(self.headers.get("Content-Length", "0"))
                if length > 16384: raise ValueError("Setup is too large.")
                data = json.loads(self.rfile.read(length) or b"{}")
                if self.path == "/config": c.save(data)
                elif self.path == "/setup": c.background(c.setup)
                elif self.path == "/start": c.background(c.start)
                elif self.path == "/stop": c.stop()
                elif self.path == "/quit":
                    c.stop(); threading.Thread(target=self.server.shutdown, daemon=True).start()
                else: return self.send(404, {})
            self.send(200, {"ok":True})
        except (ValueError, OSError) as e: self.send(400, {"error":str(e)})


def main():
    os.umask(0o077)
    controller = Controller(root=os.environ.get("FIREBRAT_DESKTOP_DATA"))
    lock = (controller.root / "launcher.lock").open("a")
    address = controller.root / "launcher-address.json"
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        try: webbrowser.open(json.loads(address.read_text())["url"])
        except (OSError, ValueError): pass
        return
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.token = secrets.token_urlsafe(32); server.controller = controller
    atexit.register(controller.stop)
    def shutdown(*_): threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGTERM, shutdown); signal.signal(signal.SIGINT, shutdown)
    url = f"http://127.0.0.1:{server.server_port}/#{server.token}"
    address.write_text(json.dumps({"url": url}))
    print("Firebrat Server is opening in your browser. Close it with the Quit button.", flush=True)
    webbrowser.open(url)
    try: server.serve_forever()
    finally:
        server.server_close(); controller.stop(); address.unlink(missing_ok=True)
        lock.close()

def smoke_test():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="firebrat-launcher-smoke-") as folder:
        controller = Controller(folder)
        for relative in ("backend/convert.py", "backend/server/routes/desktop.py", "ui/index.html"):
            if not (BUNDLE / relative).is_file(): raise RuntimeError("Missing bundled resource: " + relative)
        versions = {name: subprocess.check_output([str(BUNDLE / "bin" / name), "--version"],
                    env=controller.environment(), text=True).strip() for name in ("uv", "tectonic")}
        print(json.dumps({"resources": "ok", "tools": versions}))

if __name__ == "__main__":
    smoke_test() if "--smoke-test" in sys.argv else main()

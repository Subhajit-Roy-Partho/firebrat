from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from server import job_runner
from server.routes.admin import router as admin_router
from server.routes.desktop import router as desktop_router
from server.routes.health import router as health_router
from server.routes.books import router as books_router
from server.routes.jobs import router as jobs_router
from server.routes.profile import router as profile_router
from server.routes.settings import router as settings_router


@asynccontextmanager
async def _lifespan(app: FastAPI):
    job_runner.ensure_workers_started()
    job_runner.resume_orphaned_jobs()
    # IAM first-run: mint the one-time setup code (log + SETUP_CODE.txt)
    # when no admin exists yet. Idempotent — a no-op once set up.
    try:
        from server import config as _config
        from server import iam as _iam
        if _config.iam_enabled():
            _iam.ensure_setup_code()
    except Exception:
        import logging
        logging.getLogger("firebrat.server").exception("IAM setup-code minting failed")
    # Expressive-cast scheduler: supervised child process that turns inbox
    # entries into packages under <cast_root>/out (symlinked to OUTPUT_DIR
    # so /books lists them). Only when the operator enabled it.
    try:
        from server import cast_bridge
        from server import config as _config
        if _config.cast_enabled():
            cast_bridge.ensure_out_symlink()
            cast_bridge.ensure_supervisor_started()
    except Exception:
        import logging
        logging.getLogger("firebrat.server").exception("Cast supervisor startup failed")
    yield
    try:
        from server import cast_bridge as _bridge
        _bridge.shutdown_supervisor()
    except Exception:
        pass


app = FastAPI(title="Firebrat", version="0.1.0", lifespan=_lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router, tags=["health"])
app.include_router(desktop_router, tags=["desktop"])
app.include_router(books_router, tags=["books"])
app.include_router(jobs_router, tags=["jobs"])
app.include_router(profile_router, tags=["profile"])
app.include_router(settings_router, tags=["settings"])
# Server administration (IAM): every endpoint 404s unless FIREBRAT_IAM=1.
app.include_router(admin_router, tags=["admin"])

# Browser control room: dependency-free static UI (upload, jobs, books,
# settings) at /. The JSON API above is untouched; /docs still serves
# the Swagger UI.
_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
if os.path.isdir(_STATIC_DIR):
    app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")

    @app.get("/", include_in_schema=False)
    def web_ui():
        return FileResponse(os.path.join(_STATIC_DIR, "index.html"))

# Installable reader and server-conversion client (no browser conversion engine).
_PWA_DIR = os.path.join(_STATIC_DIR, "pwa")
if os.path.isfile(os.path.join(_PWA_DIR, "index.html")):
    @app.get("/pwa/sw.js", include_in_schema=False)
    def pwa_service_worker():
        return FileResponse(os.path.join(_PWA_DIR, "sw.js"), media_type="text/javascript",
                            headers={"Cache-Control": "no-cache", "Service-Worker-Allowed": "/pwa/"})
    app.mount("/pwa", StaticFiles(directory=_PWA_DIR, html=True), name="pwa")

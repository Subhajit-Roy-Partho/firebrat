from contextlib import asynccontextmanager
import os

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from server import job_runner
from server.routes.health import router as health_router
from server.routes.books import router as books_router
from server.routes.jobs import router as jobs_router
from server.routes.settings import router as settings_router


@asynccontextmanager
async def _lifespan(app: FastAPI):
    job_runner.ensure_workers_started()
    job_runner.resume_orphaned_jobs()
    yield


app = FastAPI(title="Firebrat", version="0.1.0", lifespan=_lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router, tags=["health"])
app.include_router(books_router, tags=["books"])
app.include_router(jobs_router, tags=["jobs"])
app.include_router(settings_router, tags=["settings"])

# Browser control room: dependency-free static UI (upload, jobs, books,
# settings) at /. The JSON API above is untouched; /docs still serves
# the Swagger UI.
_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
if os.path.isdir(_STATIC_DIR):
    app.mount("/static", StaticFiles(directory=_STATIC_DIR), name="static")

    @app.get("/", include_in_schema=False)
    def web_ui():
        return FileResponse(os.path.join(_STATIC_DIR, "index.html"))

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from server import job_runner
from server.routes.health import router as health_router
from server.routes.books import router as books_router
from server.routes.jobs import router as jobs_router


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

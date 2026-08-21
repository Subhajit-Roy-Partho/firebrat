from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from server.routes.health import router as health_router
from server.routes.books import router as books_router

app = FastAPI(title="Firebrat", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(health_router, tags=["health"])
app.include_router(books_router, tags=["books"])

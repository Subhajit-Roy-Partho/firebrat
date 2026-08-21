"""FastAPI server config."""
import os

OUTPUT_DIR = os.environ.get("FIREBRAT_OUTPUT_DIR",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "output"))
HOST = os.environ.get("FIREBRAT_HOST", "0.0.0.0")
PORT = int(os.environ.get("FIREBRAT_PORT", "8000"))

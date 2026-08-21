#!/usr/bin/env python3
"""Package an already-converted book directory into a portable .tar.gz
without re-running the pipeline. Useful for books converted before the
packaging step existed, or to re-package after manually editing a package.

Usage: python package_existing.py backend/output/<book_id>
"""
import logging
import os
import sys

_BACKEND_DIR = os.path.dirname(os.path.abspath(__file__))
if _BACKEND_DIR not in sys.path:
    sys.path.insert(0, _BACKEND_DIR)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s: %(message)s")

from firebrat.pipeline.package import package_book  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    path = package_book(sys.argv[1])
    print(path)

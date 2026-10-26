#!/usr/bin/env python3
"""cPanel cron entry point for private metadata backups and media expiry."""
from __future__ import annotations

import os
import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parents[1]
os.chdir(BACKEND_DIR)
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

from app import create_app  # noqa: E402
from app.services.retention_maintenance import run_maintenance  # noqa: E402


if __name__ == '__main__':
    application = create_app()
    with application.app_context():
        run_maintenance(application)

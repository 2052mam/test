#!/usr/bin/env python3
"""CLI script to run 72-hour automatic data retention cleanup (for cron or systemd timers)."""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from app import create_app
from app.services.retention_maintenance import run_retention_maintenance


def main():
    app = create_app()
    with app.app_context():
        result = run_retention_maintenance()
        print(
            f"[Reyno Lite Retention] Purged {result['purged_messages']} messages and "
            f"{result['purged_media_files']} media files ({result['freed_bytes']} bytes freed)."
        )


if __name__ == '__main__':
    main()

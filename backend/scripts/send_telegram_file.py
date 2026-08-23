#!/usr/bin/env python3
"""Send a large file via a personal Telegram account (Telethon), bypassing the
50MB Bot API limit. Supports up to 2GB (4GB for Premium accounts).

Setup:
  1. Get api_id/api_hash from https://my.telegram.org/apps
  2. export TELEGRAM_API_ID=... TELEGRAM_API_HASH=... in ~/.zshrc
  3. First run is interactive: it will ask for your phone number, the login
     code Telegram sends you, and your 2FA password if you have one set.
     A session file (telegram_user.session) is saved next to this script so
     future runs don't need to log in again.

Usage:
  python send_telegram_file.py <path-to-file> [target]

  target defaults to "me" (Telegram's Saved Messages). Pass a username
  (e.g. "@someone"), a phone number, or a numeric chat/user ID to send
  elsewhere.
"""
import asyncio
import os
import sys
from pathlib import Path

from telethon import TelegramClient
from telethon.tl.types import DocumentAttributeFilename

SESSION_PATH = Path(__file__).parent / "telegram_user.session"


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


async def main() -> None:
    if len(sys.argv) < 2:
        die("usage: send_telegram_file.py <path-to-file> [target]")

    file_path = Path(sys.argv[1]).expanduser()
    target = sys.argv[2] if len(sys.argv) > 2 else "me"

    if not file_path.is_file():
        die(f"file not found: {file_path}")

    api_id = os.environ.get("TELEGRAM_API_ID")
    api_hash = os.environ.get("TELEGRAM_API_HASH")
    if not api_id or not api_hash:
        die("TELEGRAM_API_ID / TELEGRAM_API_HASH not set (see script docstring)")

    client = TelegramClient(str(SESSION_PATH), int(api_id), api_hash)
    await client.start()

    size_mb = file_path.stat().st_size / (1024 * 1024)
    print(f"Uploading {file_path.name} ({size_mb:.1f} MB) to {target} ...")

    last_pct = -1

    def progress(sent, total):
        nonlocal last_pct
        pct = int(sent * 100 / total)
        if pct != last_pct:
            print(f"\r{pct}%", end="", flush=True)
            last_pct = pct

    await client.send_file(
        target,
        str(file_path),
        attributes=[DocumentAttributeFilename(file_path.name)],
        progress_callback=progress,
    )
    print("\nDone.")
    await client.disconnect()


if __name__ == "__main__":
    asyncio.run(main())

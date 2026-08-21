"""Telegram progress pings — never throws."""
import logging
import os
import requests

log = logging.getLogger(__name__)


def send_telegram(text: str, parse_mode: str | None = None) -> bool:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
    if not token or not chat_id:
        log.debug("Telegram not configured, skipping: %s", text[:80])
        return False
    try:
        data = {"chat_id": chat_id, "text": text}
        if parse_mode:
            data["parse_mode"] = parse_mode
        resp = requests.post(
            f"https://api.telegram.org/bot{token}/sendMessage",
            data=data, timeout=10,
        )
        if not resp.ok:
            log.warning("Telegram send failed HTTP %s: %s", resp.status_code, resp.text[:300])
            return False
        return True
    except Exception as e:
        log.warning("Telegram send failed: %s", e)
        return False

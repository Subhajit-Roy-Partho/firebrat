#!/usr/bin/env bash
# notify_telegram.sh "your message here"
set -euo pipefail
if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
  echo "Telegram not configured (TELEGRAM_BOT_TOKEN/TELEGRAM_CHAT_ID missing), skipping: $*" >&2
  exit 0
fi
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=$*" \
  | head -c 500; echo

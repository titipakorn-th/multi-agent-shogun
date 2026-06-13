#!/usr/bin/env bash
# telegram_send.sh — One-way push to Telegram sendMessage.
# Used by shogun_telegram_relay.sh and other Lord-bound notifications.
#
# Usage:
#   telegram_send.sh <text> [--env-file <path>] [--curl-binary <path>]
#
# Exit codes:
#   0  success OR no-op (Telegram not configured)
#   1  Telegram API error after retry
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../config/telegram.env"
CURL_BIN="${CURL_BIN:-curl}"
TEXT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file) ENV_FILE="$2"; shift 2 ;;
        --curl-binary) CURL_BIN="$2"; shift 2 ;;
        *) TEXT="$1"; shift ;;
    esac
done

# Load env
if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_CHAT_ID:-}"

if [[ -z "$TOKEN" || -z "$CHAT_ID" || "$TOKEN" == "your_bot_token_here" ]]; then
    # No-op: Telegram not configured. Silent exit so cron-driven callers
    # don't fill logs.
    exit 0
fi

# Truncate
MAX=4080   # Telegram limit is 4096; TRUNCATE_SUFFIX is 12 chars
if [[ ${#TEXT} -gt $MAX ]]; then
    TEXT="${TEXT:0:$MAX}…[truncated]"
fi

# Send with exponential backoff retry on 5xx/429.
# Backoff per spec §Error row 3: 1, 2, 4, 8 seconds.
send_once() {
    "$CURL_BIN" -sS -X POST \
        "https://api.telegram.org/bot${TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${TEXT}" \
        --max-time 15
}

backoff=1
for attempt in 1 2 3 4 5; do
    RESP="$(send_once || true)"
    if [[ "$RESP" == *'"ok":true'* ]]; then
        exit 0
    fi
    if [[ $attempt -lt 5 ]]; then
        sleep "$backoff"
        backoff=$((backoff * 2))
    fi
done

echo "ERROR: telegram_send.sh failed after retries: $RESP" >&2
exit 1

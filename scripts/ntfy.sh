#!/usr/bin/env bash
# SayTask Notification — Send push notification to smartphone via ntfy.sh
# FR-066: ntfy authentication support (Bearer token / Basic auth)
#
# telegram.mode gate: when mode=off, this script exits silently — Lord is at
# CLI/tmux and shouldn't get Telegram pings. See instructions/shogun.md →
# "Response Channel Mode (telegram.mode)".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# Mode gate: respect telegram.mode from settings.yaml.
# ponytail: short-circuit before any network call when Lord is at CLI.
TELEGRAM_MODE=$(grep -E "^[[:space:]]*mode:" "$SETTINGS" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[[:space:]]*mode:[[:space:]]*"?([^"]+)"?/\1/' \
    | tr '[:upper:]' '[:lower:]')
if [[ "$TELEGRAM_MODE" == "off" ]]; then
    exit 0
fi

# Load Telegram configuration if available
TELEGRAM_ENV="$SCRIPT_DIR/config/telegram.env"
if [ -f "$TELEGRAM_ENV" ]; then
  # Sourcing the env file
  # shellcheck disable=SC1090
  source "$TELEGRAM_ENV"
fi

# Deduplication harness
# Prevents double-messages if multiple agents report same info within short window
LAST_MSG_FILE="/tmp/ntfy_last_msg_$(id -u).txt"
MSG_HASH=$(echo "$1" | md5sum 2>/dev/null | awk '{print $1}')
[ -z "$MSG_HASH" ] && MSG_HASH=$(echo "$1" | cksum | awk '{print $1}')
CURRENT_TIME=$(date +%s)

if [ -f "$LAST_MSG_FILE" ]; then
  read -r LAST_HASH LAST_TIME < "$LAST_MSG_FILE"
  if [ "$MSG_HASH" = "$LAST_HASH" ] && [ $((CURRENT_TIME - LAST_TIME)) -lt 5 ]; then
    # Duplicate detected within 5s window, skipping
    exit 0
  fi
fi
echo "$MSG_HASH $CURRENT_TIME" > "$LAST_MSG_FILE"

if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] && [ "$TELEGRAM_BOT_TOKEN" != "your_bot_token_here" ]; then
  # Route notification to Telegram
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${1}" > /dev/null
  exit 0
fi

# Fallback to ntfy if Telegram is not configured
# Load ntfy_auth.sh
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" 2>/dev/null | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  # Silently exit if neither Telegram nor ntfy is configured to prevent error noise
  exit 0
fi

# Get auth args (empty if no settings = backward compatibility)
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

# shellcheck disable=SC2086
curl -s "${AUTH_ARGS[@]}" -H "Tags: outbound" -d "$1" "https://ntfy.sh/$TOPIC" > /dev/null

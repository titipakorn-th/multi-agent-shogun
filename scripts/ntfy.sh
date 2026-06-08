#!/usr/bin/env bash
# SayTask Notification — Send push notification to smartphone via ntfy.sh
# FR-066: ntfy authentication support (Bearer token / Basic auth)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="$SCRIPT_DIR/config/settings.yaml"

# Load ntfy_auth.sh
# shellcheck source=../lib/ntfy_auth.sh
source "$SCRIPT_DIR/lib/ntfy_auth.sh"

TOPIC=$(grep 'ntfy_topic:' "$SETTINGS" | awk '{print $2}' | tr -d '"')
if [ -z "$TOPIC" ]; then
  echo "ntfy_topic not configured in settings.yaml" >&2
  exit 1
fi

# Get auth args (empty if no settings = backward compatibility)
AUTH_ARGS=()
while IFS= read -r line; do
    [ -n "$line" ] && AUTH_ARGS+=("$line")
done < <(ntfy_get_auth_args "$SCRIPT_DIR/config/ntfy_auth.env")

# shellcheck disable=SC2086
curl -s "${AUTH_ARGS[@]}" -H "Tags: outbound" -d "$1" "https://ntfy.sh/$TOPIC" > /dev/null

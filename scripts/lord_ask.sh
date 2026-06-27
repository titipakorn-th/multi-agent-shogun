#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# lord_ask.sh — AskQuestion → Telegram wrapper (W4c consolidated)
# ═══════════════════════════════════════════════════════════════
# W4c round-7: this script no longer writes current_question.json
# directly. It delegates to scripts/lib/lord_channel.py, which owns
# the state file under flock and exposes ask() + consume(). Same
# Telegram UX, same Lord-ask flow at the boundary.
#
# Usage:
#   lord_ask.sh <question> [option1 option2 ...] [--timeout <seconds>]
#
# Behavior (telegram.mode=on):
#   1. Calls lord_channel.py ask with the question + options.
#   2. lord_channel.py writes pending state, sends Telegram question.
#   3. Polls until status=answered (callback) or timeout.
#   4. On answer: prints answer to stdout, exits 0.
#   5. On timeout: prints "no answer; proceeding with default", emits
#      lord_question_timeout event into shogun inbox, exits 3.
#
# Behavior (telegram.mode=off):
#   Lord is at CLI — fall back to terminal stdin. No Telegram, no queue.
#
# Test overrides:
#   LORD_ASK_CHANNEL — path to lord_channel.py (default: $SCRIPT_DIR/lib/lord_channel.py)
#   LORD_ASK_QUEUE_DIR — path to queue dir (default: $SCRIPT_DIR/../queue)
#   LORD_ASK_TIMEOUT  — default timeout (default 86400s)
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANNEL_PY="${LORD_ASK_CHANNEL:-$SCRIPT_DIR/lib/lord_channel.py}"
QUEUE_DIR="${LORD_ASK_QUEUE_DIR:-$SCRIPT_DIR/../queue}"
TIMEOUT="${LORD_ASK_TIMEOUT:-86400}"

QUESTION=""
OPTIONS=()
TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --tag)     TAG="$2"; shift 2 ;;
        *) if [[ -z "$QUESTION" ]]; then QUESTION="$1"; else OPTIONS+=("$1"); fi; shift ;;
    esac
done

if [[ -z "$QUESTION" ]]; then
    echo "Usage: lord_ask.sh <question> [options] [--timeout <s>] [--tag <source>]" >&2
    exit 64
fi

# Mode gate: respect telegram.mode from settings.yaml.
SETTINGS="${LORD_ASK_SETTINGS:-$SCRIPT_DIR/../config/settings.yaml}"
TELEGRAM_MODE=$(grep -E "^[[:space:]]*mode:" "$SETTINGS" 2>/dev/null \
    | head -1 \
    | sed -E 's/^[[:space:]]*mode:[[:space:]]*"?([^"]+)"?/\1/' \
    | tr '[:upper:]' '[:lower:]')

# Terminal fallback for telegram.mode=off.
if [[ "$TELEGRAM_MODE" == "off" ]]; then
    if [[ ${#OPTIONS[@]} -gt 0 ]]; then
        echo "❓ $QUESTION"
        echo "Options:"
        i=0
        for opt in "${OPTIONS[@]}"; do
            echo "  $((i+1))) $opt"
            i=$((i+1))
        done
        echo -n "Your answer (number or text): "
    else
        echo "❓ $QUESTION"
        echo -n "Your answer: "
    fi
    read -r REPLY
    printf '%s' "$REPLY"
    exit 0
fi

# Build options CSV for the channel CLI.
OPTS_CSV=""
if [[ ${#OPTIONS[@]} -gt 0 ]]; then
    OPTS_CSV=$(IFS=','; echo "${OPTIONS[*]}")
fi

# Delegate to lord_channel.py. The channel owns the state file under
# flock; we just feed it inputs and read back outputs.
CHANNEL_OUTPUT=$(python3 "$CHANNEL_PY" ask \
    --queue-dir "$QUEUE_DIR" \
    --question "$QUESTION" \
    --options "$OPTS_CSV" \
    --timeout "$TIMEOUT" \
    ${TAG:+--tag "$TAG"})
RC=$?

case "$RC" in
    0)
        # Answered — print answer to stdout.
        printf '%s' "$CHANNEL_OUTPUT"
        exit 0
        ;;
    3)
        # Timeout — emit lord_question_timeout event into shogun inbox.
        echo "no answer; proceeding with default assumption"
        INBOX_FILE="$QUEUE_DIR/inbox/shogun.yaml"
        mkdir -p "$(dirname "$INBOX_FILE")"
        TS=$(date -Iseconds)
        REQUEST_ID="lord_ask_$(date +%s)-$$"
        printf -- '- id: %s\n  from: lord_ask\n  type: lord_question_timeout\n  timestamp: "%s"\n  read: false\n  question: "%s"\n' \
            "$REQUEST_ID" "$TS" "${QUESTION//\"/\\\"}" >> "$INBOX_FILE"
        exit 3
        ;;
    4)
        echo "lord_ask: another Lord question is already pending" >&2
        exit 4
        ;;
    *)
        echo "lord_ask: lord_channel.py exited $RC" >&2
        exit "$RC"
        ;;
esac
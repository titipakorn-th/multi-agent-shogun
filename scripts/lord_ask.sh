#!/usr/bin/env bash
# lord_ask.sh — AskQuestion → Telegram wrapper.
#
# Usage:
#   lord_ask.sh <question> [option1 option2 ...] [--timeout <seconds>]
#
# Behavior:
#   1. Generates a request_id.
#   2. Calls telegram_ask.py to send the question to Telegram and write
#      queue/current_question.json.
#   3. Polls current_question.json every 1 s for status=answered.
#   4. On success: prints the answer to stdout, clears the file, exits 0.
#   5. On timeout: prints "no answer; proceeding with default", emits a
#      lord_question_timeout event into queue/inbox/shogun.yaml, exits 3.
#   6. On Telegram not configured: prints message to stderr, exits 2.
#
# Test overrides:
#   LORD_ASK_PYTHON     — path to telegram_ask.py (default: $SCRIPT_DIR/telegram_ask.py)
#   LORD_ASK_QUEUE_DIR  — path to queue dir   (default: $SCRIPT_DIR/../queue)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELEGRAM_ASK="${LORD_ASK_PYTHON:-$SCRIPT_DIR/telegram_ask.py}"
QUEUE_DIR="${LORD_ASK_QUEUE_DIR:-$SCRIPT_DIR/../queue}"
QUESTION_FILE="$QUEUE_DIR/current_question.json"
TIMEOUT="${LORD_ASK_TIMEOUT:-86400}"
INBOX_FILE="$QUEUE_DIR/inbox/shogun.yaml"
mkdir -p "$(dirname "$INBOX_FILE")"

# PENDING_FILE — FIFO of questions waiting for the current one to resolve.
# Concurrent lord_ask.sh callers append here; the listener pops entries
# back into current_question.json after the active question is answered.
PENDING_FILE="${LORD_ASK_PENDING_FILE:-$QUEUE_DIR/pending_lord_questions.yaml}"
mkdir -p "$(dirname "$PENDING_FILE")"

enqueue_pending() {
    local request_id="$1"
    local question="$2"
    local opts_json="$3"
    local ts
    ts=$(date -Iseconds)
    # Append as a YAML list entry. Caller's options are passed as a JSON
    # array string (e.g. '["A","B"]') and emitted as a YAML inline list.
    # C2 fix: escape backslashes, then quotes, then literal newlines so
    # each mapping is exactly 4 lines. The newline escape (literal
    # backslash + n) is what pending_pop's `tail -n +5` and the
    # telegram_listener drain regex rely on. The Python drain side
    # unescapes \n -> real newline before sending to Telegram.
    local safe_question="${question//\\/\\\\}"   # backslashes first
    safe_question="${safe_question//\"/\\\"}"    # then double quotes
    safe_question="${safe_question//$'\n'/\\n}"  # then real LFs
    printf -- '- request_id: "%s"\n  question: "%s"\n  options: %s\n  timestamp: "%s"\n' \
        "$request_id" "$safe_question" "$opts_json" "$ts" >> "$PENDING_FILE"
}

# pending_first — returns the first YAML mapping block (6 lines) from the
# pending file, or 1 if the file is missing/empty. Used for inspection;
# the actual FIFO pop happens in the listener (telegram_listener.py).
pending_first() {
    [[ -f "$PENDING_FILE" ]] || return 1
    awk '/^- /{exit} {print}' "$PENDING_FILE" | head -n 6
}

# pending_pop — drops the first YAML mapping from the pending file and
# rewrites the file with the remainder. Useful for shell-side drain if
# the listener is not available. Each mapping is exactly 4 lines (the
# `- request_id:` line + 3 indented body lines), so `tail -n +5` is the
# cleanest FIFO pop. If enqueue_pending's printf format ever changes,
# update this too.
pending_pop() {
    [[ -f "$PENDING_FILE" ]] || return 1
    tail -n +5 "$PENDING_FILE" > "$PENDING_FILE.tmp"
    mv "$PENDING_FILE.tmp" "$PENDING_FILE"
}

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" \
      || "$TELEGRAM_BOT_TOKEN" == "your_bot_token_here" \
      || "$TELEGRAM_CHAT_ID" == "your_chat_id_here" ]]; then
    echo "Telegram not configured — falling back to terminal." >&2
    exit 2
fi

# Parse args
QUESTION=""
OPTIONS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) if [[ -z "$QUESTION" ]]; then QUESTION="$1"; else OPTIONS+=("$1"); fi; shift ;;
    esac
done

if [[ -z "$QUESTION" ]]; then
    echo "Usage: lord_ask.sh <question> [options] [--timeout <s>]" >&2
    exit 64
fi

REQUEST_ID="$(date +%s)-$(printf '%04x' $RANDOM)"

# Build telegram_ask.py args. Token + chat_id come from env (telegram_ask.py
# reads TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID itself, falling back to
# config/telegram.env). Passing --question-file / --chat-id / --token to
# telegram_ask.py would be rejected by its argparse as unknown flags.
ASK_ARGS=(--question "$QUESTION" --timeout "$TIMEOUT" --no-wait)
for o in "${OPTIONS[@]:-}"; do
    ASK_ARGS+=(--options "$o")
done

# If a question is already pending (current_question.json exists), enqueue
# ours and wait for our turn. When our turn arrives, the listener will
# have already written our entry into current_question.json with our
# request_id; we then call telegram_ask.py to send the question.
if [[ -f "$QUESTION_FILE" ]]; then
    OPTS_JSON="[]"
    if [[ ${#OPTIONS[@]} -gt 0 ]]; then
        OPTS_JSON=$(printf '"%s",' "${OPTIONS[@]}" | sed 's/,$//')
        OPTS_JSON="[$OPTS_JSON]"
    fi
    enqueue_pending "$REQUEST_ID" "$QUESTION" "$OPTS_JSON"
    # Wait for our turn: when QUESTION_FILE has our request_id, proceed.
    while true; do
        if [[ -f "$QUESTION_FILE" ]]; then
            CURRENT_RID=$(python3 -c "import json; print(json.load(open('$QUESTION_FILE')).get('request_id',''))" 2>/dev/null || echo "")
            if [[ "$CURRENT_RID" == "$REQUEST_ID" ]]; then
                break
            fi
        fi
        sleep 1
    done
    # Now send the question via telegram_ask.py.
fi

REQUEST_ID="$REQUEST_ID" python3 "$TELEGRAM_ASK" "${ASK_ARGS[@]}" \
    || { echo "ERROR: telegram_ask.py failed" >&2; exit 1; }

# Poll
START=$(date +%s)
while true; do
    NOW=$(date +%s)
    if [[ $((NOW - START)) -ge $TIMEOUT ]]; then
        echo "no answer; proceeding with default assumption"
        # Emit event to shogun inbox
        TS=$(date -Iseconds)
        printf -- '- id: %s\n  from: lord_ask\n  type: lord_question_timeout\n  timestamp: "%s"\n  read: false\n  question: "%s"\n' \
            "$REQUEST_ID" "$TS" "${QUESTION//\"/\\\"}" >> "$INBOX_FILE"
        exit 3
    fi
    if [[ -f "$QUESTION_FILE" ]]; then
        STATUS=$(python3 -c "import json; print(json.load(open('$QUESTION_FILE')).get('status',''))" 2>/dev/null || echo "")
        if [[ "$STATUS" == "answered" ]]; then
            ANSWER=$(python3 -c "import json; print(json.load(open('$QUESTION_FILE')).get('response',''))" 2>/dev/null || echo "")
            rm -f "$QUESTION_FILE"
            printf '%s' "$ANSWER"
            exit 0
        fi
    fi
    sleep 1
done

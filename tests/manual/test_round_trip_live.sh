#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# test_round_trip_live.sh — Manual live round-trip (Lord-driven)
# ═══════════════════════════════════════════════════════════════
# The W4 acceptance bar requires a live round-trip:
#   Lord question sent → answered via Telegram → resolved in queue.
#
# The automated bats test (test_w4c_round_trip.bats) verifies the state
# machine end-to-end without needing the real Telegram API. This
# script is the Lord-driven manual check that exercises the FULL
# pipeline including a real Telegram bot.
#
# Prerequisites:
#   - TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID in config/telegram.env
#   - Telegram bot is configured and reachable
#   - Lord is on the Telegram chat that the bot posts to
#
# Usage:
#   bash tests/manual/test_round_trip_live.sh "Pick yes or no" yes no
#
# Expected: a Telegram message appears with keyboard [yes] [no] [Other].
# Lord taps a button → bot receives callback → lord_ask.sh prints the
# answer and exits 0. This script prints that answer + the state
# transition log for Lord to paste into the W4 acceptance evidence.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <question> [option1 option2 ...]" >&2
    exit 1
fi

QUESTION="$1"
shift
OPTIONS=("$@")

echo "=== W4c live round-trip ==="
echo "Question: $QUESTION"
echo "Options: ${OPTIONS[*]:-none}"
echo "Started at: $(date -Iseconds)"

# Reset state file so this test starts clean.
rm -f "$PROJECT_ROOT/queue/current_question.json"

# Run lord_ask.sh with no timeout so Lord can take their time.
LORD_ASK_SETTINGS="$PROJECT_ROOT/config/settings.yaml" \
LORD_ASK_QUEUE_DIR="$PROJECT_ROOT/queue" \
timeout 600 bash "$PROJECT_ROOT/scripts/lord_ask.sh" "$QUESTION" "${OPTIONS[@]}" --timeout 600
rc=$?

echo "Ended at: $(date -Iseconds)"
echo "lord_ask exit code: $rc"

case "$rc" in
    0) echo "✅ Round-trip succeeded — Lord answered, answer above." ;;
    3) echo "⏱️  Round-trip timed out — Lord did not respond in time." ;;
    *) echo "❌ Round-trip failed — exit code $rc. Check logs/infra_liveness.log and queue/inbox/shogun.yaml." ;;
esac

echo ""
echo "=== State machine evidence ==="
if [ -f "$PROJECT_ROOT/queue/current_question.json" ]; then
    cat "$PROJECT_ROOT/queue/current_question.json"
else
    echo "(state file removed by cleanup_question_file on success)"
fi
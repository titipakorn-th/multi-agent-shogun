#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# inbox_backlog_alarm.sh — T5 backpressure alarm (W7)
# ═══════════════════════════════════════════════════════════════
# Emits a single distinct alarm line per agent whose `read: false` count
# exceeds --threshold (default 50). Distinct from per-message nudges — the
# alarm fires ONCE per invocation per agent, regardless of how far behind
# the consumer is.
#
# Usage:
#   bash scripts/inbox_backlog_alarm.sh                   # threshold=50
#   bash scripts/inbox_backlog_alarm.sh --threshold 100
#
# Exit codes:
#   0 — no agent over threshold
#   2 — at least one agent over threshold (alarm emitted on stderr)
#
# ponytail: a `grep -c "read: false"` per inbox file. No state, no caching,
# no queueing — this is a status check, not a flow control system. Add
# per-agent rate limiting when one consumer actually stalls behind another.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INBOX_DIR="$PROJECT_ROOT/queue/inbox"

THRESHOLD=50

while [ $# -gt 0 ]; do
    case "$1" in
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --help|-h) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -d "$INBOX_DIR" ]; then
    echo "inbox_backlog_alarm: $INBOX_DIR not found" >&2
    exit 1
fi

over_threshold=()

for inbox in "$INBOX_DIR"/*.yaml; do
    [ -f "$inbox" ] || continue
    base=$(basename "$inbox" .yaml)
    unread=$(grep -c "read: false" "$inbox" 2>/dev/null | head -1)
    if [ "${unread:-0}" -ge "$THRESHOLD" ]; then
        echo "[backlog_alarm] $base: $unread unread (threshold=$THRESHOLD)" >&2
        over_threshold+=("$base")
    fi
done

if [ "${#over_threshold[@]}" -gt 0 ]; then
    echo "inbox_backlog_alarm: ${#over_threshold[@]} agent(s) over threshold (${over_threshold[*]})" >&2
    exit 2
fi

echo "inbox_backlog_alarm: all inboxes under threshold ($THRESHOLD)"
exit 0
#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# inbox_watcher_decisions.sh — T7 extracted routing decisions (W5)
# ═══════════════════════════════════════════════════════════════
# Pure (no I/O, no side effects) decision functions extracted from the
# 1587-line inbox_watcher.sh monolith. The point of the split is test
# coverage, not behavior change: the daemon continues to source these
# functions and uses them identically to before.
#
# Functions:
#   decide_wakeup_action <unread_count> <is_busy> <throttled>
#     → emits "nudge" | "skip_busy" | "throttled" on stdout.
#   classify_inbox_change <before_count> <after_count>
#     → emits "new_message" | "all_read" | "no_change" on stdout.
#   compute_nudge_backoff <attempts>
#     → emits integer seconds to wait before next nudge.
#
# ponytail: pure functions. No globals, no file I/O. The daemon still
# owns the side effects (tmux send-keys, file locks); this file owns
# the decisions only. When the routing logic grows past ~10 functions,
# retire this and rewrite the daemon in Python.
# ═══════════════════════════════════════════════════════════════

# Decide what the watcher should do with a discovered unread count.
# Args: unread_count (int), is_busy (0|1), throttled (0|1)
# Emits one of: nudge | skip_busy | throttled
decide_wakeup_action() {
    local unread_count="$1"
    local is_busy="$2"
    local throttled="$3"

    if [ "${unread_count:-0}" -eq 0 ]; then
        echo "no_unread"
        return 0
    fi
    if [ "${is_busy:-0}" -eq 1 ]; then
        echo "skip_busy"
        return 0
    fi
    if [ "${throttled:-0}" -eq 1 ]; then
        echo "throttled"
        return 0
    fi
    echo "nudge"
}

# Classify the change between two inbox snapshots.
# Args: before_count, after_count (ints)
# Emits one of: new_message | all_read | no_change
classify_inbox_change() {
    local before="$1"
    local after="$2"

    if [ "${after:-0}" -gt "${before:-0}" ]; then
        echo "new_message"
    elif [ "${after:-0}" -eq 0 ]; then
        echo "all_read"
    else
        echo "no_change"
    fi
}

# Compute exponential-ish backoff in seconds for repeated nudges.
# Args: attempts (int). 0 → 0s, 1 → 5s, 2 → 15s, 3+ → 30s (cap).
compute_nudge_backoff() {
    local attempts="$1"
    case "${attempts:-0}" in
        0) echo 0 ;;
        1) echo 5 ;;
        2) echo 15 ;;
        *) echo 30 ;;
    esac
}
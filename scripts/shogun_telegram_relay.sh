#!/usr/bin/env bash
# shogun_telegram_relay.sh — tails the Shogun pane and pushes
# "### 📨 To Lord" blocks to Telegram.
#
# Started by shutsujin_departure.sh alongside the other watchers.
# Supervised by watcher_supervisor.sh.
#
# State: dedup hash ring at /tmp/shogun_telegram_relay_dedup_$(id -u).log
# Logs:  logs/telegram_relay_error.log
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shogun_telegram_relay_extract.sh
source "$SCRIPT_DIR/lib/shogun_telegram_relay_extract.sh"

TMUX_TARGET="${SHOGUN_TMUX_TARGET:-multiagent:0.0}"
POLL_INTERVAL="${SHOGUN_RELAY_POLL_INTERVAL:-2}"
PANE_HISTORY_LINES="${SHOGUN_RELAY_PANE_LINES:-200}"
DEDUP_LOG="/tmp/shogun_telegram_relay_dedup_$(id -u).log"
DEDUP_MAX=20
ERROR_LOG="$SCRIPT_DIR/../logs/telegram_relay_error.log"
mkdir -p "$(dirname "$ERROR_LOG")"

log_err() { echo "[$(date -Iseconds)] $*" >> "$ERROR_LOG"; }

# Trim dedup log to DEDUP_MAX entries (FIFO).
trim_dedup() {
    if [[ -f "$DEDUP_LOG" ]]; then
        tail -n "$DEDUP_MAX" "$DEDUP_LOG" > "$DEDUP_LOG.tmp" && mv "$DEDUP_LOG.tmp" "$DEDUP_LOG"
    fi
}

# already_sent <hash> -> exits 0 if hash is in dedup log
already_sent() {
    local h="$1"
    [[ -f "$DEDUP_LOG" ]] && grep -qx "$h" "$DEDUP_LOG"
}

record_sent() { echo "$1" >> "$DEDUP_LOG"; trim_dedup; }

main_loop() {
    while true; do
        # Capture pane (capture-pane -p prints to stdout).
        PANE="$(tmux capture-pane -t "$TMUX_TARGET" -p -S "-$PANE_HISTORY_LINES" 2>/dev/null || true)"
        if [[ -z "$PANE" ]]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        BLOCK="$(extract_lord_block "$PANE")"
        if [[ -z "$BLOCK" ]]; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        HASH="$(hash_block "$BLOCK")"
        if already_sent "$HASH"; then
            sleep "$POLL_INTERVAL"
            continue
        fi

        TRUNCATED="$(truncate_for_telegram "$BLOCK")"
        PUSH_TEXT="🏯 Shogun:
${TRUNCATED}"

        if bash "$SCRIPT_DIR/telegram_send.sh" "$PUSH_TEXT"; then
            record_sent "$HASH"
        else
            log_err "telegram_send.sh failed for hash $HASH"
        fi

        sleep "$POLL_INTERVAL"
    done
}

main_loop

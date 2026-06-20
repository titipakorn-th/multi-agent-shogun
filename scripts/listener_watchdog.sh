#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# listener_watchdog.sh — supervise the Telegram listener process
#
# Purpose:
#   The Telegram listener (scripts/telegram_listener.py) is the only channel
#   by which the Lord can wake the system when away from the terminal. If it
#   dies, the system appears dead on the phone side and there is no way to
#   recover without SSH access.
#
#   This watchdog polls the listener every POLL_INTERVAL seconds. If the
#   process is missing, it restarts the listener with exponential backoff.
#   If a pause sentinel file exists at queue/.listener_paused, the watchdog
#   does NOT restart the listener and exits cleanly.
#
# Restart policy:
#   - Backoff: 5s, 10s, 20s, 40s, 80s, 160s, 300s (capped at 5 min).
#   - Long-running uptime (>= STABLE_AFTER_SEC = 60s) resets the backoff.
#   - "Max restarts per hour" guard: 10 restarts in 60 minutes -> STOP and
#     alert via stderr + a row in logs/listener_restarts.log with reason
#     "max_restarts_exceeded". The operator must clear the pause sentinel
#     (or fix the underlying crash) and remove the alarm by deleting
#     logs/.listener_watchdog.disabled.
#
# Pause / resume:
#   The operator can deliberately stop the listener by:
#       touch queue/.listener_paused
#       pkill -f 'scripts/telegram_listener.py'
#   The watchdog will log "paused sentinel present" once and exit cleanly.
#   To resume:
#       rm queue/.listener_paused
#   The watchdog can then be relaunched (or the next cron tick restarts it).
#
# Idempotency:
#   - The watchdog uses flock on a lockfile so two simultaneous invocations
#     (e.g., a cron tick while the daemon is already running) never double-
#     supervise. The second invocation exits silently.
#   - The watchdog uses a single PID file (logs/listener.pid) for the
#     listener; if a stale PID file points to a dead process, the watchdog
#     treats the listener as down and clears the PID file before restart.
#
# How the watchdog is launched (chicken-and-egg):
#   The recommended deployment is to run the watchdog inside a tmux window
#   in the shogun-watchers session. depart.sh already creates
#   that session. See scripts/LISTENER_SUPERVISION.md for setup steps.
#
# Manual commands:
#   - Print status:           bash scripts/listener_watchdog.sh --status
#   - Pause listener:         touch queue/.listener_paused
#   - Resume listener:        rm queue/.listener_paused
#   - Clear backoff alarm:    rm logs/.listener_watchdog.disabled
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python3"
LISTENER="$SCRIPT_DIR/scripts/telegram_listener.py"
LOG_DIR="$SCRIPT_DIR/logs"
RESTART_LOG="$LOG_DIR/listener_restarts.log"
WATCHDOG_LOG="$LOG_DIR/listener_watchdog.log"
LISTENER_STDOUT="$LOG_DIR/telegram_listener.out"
LISTENER_STDERR="$LOG_DIR/telegram_listener.err"
PID_FILE="$LOG_DIR/listener.pid"
PAUSE_SENTINEL="$SCRIPT_DIR/queue/.listener_paused"
DISABLED_FLAG="$LOG_DIR/.listener_watchdog.disabled"

PROJECT_NAME=$(basename "$SCRIPT_DIR")
LOCKFILE="/tmp/listener_watchdog_${PROJECT_NAME}.lock"

# Tunables (override via env if needed)
POLL_INTERVAL="${LISTENER_WATCHDOG_POLL:-30}"
STABLE_AFTER_SEC="${LISTENER_WATCHDOG_STABLE_AFTER:-60}"
MAX_RESTARTS_PER_HOUR="${LISTENER_WATCHDOG_MAX_RESTARTS:-10}"
BACKOFF_INITIAL="${LISTENER_WATCHDOG_BACKOFF_INITIAL:-5}"
BACKOFF_MAX="${LISTENER_WATCHDOG_BACKOFF_MAX:-300}"
HOUR_WINDOW_SEC="${LISTENER_WATCHDOG_HOUR_WINDOW:-3600}"

mkdir -p "$LOG_DIR" "$SCRIPT_DIR/queue"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

ts() { date '+%Y-%m-%d %H:%M:%S'; }

# parse_etime — convert `ps -o etime=` output (e.g. "12:34:56", "1-02:03:04")
# into seconds. Returns 0 on parse failure.
parse_etime() {
    local e="$1"
    [ -z "$e" ] && { echo 0; return; }
    local days=0 hours=0 mins=0 secs=0
    if [[ "$e" == *-* ]]; then
        days="${e%%-*}"
        e="${e#*-}"
    fi
    # After optional days, expect hh:mm:ss or mm:ss.
    local IFS=":"
    read -r -a parts <<< "$e"
    case "${#parts[@]}" in
        3) hours="${parts[0]}"; mins="${parts[1]}"; secs="${parts[2]}" ;;
        2) mins="${parts[0]}"; secs="${parts[1]}" ;;
        1) secs="${parts[0]}" ;;
        *) echo 0; return ;;
    esac
    echo $(( days*86400 + hours*3600 + mins*60 + secs ))
}

log_restart() {
    printf '[%s] %s\n' "$(ts)" "$*" >> "$RESTART_LOG"
}

log_watchdog() {
    printf '[%s] [watchdog] %s\n' "$(ts)" "$*" >> "$WATCHDOG_LOG"
}

is_paused() {
    [ -f "$PAUSE_SENTINEL" ]
}

is_disabled() {
    [ -f "$DISABLED_FLAG" ]
}

# Returns 0 if the listener is running, non-zero otherwise. We verify by PID
# file first (precise), then by pgrep (catches the case where someone killed
# the listener via signal and the PID file is stale).
listener_is_alive() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            # Cross-check pgrep so a recycled PID doesn't trick us.
            if pgrep -f "${SCRIPT_DIR}/scripts/telegram_listener\.py" >/dev/null 2>&1; then
                return 0
            fi
        fi
        # Stale PID file — clear it.
        rm -f "$PID_FILE"
    fi
    pgrep -f "${SCRIPT_DIR}/scripts/telegram_listener\.py" >/dev/null 2>&1
}

# Trim a state file to the last HOUR_WINDOW_SEC of entries (one timestamp per
# line). Older lines are dropped. This is the "max restarts per hour" guard.
prune_restart_history() {
    local state_file="$1"
    [ -f "$state_file" ] || return 0
    local cutoff
    cutoff=$(( $(date +%s) - HOUR_WINDOW_SEC ))
    local tmp="${state_file}.tmp"
    awk -v cutoff="$cutoff" '
        {
            # Expect lines: "<unix_ts> <reason>"
            ts = $1 + 0
            if (ts >= cutoff) print
        }
    ' "$state_file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$state_file" 2>/dev/null || true
}

count_recent_restarts() {
    local state_file="$1"
    [ -f "$state_file" ] || { echo 0; return; }
    wc -l < "$state_file" | tr -d ' '
}

restart_listener() {
    local reason="$1"
    if is_paused; then
        log_watchdog "skip restart: pause sentinel present at $PAUSE_SENTINEL"
        return 1
    fi
    if is_disabled; then
        log_watchdog "skip restart: watchdog disabled flag at $DISABLED_FLAG"
        return 1
    fi
    if [ ! -x "$PYTHON_BIN" ]; then
        log_watchdog "FATAL: $PYTHON_BIN not executable; cannot start listener"
        return 1
    fi
    if [ ! -f "$LISTENER" ]; then
        log_watchdog "FATAL: listener script missing at $LISTENER"
        return 1
    fi

    # Clean up any leftover process. pkill is best-effort.
    pkill -f "${SCRIPT_DIR}/scripts/telegram_listener\.py" 2>/dev/null || true
    sleep 1

    # Spawn detached. nohup + & + disown, so the watchdog exit does not take
    # the listener down. PID is captured from $! right after nohup forks.
    nohup "$PYTHON_BIN" "$LISTENER" \
        >> "$LISTENER_STDOUT" 2>> "$LISTENER_STDERR" </dev/null &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$PID_FILE"

    log_restart "$(date +%s) $reason pid=$pid"
    log_watchdog "restarted listener pid=$pid reason=$reason"
    return 0
}

print_status() {
    if is_paused; then
        echo "listener: PAUSED (sentinel at $PAUSE_SENTINEL)"
    elif listener_is_alive; then
        local pid
        pid=$(pgrep -f "${SCRIPT_DIR}/scripts/telegram_listener\.py" | head -1)
        echo "listener: ALIVE pid=$pid"
    else
        echo "listener: DEAD"
    fi
    if is_disabled; then
        echo "watchdog: DISABLED (alarm at $DISABLED_FLAG)"
    fi
    if [ -f "$RESTART_LOG" ]; then
        echo "restarts logged: $(grep -c . "$RESTART_LOG" 2>/dev/null || echo 0)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main loop
# ─────────────────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--status" ]; then
    print_status
    exit 0
fi

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

# Single-instance guard. flock -n exits the script immediately if another copy
# is already running. This is what makes cron-driven + tmux-driven supervision
# safe to overlap.
exec 9>"$LOCKFILE" || {
    echo "[watchdog] cannot open lockfile $LOCKFILE" >&2
    exit 1
}
if ! flock -n 9; then
    log_watchdog "another instance already running; exiting"
    exit 0
fi

log_watchdog "watchdog started poll=${POLL_INTERVAL}s max_restarts=${MAX_RESTARTS_PER_HOUR}/hour"

# Backoff state — kept in-memory only. If the watchdog restarts (e.g., cron
# tick), backoff resets. That is fine because the max-restarts-per-hour guard
# is the durable circuit breaker.
backoff="$BACKOFF_INITIAL"
last_start_ts=""

# Restart history file (one timestamp per line, oldest pruned hourly).
RESTART_STATE="$LOG_DIR/.listener_watchdog.restarts"
: > "$RESTART_STATE" 2>/dev/null || true

while true; do
    if is_paused; then
        log_watchdog "pause sentinel present; exiting cleanly"
        # We exit rather than loop-and-sleep so cron can re-evaluate later.
        exit 0
    fi

    if listener_is_alive; then
        # If the listener has been up long enough to be considered stable,
        # reset the backoff so the NEXT crash starts a fresh 5s interval.
        local_pid=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ -n "$local_pid" ]; then
            etime=$(ps -o etime= -p "$local_pid" 2>/dev/null | tr -d ' ' || true)
            uptime_s=$(parse_etime "$etime")
            if [ -n "$uptime_s" ] && [ "$uptime_s" -ge "$STABLE_AFTER_SEC" ] 2>/dev/null; then
                backoff="$BACKOFF_INITIAL"
            fi
        fi
        sleep "$POLL_INTERVAL"
        continue
    fi

    # Listener is dead. Apply max-restarts-per-hour guard.
    prune_restart_history "$RESTART_STATE"
    recent=$(count_recent_restarts "$RESTART_STATE")
    if [ "$recent" -ge "$MAX_RESTARTS_PER_HOUR" ] 2>/dev/null; then
        log_watchdog "ALARM: $recent restarts in last $HOUR_WINDOW_SEC sec (limit=$MAX_RESTARTS_PER_HOUR). Setting disabled flag."
        log_restart "$(date +%s) max_restarts_exceeded recent=$recent"
        touch "$DISABLED_FLAG"
        # Stop trying until the operator clears the flag.
        exit 1
    fi

    # Log the attempt and restart.
    echo "$(date +%s)" >> "$RESTART_STATE"
    log_watchdog "listener is down; sleeping backoff=${backoff}s before restart"
    sleep "$backoff"

    # Re-check pause sentinel after the backoff sleep — operator may have
    # paused us while we were waiting.
    if is_paused; then
        log_watchdog "pause sentinel appeared during backoff; not restarting"
        exit 0
    fi

    if ! restart_listener "watchdog_backoff_${backoff}s"; then
        # Could not restart (e.g., python missing). Increase backoff and try
        # again next loop.
        backoff=$(( backoff * 2 ))
        [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff="$BACKOFF_MAX"
        continue
    fi

    # Successful restart — bump backoff for the next failure.
    backoff=$(( backoff * 2 ))
    [ "$backoff" -gt "$BACKOFF_MAX" ] && backoff="$BACKOFF_MAX"

    sleep "$POLL_INTERVAL"
done

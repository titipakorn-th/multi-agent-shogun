#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# infra_liveness.sh — T2 infra liveness check (W3)
# ═══════════════════════════════════════════════════════════════
# Verifies that the delivery-layer daemons (inbox_watcher + team_monitor)
# are alive for the current tmux session. If a daemon is missing, attempts
# a best-effort relaunch. Logs results to logs/infra_liveness.log.
#
# Usage:
#   bash scripts/infra_liveness.sh              # check + relaunch (default)
#   bash scripts/infra_liveness.sh --check-only # just report, do not relaunch
#
# Exit codes:
#   0 — all daemons healthy (or relaunched successfully)
#   1 — usage error
#   2 — at least one daemon missing AND could not be relaunched
#
# ponytail: a `pgrep -f` check + a `nohup` relaunch. The watcher writes its
# own pid file; team_monitor keeps no pid file, so we scan by command line.
# When a real process supervisor (systemd, supervisord) takes over, retire
# this script.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_ROOT/logs"
LOG_FILE="$LOG_DIR/infra_liveness.log"
mkdir -p "$LOG_DIR"

CHECK_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1; shift ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

log_line() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

is_alive() {
    local pattern="$1"
    pgrep -f "$pattern" >/dev/null 2>&1
}

relaunch() {
    local label="$1"
    local cmd="$2"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        log_line "MISSING (no relaunch, check-only): $label"
        return 1
    fi
    log_line "RELAUNCH: $label — $cmd"
    # nohup + setsid + & so the daemon survives this script's exit.
    # Detach from controlling terminal so SIGHUP doesn't reach it.
    (
        nohup setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
    )
    # Brief wait for the process to register.
    sleep 1
    return 0
}

missing=()

# 1. inbox_watcher.sh — running for the current session (or any session).
if is_alive "bash scripts/inbox_watcher.sh"; then
    log_line "OK: inbox_watcher is alive"
else
    log_line "MISSING: inbox_watcher not running"
    missing+=("inbox_watcher")
    relaunch "inbox_watcher" "cd '$PROJECT_ROOT' && bash scripts/inbox_watcher.sh >> '$LOG_DIR/inbox_watcher.log' 2>&1"
fi

# 2. team_monitor.sh — daemon or cron. If neither, relaunch --daemon.
if is_alive "bash scripts/team_monitor.sh"; then
    log_line "OK: team_monitor is alive"
else
    log_line "MISSING: team_monitor not running"
    missing+=("team_monitor")
    relaunch "team_monitor" "cd '$PROJECT_ROOT' && bash scripts/team_monitor.sh --daemon >> '$LOG_DIR/team_monitor.log' 2>&1"
fi

if [ "${#missing[@]}" -eq 0 ]; then
    echo "infra_liveness: all daemons healthy"
    exit 0
fi

# Report what was missing and whether relaunch succeeded.
for d in "${missing[@]}"; do
    if is_alive "bash scripts/${d}.sh"; then
        echo "infra_liveness: RELAUNCHED $d"
        log_line "RELAUNCHED: $d"
    else
        echo "infra_liveness: STILL MISSING $d (see $LOG_FILE)"
        log_line "STILL MISSING: $d"
    fi
done

# Exit 2 if anything is still missing.
still=()
for d in "${missing[@]}"; do
    if ! is_alive "bash scripts/${d}.sh"; then still+=("$d"); fi
done
[ "${#still[@]}" -gt 0 ] && exit 2 || exit 0
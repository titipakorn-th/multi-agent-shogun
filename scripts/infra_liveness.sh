#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# infra_liveness.sh — Round-4 corrected: singleton-only + dormant-aware
# ═══════════════════════════════════════════════════════════════
# Round-3 review found this script was trying to relaunch inbox_watcher
# without the required <agent> <pane> <cli> args, so every "relaunch" died
# in <1s. inbox_watcher is per-pane (one process per agent tmux pane);
# the proper owner is scripts/watcher_supervisor.sh, NOT liveness.
#
# This script now owns only TRUE SINGLETON daemons:
#   - watcher_supervisor (per-pane inbox watchers; singleton coordinator)
#   - listener_watchdog (telegram listener supervisor)
#
# And it distinguishes DORMANT (no tmux server / no agent panes) from
# CRASHED (singletons missing while fleet is up):
#   - tmux server absent → "system at rest", exit 0, no alarm
#   - tmux server present but no agent panes → still at-rest
#   - tmux server present, panes exist, singleton missing → alarm
#
# Usage:
#   bash scripts/infra_liveness.sh           # check + relaunch missing singletons
#   bash scripts/infra_liveness.sh --check-only
#
# Exit codes:
#   0 — at rest OR all singletons healthy (or relaunched successfully)
#   2 — at least one singleton missing AND could not be relaunched
#
# ponytail: this file dropped from "two daemons" to "one daemon" because
# the two-owner model was wrong. Watcher supervision is per-pane and lives
# in watcher_supervisor.sh. When a singleton truly needs split (e.g. a
# second external probe daemon), add it here — not a sixth coordinator.
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
        --help|-h) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

log_line() { echo "[$(date -Iseconds)] $*" >> "$LOG_FILE"; }

is_alive() { pgrep -f "$1" >/dev/null 2>&1; }

relaunch() {
    local label="$1"
    local cmd="$2"
    if [ "$CHECK_ONLY" -eq 1 ]; then
        log_line "MISSING (no relaunch, check-only): $label"
        return 1
    fi
    log_line "RELAUNCH: $label — $cmd"
    (
        nohup setsid bash -c "$cmd" </dev/null >/dev/null 2>&1 &
    )
    sleep 1
    return 0
}

# ─── Detect fleet state ───
# Active fleet = tmux server running AND at least one pane exists.
# Anything less = dormant = no liveness work to do.
fleet_active=0
if tmux list-sessions >/dev/null 2>&1; then
    pane_count=$(tmux list-panes -a 2>/dev/null | wc -l | tr -d ' ')
    if [ "${pane_count:-0}" -gt 0 ]; then
        fleet_active=1
    fi
fi

if [ "$fleet_active" -eq 0 ]; then
    log_line "system at rest (no tmux panes); singleton checks skipped"
    echo "infra_liveness: system at rest — singleton checks skipped"
    exit 0
fi

log_line "fleet active ($pane_count pane(s)); checking singletons"

missing=()

# 1. watcher_supervisor.sh — singleton coordinator of per-pane watchers.
# Z1 round-5 closes the gap X1 opened: the supervisor was the named owner
# of per-pane watchers but itself had no guarantor. If it dies, every
# per-pane watcher goes unsupervised.
# ponytail: supervisor is a singleton; if multi-session ever splits it,
# revisit. ~5 lines, same shape as the other singletons here.
if is_alive "bash scripts/watcher_supervisor.sh"; then
    log_line "OK: watcher_supervisor is alive"
else
    log_line "MISSING: watcher_supervisor not running"
    missing+=("watcher_supervisor")
    relaunch "watcher_supervisor" "cd '$PROJECT_ROOT' && bash scripts/watcher_supervisor.sh >> '$LOG_DIR/watcher_supervisor.log' 2>&1"
fi

# 2. listener_watchdog.sh — supervises telegram_listener.py (auto_prompt
# trigger caller). Scripts/LISTENER_SUPERVISION.md says the canonical
# launcher is depart.sh's tmux window, but if the tmux server is down
# the watchdog dies too — leaving the listener permanently un-supervised
# (which is exactly the bug the watchdog exists to prevent). Adding it
# here as a singleton closes that gap with the same shape as the other
# two. The watchdog's own flock + pause-sentinel logic means double-launch
# is safe. ponytail: same pattern; revisit if watchdog ever splits.
if is_alive "bash scripts/listener_watchdog.sh"; then
    log_line "OK: listener_watchdog is alive"
else
    log_line "MISSING: listener_watchdog not running"
    missing+=("listener_watchdog")
    relaunch "listener_watchdog" "cd '$PROJECT_ROOT' && exec bash scripts/listener_watchdog.sh >> '$LOG_DIR/listener_watchdog.log' 2>&1"
fi

# inbox_watcher is NOT managed here. See scripts/watcher_supervisor.sh.
# Round-3 audit found this script's relaunch was malformed (no args);
# supervisor already owns per-pane watcher lifecycle (and now supervisor
# itself has infra_liveness as its guarantor, per Z1).

if [ "${#missing[@]}" -eq 0 ]; then
    echo "infra_liveness: all singletons healthy"
    exit 0
fi

for d in "${missing[@]}"; do
    if is_alive "bash scripts/${d}.sh"; then
        echo "infra_liveness: RELAUNCHED $d"
        log_line "RELAUNCHED: $d"
    else
        echo "infra_liveness: STILL MISSING $d (see $LOG_FILE)"
        log_line "STILL MISSING: $d"
    fi
done

still=()
for d in "${missing[@]}"; do
    if ! is_alive "bash scripts/${d}.sh"; then still+=("$d"); fi
done
[ "${#still[@]}" -gt 0 ] && exit 2 || exit 0
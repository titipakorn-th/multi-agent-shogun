#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# cleanup.sh — Tear down the v2 specialist-team tmux topology
#
# Kills the two sessions created by depart.sh so it can be re-run
# cleanly. Use this when:
#   - depart.sh's idempotency skips a config change (e.g. new CLI flag)
#   - pane layout/state is wedged
#   - you want a fresh start
#
# Pair with: cleanup.sh && ./depart.sh
# ═══════════════════════════════════════════════════════════════

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/scripts/shutsujin_v2_constants.sh" 2>/dev/null || true

SESSIONS=("${SHOGUN_SESSION:-shogun}" "${MULTIAGENT_SESSION:-multiagent}")

# ponytail: -t "=$s" forces exact-name match. Without '=', tmux falls back
# from exact → unique-prefix → substring, so `tmux has-session -t shogun`
# reports success for `shogun_safepay` (other project) when only that
# suffixed session exists, and the kill below murders the wrong project.
for s in "${SESSIONS[@]}"; do
    if tmux has-session -t "=$s" 2>/dev/null; then
        tmux kill-session -t "=$s"
        echo "[cleanup] killed session: $s"
    else
        echo "[cleanup] no session: $s (skipped)"
    fi
done

# Kill inbox_watcher.sh instances tied to THIS project. Discriminator:
# tmux pane target always has form `<session>:<window>.<pane>` (e.g.
# `shogun:main.0`, `multiagent_safepay:ops.0`). Match the literal
# `<session>:` substring so a sibling session like
# `multiagent_safepay:ops.0` does NOT match this project's
# `multiagent:` (the `_safepay` between `multiagent` and `:` breaks the
# substring). Without this cleanup, watchers outlive their sessions
# and try to nudge dead panes on every poll.
#
# Why basename pgrep (not absolute path): watcher_supervisor.sh spawns
# children as `bash scripts/inbox_watcher.sh ...` (relative path), so
# pgrep by absolute SCRIPT_DIR misses our OWN watchers. Session-name
# anchor is the real safety guarantee.
#
# DO NOT kill watcher_supervisor.sh: it is the respawn mechanism that
# brings inbox_watcher.sh instances back when they die. Killing it
# leaves the system unable to recover from future watcher crashes.
# The supervisor's own cycle will detect any watcher we just killed
# and respawn it on its next poll.
SESSION_REGEX="($(printf '%s:|' "${SESSIONS[@]}" | sed 's/|$//'))"
pattern="scripts/inbox_watcher.sh"
pids=$(pgrep -f "${pattern}" 2>/dev/null || true)
scoped_pids=""
if [[ -n "$pids" ]]; then
    for pid in $pids; do
        cmdline=$(ps -p "$pid" -o args= 2>/dev/null || true)
        if [[ "$cmdline" =~ $SESSION_REGEX ]]; then
            scoped_pids+="$pid "
        fi
    done
fi
scoped_pids="${scoped_pids% }"
if [[ -n "$scoped_pids" ]]; then
    echo "$scoped_pids" | xargs kill 2>/dev/null || true
    echo "[cleanup] killed $pattern: $scoped_pids"
else
    echo "[cleanup] no $pattern matching our sessions (skipped)"
fi

# Verify this project's supervisor is alive — it's the only thing that
# brings the killed watchers back. If absent, start one so the system
# self-heals before the user notices.
#
# Discriminator: the supervisor has THIS project's watcher_supervisor.sh
# open (via lsof). The supervisor's own cmdline is just
# `bash scripts/watcher_supervisor.sh` (no absolute path, no session
# name), so pgrep+cmdline cannot distinguish sibling projects. The open
# script's absolute path is the reliable anchor.
supervisor_running=0
for pid in $(pgrep -f "scripts/watcher_supervisor.sh" 2>/dev/null || true); do
    if lsof -p "$pid" 2>/dev/null | grep -q "${SCRIPT_DIR}/scripts/watcher_supervisor.sh"; then
        supervisor_running=1
        echo "[cleanup] supervisor alive for this project: PID=$pid"
        break
    fi
done
if [[ "$supervisor_running" -eq 0 ]]; then
    if [[ -x "${SCRIPT_DIR}/scripts/watcher_supervisor.sh" ]]; then
        mkdir -p "${SCRIPT_DIR}/logs"
        nohup bash "${SCRIPT_DIR}/scripts/watcher_supervisor.sh" \
            >"${SCRIPT_DIR}/logs/watcher_supervisor.log" 2>&1 &
        echo "[cleanup] started watcher_supervisor.sh (PID=$!) — will respawn killed watchers"
    else
        echo "[cleanup] WARN: no watcher_supervisor.sh for this project; killed watchers will NOT auto-respawn"
    fi
fi

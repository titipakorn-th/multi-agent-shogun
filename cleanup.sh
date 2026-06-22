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

# Kill inbox_watcher.sh + watcher_supervisor.sh instances tied to THIS
# project. Discriminator: tmux pane target always has form `<session>:
# <window>.<pane>` (e.g. `shogun:main.0`, `multiagent_safepay:ops.0`).
# Match the literal `<session>:` substring so a sibling session like
# `multiagent_safepay:ops.0` does NOT match this project's `multiagent:`
# (the `_safepay` between `multiagent` and `:` breaks the substring).
# Without this cleanup, watchers outlive their sessions and try to
# nudge dead panes on every poll.
#
# Why basename pgrep (not absolute path): watcher_supervisor.sh spawns
# children as `bash scripts/inbox_watcher.sh ...` (relative path), so
# pgrep by absolute SCRIPT_DIR misses our OWN watchers. Session-name
# anchor is the real safety guarantee.
SESSION_REGEX="($(printf '%s:|' "${SESSIONS[@]}" | sed 's/|$//'))"
for pattern in "scripts/inbox_watcher.sh" "scripts/watcher_supervisor.sh"; do
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
done

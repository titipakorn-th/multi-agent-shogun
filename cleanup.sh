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

for s in "${SESSIONS[@]}"; do
    if tmux has-session -t "$s" 2>/dev/null; then
        tmux kill-session -t "$s"
        echo "[cleanup] killed session: $s"
    else
        echo "[cleanup] no session: $s (skipped)"
    fi
done

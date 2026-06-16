#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# shutsujin_departure_v2.sh — V2 specialist-team topology
# Creates 9 panes across 3 sessions/windows:
#   - shogun session: 1 pane (shogun)
#   - multiagent session, ops window: orchestrator, fixer, designer, observer
#   - multiagent session, research window: explorer, librarian, oracle, council
# ═══════════════════════════════════════════════════════════════

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${SCRIPT_DIR}/scripts/shutsujin_v2_constants.sh"

set -u

CLI_DEFAULT="${CLI_DEFAULT:-claude}"

# ─── Phase 1: Shogun session (existing) ──────────────────────
if ! tmux has-session -t shogun 2>/dev/null; then
    tmux new-session -d -s shogun -n main
    tmux set-option -p -t shogun:main.0 @agent_id "shogun"
    tmux select-pane -t shogun:main.0 -T "shogun"
    tmux select-pane -t shogun:main.0 -P "bg=#002b36"
fi

# ─── Phase 2: Multiagent session with two windows ────────────
if ! tmux has-session -t multiagent 2>/dev/null; then
    tmux new-session -d -s multiagent -n ops
    tmux new-window -t multiagent -n research
fi

echo "[shutsujin_v2] topology ready"
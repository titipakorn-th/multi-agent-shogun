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

# ─── Pane creation helper ────────────────────────────────────
# Usage: start_specialist_pane <role> <session> <window> <pane_index> <model> <color> <cli>
#
# Idempotent: if a pane already exists at <pane_index> with the expected
# @agent_id, this is a no-op. Otherwise split-window and configure.
start_specialist_pane() {
    local role=$1 session=$2 window=$3 pane_idx=$4 model=$5 color=$6 cli=$7
    local target="${session}:${window}.${pane_idx}"

    # Check if a pane already exists at the target index with the correct role
    local existing
    existing=$(tmux list-panes -t "${session}:${window}" -F '#{pane_index}:#{@agent_id}' \
        2>/dev/null | sed -n "$((pane_idx + 1))p" || true)
    local expected="${pane_idx}:${role}"
    if [ "$existing" = "$expected" ]; then
        return 0
    fi

    # Split pane if not pane 0
    if [ "$pane_idx" -gt 0 ]; then
        tmux split-window -h -t "${session}:${window}"
    fi

    # Set agent_id and styling
    tmux set-option -p -t "$target" @agent_id "$role"
    tmux select-pane -t "$target" -T "$role"
    tmux select-pane -t "$target" -P "bg=${color}"

    # Launch CLI
    tmux send-keys -t "$target" "${cli} --model ${model}" Enter
}

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

# ─── Phase 3: Ops window panes ───────────────────────────────
# Idempotency: count existing panes; if window already has 4 correctly
# configured panes, skip. If it has MORE than 4 panes, warn and skip
# (caller should reset via tmux kill-session).
OPS_EXISTING=$(tmux list-panes -t multiagent:ops 2>/dev/null | wc -l | tr -d ' ')
if [ "${OPS_EXISTING:-0}" -eq 4 ]; then
    echo "[shutsujin_v2] ops window: 4 panes already configured"
elif [ "${OPS_EXISTING:-0}" -gt 4 ]; then
    echo "[shutsujin_v2] WARNING: ops has $OPS_EXISTING panes (>4). Run on a fresh session." >&2
else
    OPS_ROLES=("orchestrator" "fixer" "designer" "observer")
    for idx in "${!OPS_ROLES[@]}"; do
        role="${OPS_ROLES[$idx]}"
        start_specialist_pane "$role" "multiagent" "ops" "$idx" \
            "$(v2_model_for "$role")" \
            "$(v2_color_for "$role")" \
            "$CLI_DEFAULT"
    done
fi

# ─── Phase 4: Research window panes ──────────────────────────
RESEARCH_EXISTING=$(tmux list-panes -t multiagent:research 2>/dev/null | wc -l | tr -d ' ')
if [ "${RESEARCH_EXISTING:-0}" -eq 4 ]; then
    echo "[shutsujin_v2] research window: 4 panes already configured"
elif [ "${RESEARCH_EXISTING:-0}" -gt 4 ]; then
    echo "[shutsujin_v2] WARNING: research has $RESEARCH_EXISTING panes (>4). Run on a fresh session." >&2
else
    RESEARCH_ROLES=("explorer" "librarian" "oracle" "council")
    for idx in "${!RESEARCH_ROLES[@]}"; do
        role="${RESEARCH_ROLES[$idx]}"
        start_specialist_pane "$role" "multiagent" "research" "$idx" \
            "$(v2_model_for "$role")" \
            "$(v2_color_for "$role")" \
            "$CLI_DEFAULT"
    done
fi

echo "[shutsujin_v2] topology ready"

# ─── Phase 5: inbox_watcher launch ───────────────────────────
WATCHER="${SCRIPT_DIR}/scripts/inbox_watcher.sh"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

for role in $(v2_role_list); do
    pane_target="$(v2_pane_for "$role")"
    # Skip if watcher is already running for this role
    if ! pgrep -f "inbox_watcher.sh ${role} " >/dev/null 2>&1 \
       && ! pgrep -f "inbox_watcher.sh ${role}\$" >/dev/null 2>&1; then
        nohup bash "$WATCHER" "$role" "$pane_target" "$CLI_DEFAULT" \
            >"${LOG_DIR}/inbox_watcher_${role}.log" 2>&1 &
    fi
done

echo "[shutsujin_v2] watchers launched"
#!/usr/bin/env bash
# Shared agent formation helpers.
#
# `cli.agents` historically served both as per-agent CLI overrides and as the
# runtime formation list.  The default formation is the v2 specialist team
# (shogun + orchestrator + 7 specialists).  The orchestrator is the sentinel
# that marks a parsed list as a v2 formation.

AGENT_REGISTRY_PROJECT_ROOT="${AGENT_REGISTRY_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AGENT_REGISTRY_SETTINGS="${AGENT_REGISTRY_SETTINGS:-${SHOGUN_SETTINGS_FILE:-${AGENT_REGISTRY_PROJECT_ROOT}/config/settings.yaml}}"

# Source v2 pane mapping (bash-3.2 compatible case-statement lookups)
# shellcheck disable=SC1091
. "${AGENT_REGISTRY_PROJECT_ROOT}/scripts/shutsujin_v2_constants.sh" 2>/dev/null || true

# Default v2 formation: shogun + orchestrator + 7 specialists (deterministic order)
agent_registry_default_agents() {
    printf '%s\n' \
        shogun \
        orchestrator \
        explorer \
        librarian \
        oracle \
        designer \
        fixer \
        observer \
        council
}

agent_registry_read_agents_from_settings() {
    local settings="${1:-$AGENT_REGISTRY_SETTINGS}"
    [ -f "$settings" ] || return 0

    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }

        /^cli:[[:space:]]*$/ {
            in_cli = 1
            in_agents = 0
            next
        }

        in_cli && /^[^[:space:]]/ {
            in_cli = 0
            in_agents = 0
        }

        in_cli && /^[[:space:]]{2}agents:[[:space:]]*$/ {
            in_agents = 1
            next
        }

        in_agents {
            if ($0 !~ /^[[:space:]]{4}/) {
                exit
            }
            if ($0 ~ /^[[:space:]]{4}[A-Za-z0-9_-]+:[[:space:]]*/) {
                line = $0
                sub(/^[[:space:]]*/, "", line)
                sub(/:.*/, "", line)
                print line
            }
        }
    ' "$settings"
}

agent_registry_has_agent() {
    local wanted="$1"
    shift || true
    local agent
    for agent in "$@"; do
        [ "$agent" = "$wanted" ] && return 0
    done
    return 1
}

agent_registry_agents() {
    local parsed=()
    local agent

    while IFS= read -r agent; do
        [ -n "$agent" ] && parsed+=("$agent")
    done < <(agent_registry_read_agents_from_settings "$AGENT_REGISTRY_SETTINGS")

    if [ "${#parsed[@]}" -eq 0 ] || ! agent_registry_has_agent "orchestrator" "${parsed[@]}"; then
        agent_registry_default_agents
        return 0
    fi

    if ! agent_registry_has_agent "shogun" "${parsed[@]}"; then
        printf '%s\n' shogun
    fi
    printf '%s\n' "${parsed[@]}"
}

agent_registry_multiagent_agents() {
    local agent
    while IFS= read -r agent; do
        [ "$agent" = "shogun" ] && continue
        printf '%s\n' "$agent"
    done < <(agent_registry_agents)
}

# Pane target for a multiagent (non-shogun) agent.
# In v2, the layout is split across two windows (ops + research); resolve
# via the v2 pane mapping.  Fall back to a generic `multiagent:agents.N`
# only if the v2 lookup table is unavailable.
agent_registry_multiagent_pane_for_agent() {
    local wanted="$1"
    local pane_base="${2:-0}"
    local agent
    local idx=0

    while IFS= read -r agent; do
        if [ "$agent" = "$wanted" ]; then
            # Prefer the v2 layout if available
            if declare -f v2_pane_for >/dev/null 2>&1; then
                local v2_target
                v2_target=$(v2_pane_for "$wanted")
                if [ -n "$v2_target" ]; then
                    printf '%s\n' "$v2_target"
                    return 0
                fi
            fi
            # Fallback: positional layout (legacy fallback)
            printf 'multiagent:agents.%s\n' "$((pane_base + idx))"
            return 0
        fi
        idx=$((idx + 1))
    done < <(agent_registry_multiagent_agents)

    return 1
}

agent_registry_pane_for_agent() {
    local agent="$1"
    local pane_base="${2:-0}"

    if [ "$agent" = "shogun" ]; then
        printf 'shogun:main.%s\n' "$pane_base"
        return 0
    fi

    if [ "$agent" = "telegram" ]; then
        printf 'telegram:main.%s\n' "$pane_base"
        return 0
    fi

    agent_registry_multiagent_pane_for_agent "$agent" "$pane_base"
}

# ─── Layer classification (v2) ───────────────────────────────
# command-layer = receives high-level commands and dispatches (orchestrator)
# analysis-layer = does deep analysis / evaluation (oracle, council)
# task-layer = does bounded work (explorer, librarian, designer, fixer, observer)
command_layer_agents() { echo "orchestrator"; }
analysis_layer_agents() { echo "oracle council"; }
task_layer_agents() { echo "explorer librarian designer fixer observer"; }

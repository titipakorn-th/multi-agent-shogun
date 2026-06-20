#!/usr/bin/env bash
# Constants for the v2 (specialist team) topology.
# Source this from depart.sh.
#
# NOTE: This file is intentionally bash-3.2 compatible (associative arrays
# are a bash-4.0 feature). On macOS the system /bin/bash is still 3.2.
# We provide the same role→{pane,model,color} lookups via case statements.

# ─── Read role list in deterministic order ───────────────────
v2_role_list() {
    echo "shogun orchestrator explorer librarian oracle designer fixer observer council"
}

# ─── Dynamic tmux session suffix detection ───────────────────
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    CONSTANTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT_DIR="$(cd "${CONSTANTS_DIR}/.." && pwd)"
elif [ -n "${AGENT_REGISTRY_PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT_DIR="$AGENT_REGISTRY_PROJECT_ROOT"
elif [ -n "${PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT_DIR="$PROJECT_ROOT"
else
    PROJECT_ROOT_DIR="$(pwd)"
fi

PROJECT_DIR_NAME=$(basename "$PROJECT_ROOT_DIR")

# Determine suffix from setting in settings.yaml if present, otherwise auto-detect
TMUX_SUFFIX_SETTING="auto"
if [ -f "${PROJECT_ROOT_DIR}/config/settings.yaml" ]; then
    TMUX_SUFFIX_SETTING=$(grep "^tmux_session_suffix:" "${PROJECT_ROOT_DIR}/config/settings.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"'\'' ' || echo "auto")
fi

SHOGUN_SUFFIX=""
if [ "$TMUX_SUFFIX_SETTING" != "auto" ] && [ -n "$TMUX_SUFFIX_SETTING" ]; then
    SHOGUN_SUFFIX="$TMUX_SUFFIX_SETTING"
else
    if echo "$PROJECT_DIR_NAME" | grep -qE '^multi-agent-shogun[-_].+'; then
        SHOGUN_SUFFIX="_$(echo "$PROJECT_DIR_NAME" | sed -E 's/^multi-agent-shogun[-_]//')"
    elif [ "$PROJECT_DIR_NAME" != "multi-agent-shogun" ]; then
        SHOGUN_SUFFIX="_$PROJECT_DIR_NAME"
    fi
fi

SHOGUN_SESSION="shogun${SHOGUN_SUFFIX}"
MULTIAGENT_SESSION="multiagent${SHOGUN_SUFFIX}"

# ─── Read pane target for a role ─────────────────────────────
v2_pane_for() {
    local role=$1
    case "$role" in
        shogun)        echo "${SHOGUN_SESSION}:main.0" ;;
        orchestrator)  echo "${MULTIAGENT_SESSION}:ops.0" ;;
        fixer)         echo "${MULTIAGENT_SESSION}:ops.1" ;;
        designer)      echo "${MULTIAGENT_SESSION}:ops.2" ;;
        observer)      echo "${MULTIAGENT_SESSION}:ops.3" ;;
        explorer)      echo "${MULTIAGENT_SESSION}:research.0" ;;
        librarian)     echo "${MULTIAGENT_SESSION}:research.1" ;;
        oracle)        echo "${MULTIAGENT_SESSION}:research.2" ;;
        council)       echo "${MULTIAGENT_SESSION}:research.3" ;;
        *)             echo "" ;;
    esac
}

# ─── Read model for a role ───────────────────────────────────
v2_model_for() {
    local role=$1
    case "$role" in
        shogun|orchestrator|oracle|council) echo "opus" ;;
        explorer)                          echo "haiku" ;;
        librarian|designer|fixer|observer) echo "sonnet" ;;
        *)                                 echo "sonnet" ;;
    esac
}

# ─── Read color for a role ───────────────────────────────────
v2_color_for() {
    local role=$1
    case "$role" in
        shogun)        echo "#002b36" ;;
        orchestrator)  echo "#501515" ;;
        fixer)         echo "#1e3a1e" ;;
        designer)      echo "#3a1e3a" ;;
        observer)      echo "#1e3a3a" ;;
        explorer)      echo "#454510" ;;
        librarian)     echo "#503515" ;;
        oracle)        echo "#9e7c0a" ;;
        council)       echo "#353535" ;;
        *)             echo "#303030" ;;
    esac
}

# ─── Parse a session:window.pane target ─────────────────────
# Splits a target like "multiagent:ops.0" into its parts.
# Sets: V2_SESSION, V2_WINDOW, V2_PANE_IDX
v2_split_target() {
    local target=$1
    V2_SESSION="${target%%:*}"
    local rest="${target#*:}"
    V2_WINDOW="${rest%.*}"
    V2_PANE_IDX="${rest##*.}"
}
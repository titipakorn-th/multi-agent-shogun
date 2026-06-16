#!/usr/bin/env bash
# Constants for the v2 (specialist team) topology.
# Source this from shutsujin_departure_v2.sh.
#
# NOTE: This file is intentionally bash-3.2 compatible (associative arrays
# are a bash-4.0 feature). On macOS the system /bin/bash is still 3.2.
# We provide the same role→{pane,model,color} lookups via case statements.

# ─── Read role list in deterministic order ───────────────────
v2_role_list() {
    echo "shogun orchestrator explorer librarian oracle designer fixer observer council"
}

# ─── Read pane target for a role ─────────────────────────────
v2_pane_for() {
    local role=$1
    case "$role" in
        shogun)        echo "shogun:main.0" ;;
        orchestrator)  echo "multiagent:ops.0" ;;
        fixer)         echo "multiagent:ops.1" ;;
        designer)      echo "multiagent:ops.2" ;;
        observer)      echo "multiagent:ops.3" ;;
        explorer)      echo "multiagent:research.0" ;;
        librarian)     echo "multiagent:research.1" ;;
        oracle)        echo "multiagent:research.2" ;;
        council)       echo "multiagent:research.3" ;;
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
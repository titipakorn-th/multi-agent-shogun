#!/usr/bin/env bash
# Constants for the v2 (specialist team) topology.
# Source this from shutsujin_departure_v2.sh.

# ─── Role → pane target mapping ──────────────────────────────
declare -A V2_ROLE_PANE=(
    [shogun]="shogun:main.0"
    [orchestrator]="multiagent:ops.0"
    [fixer]="multiagent:ops.1"
    [designer]="multiagent:ops.2"
    [observer]="multiagent:ops.3"
    [explorer]="multiagent:research.0"
    [librarian]="multiagent:research.1"
    [oracle]="multiagent:research.2"
    [council]="multiagent:research.3"
)

# ─── Role → default model mapping ────────────────────────────
declare -A V2_ROLE_MODEL=(
    [shogun]="opus"
    [orchestrator]="opus"
    [explorer]="haiku"
    [librarian]="sonnet"
    [oracle]="opus"
    [designer]="sonnet"
    [fixer]="sonnet"
    [observer]="sonnet"
    [council]="opus"
)

# ─── Role → background color mapping ─────────────────────────
declare -A V2_ROLE_COLOR=(
    [shogun]="#002b36"
    [orchestrator]="#501515"
    [fixer]="#1e3a1e"
    [designer]="#3a1e3a"
    [observer]="#1e3a3a"
    [explorer]="#454510"
    [librarian]="#503515"
    [oracle]="#9e7c0a"
    [council]="#353535"
)

# ─── Read role list in deterministic order ───────────────────
v2_role_list() {
    echo "shogun orchestrator explorer librarian oracle designer fixer observer council"
}

# ─── Read pane target for a role ─────────────────────────────
v2_pane_for() {
    local role=$1
    echo "${V2_ROLE_PANE[$role]}"
}

# ─── Read model for a role ───────────────────────────────────
v2_model_for() {
    local role=$1
    echo "${V2_ROLE_MODEL[$role]:-sonnet}"
}

# ─── Read color for a role ───────────────────────────────────
v2_color_for() {
    local role=$1
    echo "${V2_ROLE_COLOR[$role]:-#303030}"
}
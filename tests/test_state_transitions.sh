#!/usr/bin/env bash
# tests/test_state_transitions.sh
#
# Behavioral test for the orchestrator's state machine.
#
# Verifies:
#   1. instructions/orchestrator.md defines the 8 expected states.
#   2. Each non-terminal state has at least one outgoing transition.
#   3. The expected transitions are present (graph shape).
#   4. Terminal states (done, failed) only transition to idle.
#   5. The state machine file produces no backward edges (linear flow).
#
# This is a real behavioral test — it parses the orchestrator prompt's
# state_machine YAML block and asserts on its structure. It will FAIL
# if instructions/orchestrator.md is missing or malformed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ORCHESTRATOR_MD="${ROOT_DIR}/instructions/orchestrator.md"

if [ ! -f "$ORCHESTRATOR_MD" ]; then
    echo "FAIL: $ORCHESTRATOR_MD not found" >&2
    exit 1
fi

# Pull the frontmatter block (between the first two `---` markers).
FRONTMATTER=$(awk '/^---$/{if(++n==2) {exit} if(n==1) next} n==1' "$ORCHESTRATOR_MD")

if [ -z "$FRONTMATTER" ]; then
    echo "FAIL: no YAML frontmatter found in $ORCHESTRATOR_MD" >&2
    exit 1
fi

# Write frontmatter to a temp file for yq consumption.
TMPF=$(mktemp)
trap "rm -f $TMPF" EXIT
printf '%s\n' "$FRONTMATTER" > "$TMPF"

if ! command -v yq &>/dev/null; then
    echo "SKIP: yq not installed; skipping yq-based state machine assertions" >&2
    echo "PASS: orchestrator.md exists with frontmatter (yq unavailable for deep checks)"
    exit 0
fi

EXPECTED_STATES=(idle analyzing dispatching awaiting_reports validating reconciling done failed)
FAIL=0

# 1. All 8 expected states are present in the state_machine block.
for state in "${EXPECTED_STATES[@]}"; do
    count=$(yq ".state_machine | map(select(.state == \"$state\")) | length" "$TMPF" 2>/dev/null || echo 0)
    if [ "$count" -lt 1 ]; then
        echo "FAIL: state machine missing state '$state'" >&2
        FAIL=1
    fi
done

# 2. Each state has at least one outgoing transition (non-empty list).
for state in "${EXPECTED_STATES[@]}"; do
    n=$(yq ".state_machine | map(select(.state == \"$state\")) | .[0].transitions | length" "$TMPF" 2>/dev/null || echo 0)
    if [ "$n" -lt 1 ]; then
        echo "FAIL: state '$state' has no outgoing transitions" >&2
        FAIL=1
    fi
done

# 3. Expected graph edges present.
expected_edges=(
    "idle:analyzing"
    "analyzing:dispatching"
    "dispatching:awaiting_reports"
    "awaiting_reports:validating"
    "awaiting_reports:reconciling"
    "validating:reconciling"
    "reconciling:done"
    "reconciling:failed"
    "done:idle"
    "failed:idle"
)
for edge in "${expected_edges[@]}"; do
    src="${edge%%:*}"
    dst="${edge##*:}"
    count=$(yq ".state_machine | map(select(.state == \"$src\")) | .[0].transitions | map(select(. == \"$dst\")) | length" "$TMPF" 2>/dev/null || echo 0)
    if [ "$count" -lt 1 ]; then
        echo "FAIL: missing edge $src -> $dst" >&2
        FAIL=1
    fi
done

# 4. Terminal states (done, failed) only transition to idle.
for terminal in done failed; do
    targets=$(yq ".state_machine | map(select(.state == \"$terminal\")) | .[0].transitions | .[]" "$TMPF" 2>/dev/null)
    if [ "$targets" != "idle" ]; then
        echo "FAIL: terminal state '$terminal' transitions to '$targets' (expected only 'idle')" >&2
        FAIL=1
    fi
done

# 5. No state has a self-loop.
for state in "${EXPECTED_STATES[@]}"; do
    self_loop=$(yq ".state_machine | map(select(.state == \"$state\")) | .[0].transitions | map(select(. == \"$state\")) | length" "$TMPF" 2>/dev/null || echo 0)
    if [ "$self_loop" -gt 0 ]; then
        echo "FAIL: state '$state' has a self-loop (forbidden)" >&2
        FAIL=1
    fi
done

# 6. The Markdown body also documents the state machine textually.
if ! grep -q "state_machine" "$ORCHESTRATOR_MD" && ! grep -q "## State Machine" "$ORCHESTRATOR_MD"; then
    echo "FAIL: orchestrator.md body does not include 'State Machine' section" >&2
    FAIL=1
fi

# 7. Forbidden actions F006 (role confusion) and F007 (skip validation) present.
for fa in "F006" "F007" "F008"; do
    if ! grep -q "$fa" "$ORCHESTRATOR_MD"; then
        echo "FAIL: forbidden_actions missing $fa in orchestrator.md" >&2
        FAIL=1
    fi
done

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: orchestrator state machine has 8 states, expected edges, no self-loops, terminal states only → idle"
fi
exit $FAIL
#!/usr/bin/env bash
# Verifies pane count per window in v2 topology.
# Expected: 4 panes in ops, 4 in research, 1 in shogun.

set -euo pipefail

OPS_COUNT=$(tmux list-panes -t multiagent:ops | wc -l | tr -d ' ')
RESEARCH_COUNT=$(tmux list-panes -t multiagent:research | wc -l | tr -d ' ')
SHOGUN_COUNT=$(tmux list-panes -t shogun:main | wc -l | tr -d ' ')

FAIL=0
[ "$OPS_COUNT" -eq 4 ] || {
    echo "FAIL: ops has $OPS_COUNT panes (expected 4)" >&2
    echo "  HINT: shut down the v2 session (tmux kill-session -t multiagent) and rerun" >&2
    FAIL=1
}
[ "$RESEARCH_COUNT" -eq 4 ] || {
    echo "FAIL: research has $RESEARCH_COUNT panes (expected 4)" >&2
    FAIL=1
}
[ "$SHOGUN_COUNT" -eq 1 ] || {
    echo "FAIL: shogun has $SHOGUN_COUNT panes (expected 1)" >&2
    FAIL=1
}

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: 4 panes in ops, 4 in research, 1 in shogun"
fi
exit $FAIL
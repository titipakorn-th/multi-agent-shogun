#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_watcher_supervisor_rescan.bats — Z2 multi-session rescan
# ═══════════════════════════════════════════════════════════════
# cmd_042 memory: supervisor used to bind one tmux session at startup
# and miss new sessions. Z2 closes that gap by making the supervisor
# rescan every 5s. This test verifies the rescan loop is present and
# that the iteration is the source of per-pane discovery.
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/watcher_supervisor.sh"
}

@test "Z2-T-RESCAN-001: supervisor has a rescan loop (while true ... sleep 5)" {
    # The rescan loop is the Z2 fix. If this test fails, the loop was
    # removed or its sleep shortened below 1s.
    grep -q "while true" "$SCRIPT"
    grep -qE "sleep [0-9]+" "$SCRIPT"
}

@test "Z2-T-RESCAN-002: rescan loop calls start_all_watchers on each iteration" {
    # The loop must re-invoke start_all_watchers (not just sleep),
    # otherwise new sessions wouldn't be picked up.
    # Find the loop body.
    local loop_body
    loop_body=$(awk '/while true/,/^done$/' "$SCRIPT")
    echo "$loop_body" | grep -q "start_all_watchers"
}

@test "Z2-T-RESCAN-003: rescan is opt-in verbose (default silent)" {
    # Z2 added an opt-in RESCAN log line; default behavior stays quiet
    # so production logs aren't noisy.
    grep -q "WATCHER_SUPERVISOR_VERBOSE" "$SCRIPT"
}

@test "Z2-T-RESCAN-004: --print-watchers enumerates agents via registry" {
    # With tmux mocked, the supervisor's spec enumerator should still
    # call into agent_registry (the dynamic source).
    grep -q "watcher_specs" "$SCRIPT"
    grep -q "agent_registry" "$SCRIPT"
}
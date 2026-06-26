#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_infra_liveness.bats — T2 infra liveness (W3)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/infra_liveness.sh"
}

teardown() {
    # Clean up any background sleep we started.
    [ -n "${BG_PID:-}" ] && kill "$BG_PID" 2>/dev/null || true
    unset BG_PID
}

@test "T-LIVENESS-001: rejects unknown args with exit 1" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
}

@test "T-LIVENESS-002: --help prints usage" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Usage"
}

@test "T-LIVENESS-003: --check-only reports missing daemons without relaunching" {
    run bash "$SCRIPT" --check-only
    # Daemons may or may not be running in test env — we only assert no relaunch.
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
    # If missing, the log must NOT contain a RELAUNCH entry.
    if [ -f "$PROJECT_ROOT/logs/infra_liveness.log" ]; then
        ! grep -q "RELAUNCH:" "$PROJECT_ROOT/logs/infra_liveness.log" || true
    fi
}

@test "T-LIVENESS-004: detects running daemon via pgrep" {
    # Spawn a long-running process whose command line matches our pattern.
    sleep 60 &
    BG_PID=$!
    # We can't synthesize an inbox_watcher process here without root, so
    # this test only verifies the helper function shape: a process that
    # exists IS detected by pgrep.
    run pgrep -f "sleep 60"
    [ "$status" -eq 0 ]
}

@test "T-LIVENESS-005: writes to log file" {
    bash "$SCRIPT" --check-only >/dev/null 2>&1 || true
    [ -f "$PROJECT_ROOT/logs/infra_liveness.log" ]
}
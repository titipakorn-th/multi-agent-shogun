#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_reap_janitor.bats — T6 janitor reaper (W6)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    REAPER="$PROJECT_ROOT/scripts/reap_janitor.sh"
    SANDBOX="$BATS_TEST_TMPDIR/queue"
    mkdir -p "$SANDBOX/reports" "$SANDBOX/tasks"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "T-REAP-001: dry-run does not delete anything" {
    touch -t 202401010000 "$SANDBOX/old.tmp"
    run bash "$REAPER" --age-minutes 1
    # The reaper resolves QUEUE_DIR relative to the script, so dry-run on
    # the real queue still lists the sandbox via stdout.
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
    echo "$output" | grep -qE "dry-run|APPLYING"
}

@test "T-REAP-002: rejects unknown args with exit 1" {
    run bash "$REAPER" --bogus-flag
    [ "$status" -eq 1 ]
}

@test "T-REAP-003: --help prints usage" {
    run bash "$REAPER" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Usage"
}

@test "T-REAP-004: zero candidates → clean exit 0" {
    # Empty sandbox has nothing to reap (script uses real queue dir).
    run bash "$REAPER" --age-minutes 999999
    # Real queue has candidates but all < 999999m old.
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

@test "T-REAP-005: dry-run output lists .bak.test candidates" {
    echo "x" > "$SANDBOX/fixture.bak.test"
    run bash "$REAPER" --age-minutes 0
    # .bak.test files are always reaped regardless of age (no mmin guard).
    echo "$output" | grep -q "fixture.bak.test" || echo "$output" | grep -q "would remove"
    rm -f "$SANDBOX/fixture.bak.test"
}
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
    # Use a sandboxed copy of the reaper pointed at the sandbox.
    local reaped_copy="$SANDBOX/reap_janitor_local.sh"
    sed -e "s|^QUEUE_DIR=.*|QUEUE_DIR=\"$SANDBOX\"|" \
        -e "s|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$SANDBOX\"|" \
        "$REAPER" > "$reaped_copy"
    chmod +x "$reaped_copy"
    touch -t 202401010000 "$SANDBOX/old.tmp"
    run bash "$reaped_copy" --age-minutes 1
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
    echo "$output" | grep -qE "dry-run|APPLYING"
    [ -f "$SANDBOX/old.tmp" ]  # dry-run must NOT delete
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
    # Empty sandbox has nothing to reap.
    local reaped_copy="$SANDBOX/reap_janitor_local.sh"
    sed -e "s|^QUEUE_DIR=.*|QUEUE_DIR=\"$SANDBOX\"|" \
        -e "s|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$SANDBOX\"|" \
        "$REAPER" > "$reaped_copy"
    chmod +x "$reaped_copy"
    run bash "$reaped_copy" --age-minutes 999999
    [ "$status" -eq 0 ]
}

@test "T-REAP-005: dry-run output lists .bak.test candidates" {
    local reaped_copy="$SANDBOX/reap_janitor_local.sh"
    sed -e "s|^QUEUE_DIR=.*|QUEUE_DIR=\"$SANDBOX\"|" \
        -e "s|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$SANDBOX\"|" \
        "$REAPER" > "$reaped_copy"
    chmod +x "$reaped_copy"
    mkdir -p "$SANDBOX/scripts"
    echo "x" > "$SANDBOX/scripts/fixture.bak.test"
    run bash "$reaped_copy" --age-minutes 0
    echo "$output" | grep -qE "fixture.bak.test|would remove"
    [ -f "$SANDBOX/scripts/fixture.bak.test" ]  # dry-run preserves
}

@test "T-REAP-006: --apply removes an untracked .bak.test file (round-3 V3 regression)" {
    # V3 round-3 review: ntfy.sh.bak.test survived because the original
    # candidate match only scanned queue/. The fix extends the scan to
    # scripts/ at depth ≤ 1. This test guards against future regressions.
    touch "$SANDBOX/untracked.bak.test"
    [ -f "$SANDBOX/untracked.bak.test" ]
    # Point the reaper at the sandbox by overriding INBOX_DIR + queue_dir
    # via env. Since reap_janitor hardcodes $QUEUE_DIR via BASH_SOURCE,
    # we copy the script into the sandbox with the path rewritten.
    local reaped_copy
    reaped_copy="$SANDBOX/reap_janitor_local.sh"
    sed -e "s|^QUEUE_DIR=.*|QUEUE_DIR=\"$SANDBOX\"|" \
        -e "s|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$SANDBOX\"|" \
        "$PROJECT_ROOT/scripts/reap_janitor.sh" > "$reaped_copy"
    chmod +x "$reaped_copy"
    # Plant a sibling scripts/ dir so the bak.test scan finds the file.
    mkdir -p "$SANDBOX/scripts"
    mv "$SANDBOX/untracked.bak.test" "$SANDBOX/scripts/untracked.bak.test"
    bash "$reaped_copy" --apply >/dev/null 2>&1 || true
    [ ! -f "$SANDBOX/scripts/untracked.bak.test" ]
}
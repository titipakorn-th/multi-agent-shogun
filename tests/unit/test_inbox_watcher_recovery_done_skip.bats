#!/usr/bin/env bats
# test_inbox_watcher_recovery_done_skip.bats — regression guard for the
# auto-recovery skip-guard. The Python heredoc at inbox_watcher.sh:393
# (inside enqueue_recovery_task_assigned) skips auto-recovery when the
# task YAML status is in {"cancelled", "idle", "done"}.
#
# Bug: pre-fix, "done" was NOT in the skip set. A clear_command arriving
# while the YAML still read done (cleanup resets, slow redo write) made
# the agent receive "[auto-recovery] … resume the assigned task" — telling
# it to re-execute finished work. CLAUDE.md task-layer rule:
# done = wait (DO NOT re-report).
#
# Plan: 2026-06-27-redo-recovery-done-status-gap.md

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WATCHER="$REPO_ROOT/scripts/inbox_watcher.sh"
    TEST_TMP="$(mktemp -d /tmp/iw_done.XXXXXX)"
    export HOME="$TEST_TMP"

    # Minimal queue/inbox scaffolding.
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue/tasks"
    mkdir -p "$TEST_TMP/scripts"

    # In testing mode the watcher's arg-parsing block (which sets SCRIPT_DIR,
    # AGENT_ID, PANE_TARGET, LOCKFILE) is skipped — the test must set these
    # before sourcing. enqueue_recovery_task_assigned uses SCRIPT_DIR to
    # locate the python interpreter and INBOX for the inbox file path.
    SCRIPT_DIR="$REPO_ROOT"
    INBOX="$TEST_TMP/queue/inbox/oracle.yaml"
    AGENT_ID="oracle"
    PANE_TARGET="multiagent:research.2"
    CLI_TYPE="claude"
    LOCKFILE="${INBOX}.lock"
    IDLE_FLAG_DIR="$TEST_TMP/idle_flags"
    mkdir -p "$IDLE_FLAG_DIR"
    export SCRIPT_DIR INBOX AGENT_ID PANE_TARGET CLI_TYPE LOCKFILE IDLE_FLAG_DIR

    # Empty inbox so dedup loop exits without printing.
    printf 'messages: []\n' > "$INBOX"

    # Source the watcher in testing mode (functions only, no main loop).
    export __INBOX_WATCHER_TESTING__=1
    # shellcheck disable=SC1090
    source "$WATCHER"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: write a task YAML with the given status.
write_task_yaml() {
    local status="$1"
    cat > "$TEST_TMP/queue/tasks/oracle.yaml" <<YAML
task:
  status: ${status}
  task_id: test_task_001
YAML
}

# Helper: invoke enqueue_recovery_task_assigned and capture stdout.
invoke_recovery() {
    enqueue_recovery_task_assigned
}

@test "status: done → SKIP_CANCELLED:done (the fix)" {
    # The bug: pre-fix, status=done would NOT print SKIP_CANCELLED and
    # would proceed to enqueue the recovery message. Post-fix it must
    # short-circuit at the status check.
    write_task_yaml "done"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ "$output" == "SKIP_CANCELLED:done" ]]
}

@test "status: cancelled → SKIP_CANCELLED:cancelled (regression guard for existing behavior)" {
    write_task_yaml "cancelled"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ "$output" == "SKIP_CANCELLED:cancelled" ]]
}

@test "status: idle → SKIP_CANCELLED:idle (regression guard for existing behavior)" {
    write_task_yaml "idle"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ "$output" == "SKIP_CANCELLED:idle" ]]
}

@test "status: assigned → does NOT skip (recovery proceeds normally)" {
    # The skip guard must NOT short-circuit on assigned — that's the
    # normal path where auto-recovery SHOULD enqueue the resume message.
    write_task_yaml "assigned"
    run invoke_recovery
    [ "$status" -eq 0 ]
    # Should NOT print any SKIP_CANCELLED line.
    [[ ! "$output" =~ "SKIP_CANCELLED" ]]
}

@test "status: in_progress → does NOT skip (recovery proceeds normally)" {
    write_task_yaml "in_progress"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "SKIP_CANCELLED" ]]
}

@test "no task YAML present → does NOT skip (recovery proceeds as safety net)" {
    # The status guard only fires when the YAML exists AND its status is
    # terminal. Missing YAML → safety-net proceed (the existing
    # except-pass behavior at line 399).
    rm -f "$TEST_TMP/queue/tasks/oracle.yaml"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "SKIP_CANCELLED" ]]
}

@test "status: DONE (uppercase) → does NOT skip (case-sensitive)" {
    # The fix is case-sensitive — it matches lowercase "done" exactly.
    # This is a deliberate choice: task YAML statuses are typed
    # lowercase throughout the codebase. Document the contract.
    write_task_yaml "DONE"
    run invoke_recovery
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "SKIP_CANCELLED" ]]
}
#!/usr/bin/env bats
# test_stop_hook.bats — stop_hook_inbox.sh unit tests
#
# Calls the REAL production script with env var overrides:
#   __STOP_HOOK_SCRIPT_DIR → points to test temp directory
#   __STOP_HOOK_AGENT_ID   → mocks tmux agent detection
#
# Test configuration:
#   T-HOOK-001: stop_hook_active=true → exit 0
#   T-HOOK-002: unknown agent -> exit 0
#   T-HOOK-003: agent_id=shogun → exit 0
#   T-HOOK-004: completion message -> inbox_write is called (report_completed)
#   T-HOOK-005: error message -> inbox_write is called (error_report)
#   T-HOOK-006: neutral message -> inbox_write is not called
#   T-HOOK-007: empty last_assistant_message -> inbox_write is not called
#   T-HOOK-008: inbox has unread -> block JSON output
#   T-HOOK-009: inbox has no unread + completion message -> exit 0 + notification
#   T-HOOK-010: inbox has unread + completion message -> block + notification

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/scripts/stop_hook_inbox.sh"

setup() {
    TEST_TMP="$(mktemp -d)"
    mkdir -p "$TEST_TMP/scripts"
    mkdir -p "$TEST_TMP/queue/inbox"

    # Mock inbox_write.sh — logs arguments to file
    cat > "$TEST_TMP/scripts/inbox_write.sh" << 'MOCK'
#!/bin/bash
echo "$@" >> "$(dirname "$0")/../inbox_write_calls.log"
MOCK
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: run the REAL hook script with test overrides
run_hook() {
    local json="$1"
    local agent_id="${2:-ashigaru1}"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="$agent_id" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

# Helper: run with no agent ID set
run_hook_no_agent() {
    local json="$1"
    __STOP_HOOK_SCRIPT_DIR="$TEST_TMP" \
    __STOP_HOOK_AGENT_ID="" \
    run bash "$HOOK_SCRIPT" <<< "$json"
}

@test "T-HOOK-001: stop_hook_active=true skips all processing" {
    run_hook '{"stop_hook_active": true, "last_assistant_message": "Task completed"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-002: unknown agent (empty agent_id) exits 0" {
    run_hook_no_agent '{"stop_hook_active": false}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-003: shogun agent always exits 0" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "Task completed"}' "shogun"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "T-HOOK-004: completion message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "Task completed. report YAML updated."}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
    grep -q "ashigaru1" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-005: error message triggers inbox_write to karo" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "File not found. Interrupted due to error."}'
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "karo" "$TEST_TMP/inbox_write_calls.log"
    grep -q "error_report" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-006: neutral message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": "Waiting. Awaiting next instructions."}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-007: empty last_assistant_message does not trigger inbox_write" {
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/inbox_write_calls.log" ]
}

@test "T-HOOK-008: unread inbox messages produce block JSON" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "This is a new task"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": ""}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"decision"'
    echo "$output" | grep -q '"block"'
}

@test "T-HOOK-009: no unread + completion message exits 0 with notification" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "Old message"
    read: true
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "Task completed. report YAML updated."}'
    [ "$status" -eq 0 ]
    [ -z "$output" ] || ! echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

@test "T-HOOK-010: unread inbox + completion message blocks AND notifies" {
    cat > "$TEST_TMP/queue/inbox/ashigaru1.yaml" << 'YAML'
messages:
  - id: msg_001
    from: karo
    type: task_assigned
    content: "Next task"
    read: false
YAML
    run_hook '{"stop_hook_active": false, "last_assistant_message": "Task completed."}'
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"block"'
    [ -f "$TEST_TMP/inbox_write_calls.log" ]
    grep -q "report_completed" "$TEST_TMP/inbox_write_calls.log"
}

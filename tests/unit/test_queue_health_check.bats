#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_queue_health_check.bats — Task 9 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/queue_health_check.py:
#   - Reports active queue size + command count
#   - Detects terminal commands still in active file
#   - Detects stale tmp files
#   - Detects corrupt inbox backups
#   - Detects oversized inboxes
#   - Fix mode removes stale tmp files (not unread messages)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECKER="$PROJECT_ROOT/scripts/queue_health_check.py"
    TEST_TMP="$(mktemp -d)"
    QUEUE="$TEST_TMP/queue"
    mkdir -p "$QUEUE/inbox" "$QUEUE/tasks"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "T-QHEALTH-001: empty queue → healthy (exit 0)" {
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "OK: queue is healthy"
}

@test "T-QHEALTH-002: terminal cmds in active file → warning" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_done
    status: done
  - id: cmd_pending
    status: pending
YAML
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "terminal cmd"
}

@test "T-QHEALTH-003: stale tmp file → warning" {
    # Create a fake stale tmp file with old mtime.
    mkdir -p "$QUEUE/inbox"
    touch -t 202001010000 "$QUEUE/inbox/old.tmp.999"
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "stale tmp"
}

@test "T-QHEALTH-004: corrupt inbox backup → warning" {
    mkdir -p "$QUEUE/inbox"
    touch "$QUEUE/inbox/orchestrator.yaml.corrupt"
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "corrupt"
}

@test "T-QHEALTH-005: oversized inbox → warning" {
    mkdir -p "$QUEUE/inbox"
    # Build inbox with > 100 unread messages.
    cat > "$QUEUE/inbox/shogun.yaml" <<'YAML'
messages:
  - {id: m1, read: false}
YAML
    # Append 110 more.
    python3 -c "
import yaml
data = {'messages': [{'id': f'm{i}', 'read': False} for i in range(120)]}
with open('$QUEUE/inbox/shogun.yaml', 'w') as f:
    yaml.dump(data, f)
"
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "oversized"
}

@test "T-QHEALTH-006: --fix removes stale tmp files but NOT unread messages" {
    mkdir -p "$QUEUE/inbox"
    touch -t 202001010000 "$QUEUE/inbox/old.tmp.999"
    # Add unread message
    cat > "$QUEUE/inbox/fixer.yaml" <<'YAML'
messages:
  - {id: keep_me, read: false}
YAML

    run python3 "$CHECKER" --queue-dir "$QUEUE" --fix
    # Stale tmp should be gone.
    [ ! -e "$QUEUE/inbox/old.tmp.999" ]
    # Unread message MUST still exist.
    [ -f "$QUEUE/inbox/fixer.yaml" ]
    grep -q "keep_me" "$QUEUE/inbox/fixer.yaml"
}

@test "T-QHEALTH-007: large cmd_queue byte size → warning" {
    # Generate a queue file > 64KB.
    python3 -c "
import yaml
data = {'queue': [{'id': f'cmd_{i}', 'status': 'pending', 'padding': 'x' * 1000} for i in range(80)]}
with open('$QUEUE/shogun_to_orchestrator.yaml', 'w') as f:
    yaml.dump(data, f)
"
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "cmd_queue"
}

@test "T-QHEALTH-008: orchestrator.yaml state file is not treated as a queue" {
    cat > "$QUEUE/tasks/orchestrator.yaml" <<'YAML'
orchestration:
  parent_cmd: cmd_test
  state: in_progress
YAML
    run python3 "$CHECKER" --queue-dir "$QUEUE"
    # Should NOT report terminal cmds because it's an orchestration state file.
    [ "$status" -eq 0 ]
}
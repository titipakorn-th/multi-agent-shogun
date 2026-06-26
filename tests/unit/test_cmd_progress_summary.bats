#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_cmd_progress_summary.bats — Task 10 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/cmd_progress_summary.py:
#   - JSON output shape
#   - Text output is human-readable
#   - Detects waiting on specialist / validation / Lord / delivery stuck
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SUMMARIZER="$PROJECT_ROOT/scripts/cmd_progress_summary.py"
    TEST_TMP="$(mktemp -d)"
    QUEUE="$TEST_TMP/queue"
    mkdir -p "$QUEUE/tasks" "$QUEUE/reports" "$QUEUE/inbox"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "T-PROG-001: empty queue → empty commands list" {
    echo "queue: []" > "$QUEUE/shogun_to_orchestrator.yaml"
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['commands']==[]"
}

@test "T-PROG-002: waiting on specialist detection" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_test_001
    status: in_progress
    purpose: "Test cmd"
YAML
    # Active task with no report.
    cat > "$QUEUE/tasks/fixer.yaml" <<YAML
worker_id: fixer
task_id: cmd_test_001_a
parent_cmd: cmd_test_001
status: assigned
timestamp: "$(date '+%Y-%m-%dT%H:%M:%S')"
YAML
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    [ "$status" -eq 0 ]
    echo "$output" | grep -q '"blocker": "waiting on specialist"'
}

@test "T-PROG-003: waiting on validation detection" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_test_002
    status: in_progress
    purpose: "Test cmd"
    required_validations:
      - role: oracle
        subtask_id: cmd_test_002_a
        required_for: [done]
YAML
    # No report yet.
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    echo "$output" | grep -q '"blocker": "waiting on validation"'
}

@test "T-PROG-004: text format readable output" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_test_003
    status: in_progress
    purpose: "Test cmd for text output"
YAML
    # Active task → "waiting on specialist" classification.
    cat > "$QUEUE/tasks/fixer.yaml" <<YAML
worker_id: fixer
task_id: cmd_test_003_a
parent_cmd: cmd_test_003
status: assigned
timestamp: "$(date '+%Y-%m-%dT%H:%M:%S')"
YAML
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format text
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "cmd_test_003"
    echo "$output" | grep -q "waiting on specialist"
}

@test "T-PROG-005: completed cmd is excluded from summary" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_done
    status: done
  - id: cmd_active
    status: in_progress
YAML
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    echo "$output" | python3 -c "
import sys,json
d=json.load(sys.stdin)
ids=[c['id'] for c in d['commands']]
assert 'cmd_done' not in ids
assert 'cmd_active' in ids
"
}

@test "T-PROG-006: missing queue file → empty list, exit 0" {
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['commands']==[]"
}

@test "T-PROG-007: validation passed count" {
    cat > "$QUEUE/shogun_to_orchestrator.yaml" <<'YAML'
queue:
  - id: cmd_test_007
    status: in_progress
    purpose: "Validation test"
    required_validations:
      - role: oracle
        subtask_id: cmd_test_007_a
        required_for: [done]
YAML
    cat > "$QUEUE/reports/oracle_report.yaml" <<'YAML'
sections:
  - task_id: cmd_test_007_a
    parent_cmd: cmd_test_007
    verdict: PASS_FULL
    timestamp: "2026-06-26T12:00:00+09:00"
YAML
    run python3 "$SUMMARIZER" --queue-dir "$QUEUE" --format json
    echo "$output" | grep -q '"passed": 1'
}
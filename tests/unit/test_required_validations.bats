#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_required_validations.bats — Task 6 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/check_required_validations.py:
#   - Empty required_validations → PASS (exit 0)
#   - All required validations present with PASS_* → PASS (exit 0)
#   - Missing required validation → FAIL (exit 2)
#   - Failed required validation → FAIL (exit 3)
#   - Missing orchestrator.yaml → error
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECKER="$PROJECT_ROOT/scripts/check_required_validations.py"
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: write a minimal orchestrator.yaml with required_validations block.
# Args: parent_cmd and a series of role/subtask_id pairs.
write_orchestrator() {
    local parent_cmd="$1"
    shift
    mkdir -p "$TEST_TMP/queue/tasks"
    {
        echo "orchestration:"
        echo "  parent_cmd: ${parent_cmd}"
        echo "  started_at: \"2026-06-26T00:00:00+09:00\""
        echo "  state: in_progress"
        echo "  required_validations:"
        local role subtask
        while [ $# -gt 0 ]; do
            role="$1"
            subtask="$2"
            echo "    - role: ${role}"
            echo "      subtask_id: ${subtask}"
            echo "      required_for: [done]"
            shift 2
        done
    } > "$TEST_TMP/queue/tasks/orchestrator.yaml"
}

# Helper: write a role report.
write_report() {
    local role="$1" subtask_id="$2" verdict="$3"
    mkdir -p "$TEST_TMP/queue/reports"
    cat > "$TEST_TMP/queue/reports/${role}_report.yaml" <<YAML
sections:
  - subtask_id: ${subtask_id}
    parent_cmd: cmd_test_001
    role: ${role}
    verdict: ${verdict}
    timestamp: "2026-06-26T01:00:00+09:00"
YAML
}

@test "T-VALID-001: empty required_validations → PASS" {
    write_orchestrator "cmd_test_001"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no required_validations"
}

@test "T-VALID-002: all required PASS_FULL → PASS" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a"
    write_report "oracle" "cmd_test_001_a" "PASS_FULL"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Passed:   1"
}

@test "T-VALID-003: missing required validation → FAIL exit 2" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a"
    # No report written.
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "Missing:  1"
}

@test "T-VALID-004: failed validation → FAIL exit 3" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a"
    write_report "oracle" "cmd_test_001_a" "FAIL_BLOCKER"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 3 ]
    echo "$output" | grep -q "Failed:   1"
}

@test "T-VALID-005: multi-role required (oracle + council) → both must pass" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a" "council" "cmd_test_001_b"
    write_report "oracle" "cmd_test_001_a" "PASS_FULL"
    # council report missing.
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "Missing:  1"

    # Now add council report.
    write_report "council" "cmd_test_001_b" "PASS_FULL"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 0 ]
}

@test "T-VALID-006: PASS_PARTIAL counts as passed" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a"
    write_report "oracle" "cmd_test_001_a" "PASS_PARTIAL"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 0 ]
}

@test "T-VALID-007: unknown verdict treated as missing" {
    write_orchestrator "cmd_test_001" "oracle" "cmd_test_001_a"
    write_report "oracle" "cmd_test_001_a" "WEIRD_VERDICT"
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 2 ]
}

@test "T-VALID-008: missing orchestrator.yaml → usage error" {
    # Don't create orchestrator.yaml. The checker needs at least an empty
    # orchestration block.
    mkdir -p "$TEST_TMP/queue/tasks"
    cat > "$TEST_TMP/queue/tasks/orchestrator.yaml" <<'YAML'
orchestration: {}
YAML
    run python3 "$CHECKER" "cmd_test_001" \
        --orchestrator "$TEST_TMP/queue/tasks/orchestrator.yaml" \
        --reports "$TEST_TMP/queue/reports"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "no required_validations"
}
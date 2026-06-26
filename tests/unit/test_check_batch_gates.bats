#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_check_batch_gates.bats — Task 11 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/check_batch_gates.py:
#   - Strategy review required (oracle)
#   - Quality template required
#   - Unprocessed detection pattern required
#   - batch1 must reach qc_passed before batch2 dispatch
#   - batch1 qc_failed → block with root cause hint
#   - item_count mismatch → fail
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHECKER="$PROJECT_ROOT/scripts/check_batch_gates.py"
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: write a batch task YAML with optional overrides via stdin-friendly here-doc.
write_batch_yaml() {
    local body="$1"
    cat > "$TEST_TMP/batch.yaml" <<YAML
worker_id: fixer
task_id: subtask_batch_test
status: assigned
batch:
${body}
YAML
}

@test "T-BATCH-001: all gates pass → exit 0" {
    write_batch_yaml "  item_count: 50
  batch_size: 30
  strategy_reviewed_by: oracle
  strategy_reviewed_at: \"2026-06-26T12:00:00+09:00\"
  quality_template_present: true
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: qc_passed
      item_count: 30
      dispatched_at: \"2026-06-26T13:00:00+09:00\"
      qc_reviewed_at: \"2026-06-26T14:00:00+09:00\"
      qc_reviewed_by: shogun
      qc_outcome: PASS
    - batch_id: batch2
      status: pending
      item_count: 20"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "batch gates pass"
}

@test "T-BATCH-002: missing strategy_reviewed_by → fail" {
    write_batch_yaml "  item_count: 50
  quality_template_present: true
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: qc_passed"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "strategy_reviewed_by"
}

@test "T-BATCH-003: missing quality_template → fail" {
    write_batch_yaml "  item_count: 50
  strategy_reviewed_by: oracle
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: qc_passed"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "quality_template"
}

@test "T-BATCH-004: missing unprocessed_detection_pattern → fail" {
    write_batch_yaml "  item_count: 50
  strategy_reviewed_by: oracle
  quality_template_present: true
  batches:
    - batch_id: batch1
      status: qc_passed"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "unprocessed_detection_pattern"
}

@test "T-BATCH-005: batch1 QC not done → block batch2 (exit 3)" {
    write_batch_yaml "  item_count: 50
  strategy_reviewed_by: oracle
  quality_template_present: true
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: dispatched
    - batch_id: batch2
      status: pending"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml" --phase dispatch-batch2
    [ "$status" -eq 3 ]
    echo "$output" | grep -q "must reach qc_passed"
}

@test "T-BATCH-006: batch1 QC failed → block (exit 4)" {
    write_batch_yaml "  item_count: 50
  strategy_reviewed_by: oracle
  quality_template_present: true
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: qc_failed
      qc_reviewed_at: \"2026-06-26T14:00:00+09:00\"
      qc_reviewed_by: shogun
      qc_outcome: FAIL"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml" --phase dispatch-batch2
    [ "$status" -eq 4 ]
    echo "$output" | grep -q "root cause analysis"
}

@test "T-BATCH-007: item_count mismatch → fail" {
    write_batch_yaml "  item_count: 100
  strategy_reviewed_by: oracle
  quality_template_present: true
  unprocessed_detection_pattern: \"status: pending\"
  batches:
    - batch_id: batch1
      status: qc_passed
      item_count: 30
    - batch_id: batch2
      status: pending
      item_count: 20"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "item_count mismatch"
}

@test "T-BATCH-008: small item_count (< 30) → no batch gates needed" {
    write_batch_yaml "  item_count: 5
  strategy_reviewed_by: oracle"
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "batch gates only apply"
}

@test "T-BATCH-009: missing batch block → fail" {
    cat > "$TEST_TMP/batch.yaml" <<'YAML'
worker_id: fixer
task_id: subtask_no_batch
status: assigned
YAML
    run python3 "$CHECKER" "$TEST_TMP/batch.yaml"
    [ "$status" -eq 1 ]
    echo "$output" | grep -q "missing 'batch' block"
}
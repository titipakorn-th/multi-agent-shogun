#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_weekly_health_review.bats — Task 14 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/weekly_health_review.sh:
#   - Runs without error (exit 0 or 2)
#   - Reports each of the 6 sections
#   - Emits recommendations when thresholds exceeded
#   - Skips gracefully when ledger/queue missing
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    REVIEW="$PROJECT_ROOT/scripts/weekly_health_review.sh"
}

@test "T-HEALTH-001: runs without error in current repo state" {
    run bash "$REVIEW"
    # Exit 0 (healthy) or 2 (warnings) — never 1 (usage error) or other.
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
}

@test "T-HEALTH-002: reports all 6 sections" {
    run bash "$REVIEW"
    echo "$output" | grep -q "## 1. Queue size"
    echo "$output" | grep -q "## 2. Queue hygiene"
    echo "$output" | grep -q "## 3. Checkpoint latency"
    echo "$output" | grep -q "## 4. Validation gate coverage"
    echo "$output" | grep -q "## 5. Test skip count"
    echo "$output" | grep -q "## 6. Instruction drift"
}

@test "T-HEALTH-003: honors --threshold flag" {
    run bash "$REVIEW" --threshold 999
    # Threshold 999 means no recommendations should fire.
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "All checks healthy"
}

@test "T-HEALTH-004: honors --since-days flag" {
    run bash "$REVIEW" --since-days 1 --threshold 999
    [ "$status" -eq 0 ]
}

@test "T-HEALTH-005: rejects unknown arg with exit 1" {
    run bash "$REVIEW" --bogus-flag
    [ "$status" -eq 1 ]
}

# ─── Archive validation path coverage (Task 6 follow-up) ───
# The script must inspect BOTH archive shapes the repo actually uses:
#   - queue/shogun_to_orchestrator_archive.yaml (single concatenated ledger)
#   - queue/archive/                            (per-command files)
# Tests below run the script in an isolated sandbox that mirrors that layout.

setup_sandbox() {
    local sandbox="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$sandbox/queue/archive" \
             "$sandbox/scripts" \
             "$sandbox/.venv/bin" \
             "$sandbox/instructions/generated" \
             "$sandbox/tests"
    # Stub python so queue_health_check is a no-op for these tests.
    # Delegate to system python3 (which has PyYAML) so the YAML parsing path
    # in section 4 works against fixture archives.
    cat > "$sandbox/.venv/bin/python3" <<'PY'
import subprocess, sys
sys.exit(subprocess.call(["python3"] + sys.argv))
PY
    chmod +x "$sandbox/.venv/bin/python3"
    # Copy the script under test.
    cp "$PROJECT_ROOT/scripts/weekly_health_review.sh" "$sandbox/scripts/"
}

@test "T-HEALTH-006: done+required_validations is NOT a validation miss (ledger)" {
    setup_sandbox
    local sandbox="$BATS_TEST_TMPDIR/sandbox"

    cat > "$sandbox/queue/shogun_to_orchestrator_archive.yaml" <<'YAML'
commands:
  - id: cmd_d1
    status: done
    required_validations:
      - type: tests
YAML

    run bash "$sandbox/scripts/weekly_health_review.sh"
    echo "$output" | grep -E "done WITHOUT required_validations: 0" \
        || { echo "expected 0 validation misses (cmd_d1 has required_validations):" >&2; echo "$output" | tail -15 >&2; return 1; }
}

@test "T-HEALTH-007: done WITHOUT required_validations IS a validation miss (per-command file)" {
    setup_sandbox
    local sandbox="$BATS_TEST_TMPDIR/sandbox"

    cat > "$sandbox/queue/archive/cmd_d2.yaml" <<'YAML'
commands:
  - id: cmd_d2
    status: done
YAML

    run bash "$sandbox/scripts/weekly_health_review.sh"
    echo "$output" | grep -E "done WITHOUT required_validations: 1" \
        || { echo "expected 1 validation miss (cmd_d2 is done with no required_validations):" >&2; echo "$output" | tail -15 >&2; return 1; }
}

@test "T-HEALTH-008: mixed ledger counts only done cmds missing required_validations" {
    setup_sandbox
    local sandbox="$BATS_TEST_TMPDIR/sandbox"

    cat > "$sandbox/queue/shogun_to_orchestrator_archive.yaml" <<'YAML'
commands:
  - id: cmd_done_with_validation
    status: done
    required_validations:
      - type: tests
  - id: cmd_done_no_validation
    status: done
  - id: cmd_pending_with_validation
    status: pending
    required_validations:
      - type: tests
  - id: cmd_in_progress_no_validation
    status: in_progress
YAML

    run bash "$sandbox/scripts/weekly_health_review.sh"
    # Only `cmd_done_no_validation` is a miss: 1 total.
    echo "$output" | grep -E "done WITHOUT required_validations: 1" \
        || { echo "expected 1 validation miss (only cmd_done_no_validation):" >&2; echo "$output" | tail -15 >&2; return 1; }
}

@test "T-HEALTH-009: malformed archive entry is reported as warning, not silent" {
    setup_sandbox
    local sandbox="$BATS_TEST_TMPDIR/sandbox"

    cat > "$sandbox/queue/archive/cmd_bad.yaml" <<'YAML'
commands:
  - id: cmd_bad
    status: done
  this: is: malformed: yaml:
YAML

    run bash "$sandbox/scripts/weekly_health_review.sh"
    # Script must still exit cleanly (status 0 or 2) and emit a WARN line.
    [ "$status" -eq 0 ] || [ "$status" -eq 2 ]
    echo "$output" | grep -qE "WARN.*cmd_bad" \
        || { echo "expected WARN line for cmd_bad.yaml:" >&2; echo "$output" | tail -15 >&2; return 1; }
}
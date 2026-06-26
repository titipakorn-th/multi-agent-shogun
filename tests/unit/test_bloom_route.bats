#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_bloom_route.bats — Task 3 gap-closure: executable Bloom routing
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/bloom_route.py:
#   - auto routes L1→explorer, L3→orchestrator, L4→oracle, L5→oracle,
#     L5/EVAL→council, L6→oracle
#   - manual mode emits 'manual' role per task (no auto routing)
#   - off mode emits an empty work graph
#   - keyword inference fills missing levels
#   - work graph records level, route, role, reason
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BLOOM="$PROJECT_ROOT/.venv/bin/python3 $PROJECT_ROOT/scripts/bloom_route.py"
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    rm -rf "$TEST_TMP"
}

write_settings() {
    cat > "$TEST_TMP/settings.yaml" <<YAML
language: en
shell: bash
topology: v2
cli:
  default: claude
bloom_routing: $1
roles:
  shogun: { model: opus, pane_target: shogun:main.0, prompt_path: instructions/shogun.md }
  orchestrator: { model: opus, pane_target: multiagent:ops.0, prompt_path: instructions/orchestrator.md }
  explorer: { model: sonnet, pane_target: multiagent:research.0, prompt_path: instructions/explorer.md }
YAML
}

write_subtasks() {
    cat > "$TEST_TMP/subtasks.yaml" <<'YAML'
subtasks:
  - id: st_001
    title: "Locate auth module"
    level: L1
  - id: st_002
    title: "Apply bugfix"
    level: L3
  - id: st_003
    title: "Analyze architecture"
    level: L4
  - id: st_004
    title: "Evaluate plan"
    level: L5
    eval: true
  - id: st_005
    title: "Design new schema"
    level: L6
YAML
}

# ─── T-BLOOM-ROUTE-001: L1 routes to explorer ───

@test "T-BLOOM-ROUTE-001: L1 routes to explorer" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    # Output ordering: id, level, route, role, action, reason → role is 4th line.
    echo "$output" | awk '/^- id: st_001/{flag=1; next} flag && /role:/{print; exit}' | grep -q "role: explorer"
}

# ─── T-BLOOM-ROUTE-002: L3 routes to orchestrator ───

@test "T-BLOOM-ROUTE-002: L3 routes to orchestrator (apply)" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/^- id: st_002/{flag=1; next} flag && /role:/{print; exit}' | grep -q "role: orchestrator"
    echo "$output" | awk '/^- id: st_002/{flag=1; next} flag && /action:/{print; exit}' | grep -q "action: apply"
}

# ─── T-BLOOM-ROUTE-003: L4 routes to oracle ───

@test "T-BLOOM-ROUTE-003: L4 routes to oracle (analyze)" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/^- id: st_003/{flag=1; next} flag && /role:/{print; exit}' | grep -q "role: oracle"
    echo "$output" | awk '/^- id: st_003/{flag=1; next} flag && /action:/{print; exit}' | grep -q "action: analyze"
}

# ─── T-BLOOM-ROUTE-004: L5+EVAL routes to council ───

@test "T-BLOOM-ROUTE-004: L5+EVAL routes to council" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/^- id: st_004/{flag=1; next} flag && /role:/{print; exit}' | grep -q "role: council"
}

# ─── T-BLOOM-ROUTE-005: L6 routes to oracle (create) ───

@test "T-BLOOM-ROUTE-005: L6 routes to oracle (create)" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/^- id: st_005/{flag=1; next} flag && /role:/{print; exit}' | grep -q "role: oracle"
    echo "$output" | awk '/^- id: st_005/{flag=1; next} flag && /action:/{print; exit}' | grep -q "action: create"
}

# ─── T-BLOOM-ROUTE-006: manual mode emits 'manual' per task ───

@test "T-BLOOM-ROUTE-006: manual mode emits manual routes" {
    write_settings "manual"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "mode: manual"
    echo "$output" | grep -c "role: manual" | grep -q "5"
}

# ─── T-BLOOM-ROUTE-007: off mode emits empty graph ───

@test "T-BLOOM-ROUTE-007: off mode emits empty tasks list" {
    write_settings "off"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qE "mode: ['\"]?off['\"]?"
    echo "$output" | grep -q "tasks: \[\]"
}

# ─── T-BLOOM-ROUTE-008: auto/manual/off produce different output ───

@test "T-BLOOM-ROUTE-008: auto/manual/off differ for the same input" {
    write_subtasks
    cat > "$TEST_TMP/s_auto.yaml" <<'YAML'
bloom_routing: auto
YAML
    cat > "$TEST_TMP/s_manual.yaml" <<'YAML'
bloom_routing: manual
YAML
    cat > "$TEST_TMP/s_off.yaml" <<'YAML'
bloom_routing: off
YAML

    run bash -c "$BLOOM --settings $TEST_TMP/s_auto.yaml --subtasks $TEST_TMP/subtasks.yaml"
    auto_out="$output"
    run bash -c "$BLOOM --settings $TEST_TMP/s_manual.yaml --subtasks $TEST_TMP/subtasks.yaml"
    manual_out="$output"
    run bash -c "$BLOOM --settings $TEST_TMP/s_off.yaml --subtasks $TEST_TMP/subtasks.yaml"
    off_out="$output"

    [ "$auto_out" != "$manual_out" ]
    [ "$auto_out" != "$off_out" ]
    [ "$manual_out" != "$off_out" ]
}

# ─── T-BLOOM-ROUTE-009: keyword inference ───

@test "T-BLOOM-ROUTE-009: missing level is inferred from keywords" {
    write_settings "auto"
    cat > "$TEST_TMP/subtasks.yaml" <<'YAML'
subtasks:
  - id: st_infer_analyze
    title: "Analyze the codebase"
  - id: st_infer_design
    title: "Design the schema"
  - id: st_infer_default
    title: "Misc"
YAML
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    echo "$output" | awk '/^- id: st_infer_analyze/{flag=1; next} flag && /level:/{print; exit}' | grep -q "level: L4"
    echo "$output" | awk '/^- id: st_infer_design/{flag=1; next} flag && /level:/{print; exit}' | grep -q "level: L6"
    echo "$output" | awk '/^- id: st_infer_default/{flag=1; next} flag && /level:/{print; exit}' | grep -q "level: L3"
}

# ─── T-BLOOM-ROUTE-010: work graph records reason per task ───

@test "T-BLOOM-ROUTE-010: every task has a reason field" {
    write_settings "auto"
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 0 ]
    # 5 subtasks → 5 reason entries
    reason_count=$(echo "$output" | grep -c "reason:")
    [ "$reason_count" -eq 5 ]
}

# ─── T-BLOOM-ROUTE-011: missing settings file fails ───

@test "T-BLOOM-ROUTE-011: missing settings file returns exit 1" {
    write_subtasks
    run bash -c "$BLOOM --settings /nonexistent.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 1 ]
}

# ─── T-BLOOM-ROUTE-012: bogus bloom_routing value returns exit 2 ───

@test "T-BLOOM-ROUTE-012: bogus bloom_routing value returns exit 2" {
    cat > "$TEST_TMP/settings.yaml" <<YAML
bloom_routing: nonsense
YAML
    write_subtasks
    run bash -c "$BLOOM --settings $TEST_TMP/settings.yaml --subtasks $TEST_TMP/subtasks.yaml"
    [ "$status" -eq 2 ]
}
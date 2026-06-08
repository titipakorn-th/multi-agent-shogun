#!/usr/bin/env bats
# test_dynamic_model_routing.bats — Dynamic Model Routing Phase 1 Unit Test
# DMR-SPEC-001 Compliant (TC-DMR-001 to 055)
# Issue #53 / TDD Red Phase

# --- Setup ---

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # For Phase 1 Testing: capability_tiers defined
    cat > "${TEST_TMP}/settings_with_tiers.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru2:
      type: claude
      model: claude-sonnet-4-5-20250929
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  gpt-5.3:
    max_bloom: 4
    cost_group: chatgpt_pro
  claude-sonnet-4-5-20250929:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    # capability_tiers section missing (backward compatibility test)
    cat > "${TEST_TMP}/settings_no_tiers.yaml" << 'YAML'
cli:
  default: claude
  agents:
    ashigaru1:
      type: codex
      model: gpt-5.3-codex-spark
YAML

    # Empty file
    cat > "${TEST_TMP}/settings_empty.yaml" << 'YAML'
YAML

    # YAML syntax error
    cat > "${TEST_TMP}/settings_broken.yaml" << 'YAML'
capability_tiers:
  model: [broken yaml
  agents: {{invalid
YAML

    # For bloom_routing setting test
    cat > "${TEST_TMP}/settings_bloom_auto.yaml" << 'YAML'
bloom_routing: auto
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    cat > "${TEST_TMP}/settings_bloom_manual.yaml" << 'YAML'
bloom_routing: manual
YAML

    cat > "${TEST_TMP}/settings_bloom_off.yaml" << 'YAML'
bloom_routing: "off"
YAML

    cat > "${TEST_TMP}/settings_bloom_invalid.yaml" << 'YAML'
bloom_routing: invalid_value
YAML

    # For cost priority test: different cost_group with same max_bloom
    cat > "${TEST_TMP}/settings_cost_priority.yaml" << 'YAML'
capability_tiers:
  model-chatgpt-a:
    max_bloom: 4
    cost_group: chatgpt_pro
  model-claude-a:
    max_bloom: 4
    cost_group: claude_max
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    # For Subscription pattern test: Claude only pattern
    cat > "${TEST_TMP}/settings_claude_only.yaml" << 'YAML'
cli:
  default: claude
capability_tiers:
  claude-sonnet-4-5-20250929:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    # For Subscription pattern test: ChatGPT only pattern
    cat > "${TEST_TMP}/settings_chatgpt_only.yaml" << 'YAML'
cli:
  default: codex
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  gpt-5.3:
    max_bloom: 4
    cost_group: chatgpt_pro
YAML

    # For Subscription pattern test: available_cost_groups explicitly defined
    cat > "${TEST_TMP}/settings_explicit_groups.yaml" << 'YAML'
cli:
  default: claude
available_cost_groups:
  - claude_max
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  gpt-5.3:
    max_bloom: 4
    cost_group: chatgpt_pro
  claude-sonnet-4-5-20250929:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    # For Subscription pattern test: available_cost_groups chatgpt_pro only
    cat > "${TEST_TMP}/settings_chatgpt_groups.yaml" << 'YAML'
cli:
  default: codex
available_cost_groups:
  - chatgpt_pro
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  gpt-5.3:
    max_bloom: 4
    cost_group: chatgpt_pro
  claude-sonnet-4-5-20250929:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
YAML

    # For Phase 3 Testing: gunshi_analysis.yaml fixture

    # Valid analysis YAML (all fields defined)
    cat > "${TEST_TMP}/analysis_valid.yaml" << 'YAML'
task_id: subtask_test001
timestamp: "2026-02-18T00:00:00+09:00"
analysis:
  bloom_level: 4
  bloom_reasoning: "Bug fix task. Code reading + cause analysis required"
  recommended_model: "gpt-5.3"
  recommended_cli: "codex"
  confidence: 0.85
  quality_criteria:
    - "Existing tests must pass"
    - "Add unit tests for changes"
  qc_method: automated
  pdca_needed: false
YAML

    # #48 fields omitted (#53 area only)
    cat > "${TEST_TMP}/analysis_no48.yaml" << 'YAML'
task_id: subtask_test002
timestamp: "2026-02-18T00:00:00+09:00"
analysis:
  bloom_level: 3
  bloom_reasoning: "Template application task"
  recommended_model: "gpt-5.3-codex-spark"
  recommended_cli: "codex"
  confidence: 0.92
YAML

    # bloom_level out of range
    cat > "${TEST_TMP}/analysis_bad_bloom.yaml" << 'YAML'
task_id: subtask_test003
timestamp: "2026-02-18T00:00:00+09:00"
analysis:
  bloom_level: 7
  bloom_reasoning: "invalid level"
  recommended_model: "gpt-5.3"
  recommended_cli: "codex"
  confidence: 0.5
YAML

    # confidence out of range
    cat > "${TEST_TMP}/analysis_bad_confidence.yaml" << 'YAML'
task_id: subtask_test004
timestamp: "2026-02-18T00:00:00+09:00"
analysis:
  bloom_level: 4
  bloom_reasoning: "normal task"
  recommended_model: "gpt-5.3"
  recommended_cli: "codex"
  confidence: 2.0
YAML

    # For find_agent_for_model test: mixed CLI configuration
    cat > "${TEST_TMP}/settings_mixed_cli.yaml" << 'YAML'
cli:
  default: claude
  agents:
    karo:
      type: claude
      model: claude-sonnet-4-5-20250929
    ashigaru1:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru2:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru3:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru4:
      type: claude
      model: claude-sonnet-4-6
    ashigaru5:
      type: claude
      model: claude-sonnet-4-6
    ashigaru6:
      type: claude
      model: claude-opus-4-6
    ashigaru7:
      type: claude
      model: claude-opus-4-6
    gunshi:
      type: claude
      model: opus
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
bloom_routing: "manual"
YAML

    # For find_agent_for_model test: all Ashigaru Spark
    cat > "${TEST_TMP}/settings_all_spark.yaml" << 'YAML'
cli:
  default: codex
  agents:
    ashigaru1:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru2:
      type: codex
      model: gpt-5.3-codex-spark
    ashigaru3:
      type: codex
      model: gpt-5.3-codex-spark
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
YAML

    # For bloom_model_preference test: standard preference definition (4 levels)
    cat > "${TEST_TMP}/settings_with_preference.yaml" << 'YAML'
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3
    cost_group: claude_max
  gpt-5.3:
    max_bloom: 5
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
  claude-opus-4-6:
    max_bloom: 6
    cost_group: claude_max
bloom_model_preference:
  L1-L2:
    - gpt-5.3-codex-spark
    - claude-haiku-4-5-20251001
  L3:
    - gpt-5.3
    - gpt-5.3-codex-spark
    - claude-haiku-4-5-20251001
  L4-L5:
    - claude-sonnet-4-6
    - gpt-5.3
  L6:
    - claude-opus-4-6
    - claude-sonnet-4-6
YAML

    # For bloom_model_preference test: 1st capability insufficient -> 2nd fallback
    cat > "${TEST_TMP}/settings_preference_cap_fallback.yaml" << 'YAML'
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
bloom_model_preference:
  L4-L5:
    - gpt-5.3-codex-spark
    - claude-sonnet-4-6
YAML

    # For bloom_model_preference test: preference all fail -> fallback to cost_priority
    cat > "${TEST_TMP}/settings_preference_all_fail.yaml" << 'YAML'
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
bloom_model_preference:
  L4-L5:
    - gpt-5.3-codex-spark
    - claude-haiku-4-5-20251001
YAML

    # For bloom_model_preference test: exclude Spark with available_cost_groups=[claude_max]
    cat > "${TEST_TMP}/settings_preference_claude_only.yaml" << 'YAML'
available_cost_groups:
  - claude_max
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3
    cost_group: chatgpt_pro
  claude-haiku-4-5-20251001:
    max_bloom: 3
    cost_group: claude_max
  claude-sonnet-4-6:
    max_bloom: 5
    cost_group: claude_max
bloom_model_preference:
  L1-L3:
    - gpt-5.3-codex-spark
    - claude-haiku-4-5-20251001
YAML

    # Create symlink to .venv
    if [ -d "${PROJECT_ROOT}/.venv" ]; then
        ln -sf "${PROJECT_ROOT}/.venv" "${TEST_TMP}/.venv"
    fi
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: Load cli_adapter with a specific settings.yaml
load_adapter_with() {
    local settings_file="$1"
    export CLI_ADAPTER_SETTINGS="$settings_file"
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
}

# =============================================================================
# TC-DMR-001 to 003: FR-01 settings.yaml capability_tiers section
# =============================================================================

@test "TC-DMR-001: FR-01 capability_tiers basic read - no parse error" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # get_capability_tier is defined (function exists)
    type get_capability_tier &>/dev/null
    # max_bloom of Spark is readable
    result=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result" = "3" ]
}

@test "TC-DMR-002: FR-01 capability_tiers section missing - backward compatibility" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    # Returns default value (6) without error
    result=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result" = "6" ]
}

@test "TC-DMR-003: FR-01 cost_group read" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_cost_group "gpt-5.3-codex-spark")
    [ "$result" = "chatgpt_pro" ]
}

# =============================================================================
# TC-DMR-010-017: FR-02 get_capability_tier()
# =============================================================================

@test "TC-DMR-010: FR-02 Spark -> 3" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result" = "3" ]
}

@test "TC-DMR-011: FR-02 Codex 5.3 -> 4" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "gpt-5.3")
    [ "$result" = "4" ]
}

@test "TC-DMR-012: FR-02 Sonnet Thinking -> 5" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "claude-sonnet-4-5-20250929")
    [ "$result" = "5" ]
}

@test "TC-DMR-013: FR-02 Opus Thinking -> 6" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "claude-opus-4-6")
    [ "$result" = "6" ]
}

@test "TC-DMR-014: FR-02 Undefined model -> 6" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "unknown-model")
    [ "$result" = "6" ]
}

@test "TC-DMR-015: FR-02 capability_tiers section missing -> 6" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result" = "6" ]
}

@test "TC-DMR-016: FR-02 YAML corruption -> 6" {
    load_adapter_with "${TEST_TMP}/settings_broken.yaml"
    result=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result" = "6" ]
}

@test "TC-DMR-017: FR-02 Empty string input -> 6" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_capability_tier "")
    [ "$result" = "6" ]
}

# =============================================================================
# TC-DMR-020-029: FR-03 get_recommended_model()
# =============================================================================

@test "TC-DMR-020: FR-03 L1 -> Spark" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 1)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

@test "TC-DMR-021: FR-03 L2 -> Spark" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 2)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

@test "TC-DMR-022: FR-03 L3 -> Spark" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 3)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

@test "TC-DMR-023: FR-03 L4 -> Codex 5.3" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 4)
    [ "$result" = "gpt-5.3" ]
}

@test "TC-DMR-024: FR-03 L5 -> Sonnet Thinking" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 5)
    [ "$result" = "claude-sonnet-4-5-20250929" ]
}

@test "TC-DMR-025: FR-03 L6 -> Opus Thinking" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 6)
    [ "$result" = "claude-opus-4-6" ]
}

@test "TC-DMR-026: FR-03 capability_tiers section missing -> empty string" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(get_recommended_model 3)
    [ "$result" = "" ]
}

@test "TC-DMR-027: FR-03 Out of range (0) -> exit 1" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run get_recommended_model 0
    [ "$status" -eq 1 ]
}

@test "TC-DMR-028: FR-03 Out of range (7) -> exit 1" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run get_recommended_model 7
    [ "$status" -eq 1 ]
}

@test "TC-DMR-029: FR-03 Cost priority - chatgpt_pro takes priority" {
    load_adapter_with "${TEST_TMP}/settings_cost_priority.yaml"
    result=$(get_recommended_model 4)
    [ "$result" = "model-chatgpt-a" ]
}

# =============================================================================
# TC-DMR-030-033: FR-04 get_cost_group()
# =============================================================================

@test "TC-DMR-030: FR-04 Spark -> chatgpt_pro" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_cost_group "gpt-5.3-codex-spark")
    [ "$result" = "chatgpt_pro" ]
}

@test "TC-DMR-031: FR-04 Opus -> claude_max" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_cost_group "claude-opus-4-6")
    [ "$result" = "claude_max" ]
}

@test "TC-DMR-032: FR-04 Undefined model -> unknown" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_cost_group "unknown-model")
    [ "$result" = "unknown" ]
}

@test "TC-DMR-033: FR-04 capability_tiers section missing -> unknown" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(get_cost_group "gpt-5.3-codex-spark")
    [ "$result" = "unknown" ]
}

# =============================================================================
# TC-DMR-040 to 041: NFR-01 Backward compatibility
# =============================================================================

@test "TC-DMR-040: NFR-01 No regression in existing get_cli_type" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    # Existing functions operate normally even after adding capability_tiers
    result=$(get_cli_type "ashigaru1")
    [ "$result" = "codex" ]
}

@test "TC-DMR-041: NFR-01 No regression in existing get_agent_model" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(get_agent_model "ashigaru1")
    [ "$result" = "gpt-5.3-codex-spark" ]
}

# =============================================================================
# TC-DMR-050: NFR-05 Testability
# =============================================================================

@test "TC-DMR-050: NFR-05 CLI_ADAPTER_SETTINGS injection" {
    # Verify that testing is possible by injecting different settings files
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result1=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result1" = "3" ]

    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result2=$(get_capability_tier "gpt-5.3-codex-spark")
    [ "$result2" = "6" ]
}

# =============================================================================
# TC-DMR-055: NFR-06 Idempotency
# =============================================================================

@test "TC-DMR-055: NFR-06 get_recommended_model returns identical result on sequential calls" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result1=$(get_recommended_model 4)
    result2=$(get_recommended_model 4)
    [ "$result1" = "$result2" ]
}

# =============================================================================
# TC-DMR-220 to 224: FR-09 bloom_routing settings (Phase 3 but pre-testable in L1)
# =============================================================================

@test "TC-DMR-220: FR-09 bloom_routing=auto read" {
    load_adapter_with "${TEST_TMP}/settings_bloom_auto.yaml"
    result=$(_cli_adapter_read_yaml "bloom_routing" "off")
    [ "$result" = "auto" ]
}

@test "TC-DMR-221: FR-09 bloom_routing=manual read" {
    load_adapter_with "${TEST_TMP}/settings_bloom_manual.yaml"
    result=$(_cli_adapter_read_yaml "bloom_routing" "off")
    [ "$result" = "manual" ]
}

@test "TC-DMR-222: FR-09 bloom_routing=off read" {
    load_adapter_with "${TEST_TMP}/settings_bloom_off.yaml"
    result=$(_cli_adapter_read_yaml "bloom_routing" "off")
    [ "$result" = "off" ]
}

@test "TC-DMR-223: FR-09 bloom_routing undefined -> off" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(_cli_adapter_read_yaml "bloom_routing" "off")
    [ "$result" = "off" ]
}

# =============================================================================
# Phase 2: TC-DMR-100-142 — Karo manual model_switch
# =============================================================================

# --- TC-DMR-100 to 103: FR-05 model_switch decision ---

@test "TC-DMR-100: FR-05 Switch unnecessary - bloom=3, model=spark" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run needs_model_switch "gpt-5.3-codex-spark" 3
    [ "$status" -eq 0 ]
    [ "$output" = "no" ]
}

@test "TC-DMR-101: FR-05 Switch necessary - bloom=4, model=spark" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run needs_model_switch "gpt-5.3-codex-spark" 4
    [ "$status" -eq 0 ]
    [ "$output" = "yes" ]
}

@test "TC-DMR-102: FR-05 capability_tiers missing -> skip decision" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    run needs_model_switch "gpt-5.3-codex-spark" 4
    [ "$status" -eq 0 ]
    [ "$output" = "skip" ]
}

@test "TC-DMR-103: FR-05 bloom field missing -> skip decision" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run needs_model_switch "gpt-5.3-codex-spark" ""
    [ "$status" -eq 0 ]
    [ "$output" = "skip" ]
}

# --- TC-DMR-110 to 113: FR-06 model_switch decision logic details ---

@test "TC-DMR-110: FR-06 Switch within same CLI - codex spark -> codex 5.3" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # bloom=4, current=spark(max3) -> recommended=codex5.3(max4), both chatgpt_pro
    result=$(get_switch_recommendation "gpt-5.3-codex-spark" 4)
    [[ "$result" == *"gpt-5.3"* ]]
    [[ "$result" == *"same_cost_group"* ]]
}

@test "TC-DMR-111: FR-06 Cross-CLI - bloom=5, Codex Ashigaru" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # bloom=5, current=spark(chatgpt_pro) -> recommended=sonnet(claude_max) = cross_cost_group
    result=$(get_switch_recommendation "gpt-5.3-codex-spark" 5)
    [[ "$result" == *"claude-sonnet"* ]]
    [[ "$result" == *"cross_cost_group"* ]]
}

@test "TC-DMR-112: FR-06 Keeps current model when switch is unnecessary" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # bloom=3, current=spark(max3) -> sufficient, no switch
    result=$(get_switch_recommendation "gpt-5.3-codex-spark" 3)
    [ "$result" = "no_switch" ]
}

@test "TC-DMR-113: FR-06 Reaches Opus at bloom=6" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_switch_recommendation "gpt-5.3-codex-spark" 6)
    [[ "$result" == *"claude-opus-4-6"* ]]
}

# --- TC-DMR-120 to 121: NFR-02 Response latency ---

@test "TC-DMR-120: NFR-02 get_capability_tier response latency within 500ms" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    start=$(date +%s%N)
    get_capability_tier "gpt-5.3-codex-spark" > /dev/null
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    [ "$elapsed_ms" -lt 500 ]
}

@test "TC-DMR-121: NFR-02 get_recommended_model response latency within 500ms" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    start=$(date +%s%N)
    get_recommended_model 4 > /dev/null
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    [ "$elapsed_ms" -lt 500 ]
}

# --- TC-DMR-130 to 131: NFR-03 CLI compatibility ---

@test "TC-DMR-130: NFR-03 model_switch is only active for Claude Ashigaru" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # Codex Ashigaru: switch is possible but watch out for cross-CLI
    result=$(can_model_switch "codex")
    [ "$result" = "limited" ]
}

@test "TC-DMR-131: NFR-03 Claude Ashigaru can full switch" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(can_model_switch "claude")
    [ "$result" = "full" ]
}

# --- TC-DMR-140 to 142: NFR-04 Cost optimization ---

@test "TC-DMR-140: NFR-04 Opus not used for L3" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 3)
    [ "$result" != "claude-opus-4-6" ]
}

@test "TC-DMR-141: NFR-04 chatgpt_pro prioritized" {
    load_adapter_with "${TEST_TMP}/settings_cost_priority.yaml"
    result=$(get_recommended_model 4)
    cg=$(get_cost_group "$result")
    [ "$cg" = "chatgpt_pro" ]
}

@test "TC-DMR-142: NFR-04 Suppress unnecessary switch" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # current model can handle bloom level → no switch
    run needs_model_switch "gpt-5.3" 4
    [ "$output" = "no" ]
}

# =============================================================================
# Phase 3: TC-DMR-200-224 — Gunshi Bloom analysis layer
# =============================================================================

# --- TC-DMR-200 to 203: FR-07 gunshi_analysis.yaml schema ---

@test "TC-DMR-200: FR-07 Normal YAML - all fields defined" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run validate_gunshi_analysis "${TEST_TMP}/analysis_valid.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "valid" ]
}

@test "TC-DMR-201: FR-07 #48 fields omitted - no parse error" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run validate_gunshi_analysis "${TEST_TMP}/analysis_no48.yaml"
    [ "$status" -eq 0 ]
    [ "$output" = "valid" ]
}

@test "TC-DMR-202: FR-07 bloom_level out of range(0,7) — validation error" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run validate_gunshi_analysis "${TEST_TMP}/analysis_bad_bloom.yaml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bloom_level"* ]]
}

@test "TC-DMR-203: FR-07 confidence out of range(-1, 2.0) — validation error" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    run validate_gunshi_analysis "${TEST_TMP}/analysis_bad_confidence.yaml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"confidence"* ]]
}

# --- TC-DMR-210 to 214: FR-08 Bloom analysis trigger decision logic ---
# Extracts and tests decision logic part of L2 integration tests into L1 functions

@test "TC-DMR-210: FR-08 auto -> Analyze all tasks trigger" {
    load_adapter_with "${TEST_TMP}/settings_bloom_auto.yaml"
    result=$(should_trigger_bloom_analysis "auto" "false")
    [ "$result" = "yes" ]
}

@test "TC-DMR-211: FR-08 manual + required=true -> Analyze trigger" {
    load_adapter_with "${TEST_TMP}/settings_bloom_manual.yaml"
    result=$(should_trigger_bloom_analysis "manual" "true")
    [ "$result" = "yes" ]
}

@test "TC-DMR-211b: FR-08 manual + required=false -> No trigger" {
    load_adapter_with "${TEST_TMP}/settings_bloom_manual.yaml"
    result=$(should_trigger_bloom_analysis "manual" "false")
    [ "$result" = "no" ]
}

@test "TC-DMR-212: FR-08 off -> No analysis" {
    load_adapter_with "${TEST_TMP}/settings_bloom_off.yaml"
    result=$(should_trigger_bloom_analysis "off" "true")
    [ "$result" = "no" ]
}

@test "TC-DMR-213: FR-08 bloom_routing undefined -> treated as off -> no analysis" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    # bloom_routing not set → get_bloom_routing returns "off"
    routing=$(get_bloom_routing)
    result=$(should_trigger_bloom_analysis "$routing" "true")
    [ "$result" = "no" ]
}

@test "TC-DMR-214: FR-08 should_trigger_bloom_analysis fallback argument" {
    load_adapter_with "${TEST_TMP}/settings_bloom_auto.yaml"
    # gunshi_available=no → fallback to Phase 2
    result=$(should_trigger_bloom_analysis "auto" "false" "no")
    [ "$result" = "fallback" ]
}

# --- TC-DMR-224: FR-09 Invalid value -> off + stderr warning ---

@test "TC-DMR-224: FR-09 bloom_routing invalid value -> off + stderr warning" {
    load_adapter_with "${TEST_TMP}/settings_bloom_invalid.yaml"
    result=$(get_bloom_routing 2>/tmp/dmr_stderr_test)
    [ "$result" = "off" ]
    # Warning output to stderr
    grep -q "bloom_routing" /tmp/dmr_stderr_test || grep -q "invalid" /tmp/dmr_stderr_test
    rm -f /tmp/dmr_stderr_test
}

# =============================================================================
# Phase 4: TC-DMR-300 to 303 - Full auto-selection (Quality feedback)
# =============================================================================

@test "TC-DMR-300: FR-10 History append - append 1 line to model_performance.yaml" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    local perf_file="${TEST_TMP}/model_performance.yaml"
    # Initial append
    run append_model_performance "$perf_file" "subtask_001" "seo_article" 3 "gpt-5.3-codex-spark" "pass" 0.85
    [ "$status" -eq 0 ]
    # File is created, 1 history entry exists
    run "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml
with open('${perf_file}') as f:
    doc = yaml.safe_load(f)
print(len(doc.get('history', [])))
"
    [ "$output" = "1" ]
}

@test "TC-DMR-301: FR-10 History read - aggregation by task_type x bloom_level" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    local perf_file="${TEST_TMP}/model_performance.yaml"
    # Append 3 entries
    append_model_performance "$perf_file" "subtask_001" "seo_article" 3 "gpt-5.3-codex-spark" "pass" 0.90
    append_model_performance "$perf_file" "subtask_002" "seo_article" 3 "gpt-5.3-codex-spark" "pass" 0.85
    append_model_performance "$perf_file" "subtask_003" "seo_article" 3 "gpt-5.3-codex-spark" "fail" 0.40
    # Aggregation: seo_article x bloom3 -> 3 entries
    result=$(get_model_performance_summary "$perf_file" "seo_article" 3)
    [[ "$result" == *"total:3"* ]]
    [[ "$result" == *"pass:2"* ]]
}

@test "TC-DMR-302: FR-10 Empty file - no errors even if model_performance.yaml is missing" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    local perf_file="${TEST_TMP}/nonexistent_performance.yaml"
    run get_model_performance_summary "$perf_file" "seo_article" 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"total:0"* ]]
}

@test "TC-DMR-303: FR-10 Suitability calculation - pass rate can be calculated" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    local perf_file="${TEST_TMP}/model_performance.yaml"
    # 4 cases: 3 pass, 1 fail -> pass_rate=0.75
    append_model_performance "$perf_file" "subtask_001" "bugfix" 4 "gpt-5.3" "pass" 0.90
    append_model_performance "$perf_file" "subtask_002" "bugfix" 4 "gpt-5.3" "pass" 0.85
    append_model_performance "$perf_file" "subtask_003" "bugfix" 4 "gpt-5.3" "pass" 0.80
    append_model_performance "$perf_file" "subtask_004" "bugfix" 4 "gpt-5.3" "fail" 0.30
    result=$(get_model_performance_summary "$perf_file" "bugfix" 4)
    [[ "$result" == *"pass_rate:0.75"* ]]
}

# =============================================================================
# Subscription Patterns: TC-DMR-400-423
# Support user contract pattern (Claude only / ChatGPT only / Both)
# =============================================================================

# --- TC-DMR-400-402: get_available_cost_groups ---

@test "TC-DMR-400: get_available_cost_groups - explicitly defined claude_max only" {
    load_adapter_with "${TEST_TMP}/settings_explicit_groups.yaml"
    result=$(get_available_cost_groups)
    [ "$result" = "claude_max" ]
}

@test "TC-DMR-401: get_available_cost_groups - automatically estimated from capability_tiers when omitted" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_available_cost_groups)
    # Both cost_groups included (order independent)
    [[ "$result" == *"chatgpt_pro"* ]]
    [[ "$result" == *"claude_max"* ]]
}

@test "TC-DMR-402: get_available_cost_groups - capability_tiers missing -> empty" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(get_available_cost_groups)
    [ "$result" = "" ]
}

@test "TC-DMR-403: get_available_cost_groups - auto-estimation of Claude only" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(get_available_cost_groups)
    [ "$result" = "claude_max" ]
}

@test "TC-DMR-404: get_available_cost_groups - auto-estimation of ChatGPT only" {
    load_adapter_with "${TEST_TMP}/settings_chatgpt_only.yaml"
    result=$(get_available_cost_groups)
    [ "$result" = "chatgpt_pro" ]
}

# --- TC-DMR-410 to 413: get_recommended_model - action per contract pattern ---

@test "TC-DMR-410: Claude only - L3 -> sonnet + overqualified warning" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(get_recommended_model 3 2>/tmp/dmr_410_stderr)
    [ "$result" = "claude-sonnet-4-5-20250929" ]
    # overqualified warning in stderr
    grep -q "overqualified" /tmp/dmr_410_stderr
    rm -f /tmp/dmr_410_stderr
}

@test "TC-DMR-411: ChatGPT only - L5 -> gpt-5.3 + insufficient warning" {
    load_adapter_with "${TEST_TMP}/settings_chatgpt_only.yaml"
    result=$(get_recommended_model 5 2>/tmp/dmr_411_stderr)
    [ "$result" = "gpt-5.3" ]
    # insufficient warning in stderr
    grep -q "insufficient" /tmp/dmr_411_stderr
    rm -f /tmp/dmr_411_stderr
}

@test "TC-DMR-412: available_cost_groups=claude_max -> exclude chatgpt_pro models from candidates" {
    load_adapter_with "${TEST_TMP}/settings_explicit_groups.yaml"
    # Even at L3, chatgpt_pro model (Spark) is excluded, sonnet of claude_max is selected
    result=$(get_recommended_model 3)
    [[ "$result" == "claude-sonnet-4-5-20250929" ]]
}

@test "TC-DMR-413: available_cost_groups=chatgpt_pro -> exclude claude_max models from candidates" {
    load_adapter_with "${TEST_TMP}/settings_chatgpt_groups.yaml"
    # Even at L5, claude_max model (Sonnet) is excluded, maximum gpt-5.3 of chatgpt_pro is selected
    result=$(get_recommended_model 5 2>/dev/null)
    [ "$result" = "gpt-5.3" ]
}

@test "TC-DMR-414: Both contracted - L3 -> Spark (cheapest option selected as before)" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(get_recommended_model 3)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

# --- TC-DMR-420-423: validate_subscription_coverage ---

@test "TC-DMR-420: validate_subscription_coverage - covers all Bloom -> ok" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    result=$(validate_subscription_coverage)
    [ "$result" = "ok" ]
}

@test "TC-DMR-421: validate_subscription_coverage — ChatGPT only → gap:5,6" {
    load_adapter_with "${TEST_TMP}/settings_chatgpt_only.yaml"
    result=$(validate_subscription_coverage)
    [[ "$result" == *"gap"* ]]
    [[ "$result" == *"5"* ]]
    [[ "$result" == *"6"* ]]
}

@test "TC-DMR-422: validate_subscription_coverage - Claude only -> covered (has L5+L6)" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(validate_subscription_coverage)
    # All L1-L6 can be covered by Sonnet(L5)+Opus(L6) (overqualified but supported)
    [ "$result" = "ok" ]
}

@test "TC-DMR-423: validate_subscription_coverage - capability_tiers missing -> unconfigured" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    result=$(validate_subscription_coverage)
    [ "$result" = "unconfigured" ]
}

# ============================================================
# TC-FAM-001 to 009: find_agent_for_model() - Phase 2 Unit Test
# ============================================================
# NOTE: tmux session does not exist in unit test environment.
#       pane_target is empty -> returns first candidate immediately (by design).
#       tmux integration is verified in E2E tests.

@test "TC-FAM-001: Ashigaru with exact match exists -> returns ashigaru1 (Spark)" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    result=$(find_agent_for_model "gpt-5.3-codex-spark")
    [ "$result" = "ashigaru1" ]
}

@test "TC-FAM-002: Sonnet Ashigaru exists -> returns ashigaru4" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    result=$(find_agent_for_model "claude-sonnet-4-6")
    [ "$result" = "ashigaru4" ]
}

@test "TC-FAM-003: Opus Ashigaru exists -> returns ashigaru6" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    result=$(find_agent_for_model "claude-opus-4-6")
    [ "$result" = "ashigaru6" ]
}

@test "TC-FAM-004: No Ashigaru with matching model + other Ashigaru exist -> fallback (any Ashigaru)" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    result=$(find_agent_for_model "gpt-5.1-codex-max")
    # No exact match -> returns Ashigaru with smallest index as fallback
    [ -n "$result" ]
    [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

@test "TC-FAM-005: No arguments -> exit code 1" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    run find_agent_for_model
    [ "$status" -eq 1 ]
}

@test "TC-FAM-006: Empty string argument -> exit code 1" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    run find_agent_for_model ""
    [ "$status" -eq 1 ]
}

@test "TC-FAM-007: Multiple Ashigaru with same model -> returns smallest index (ashigaru1)" {
    load_adapter_with "${TEST_TMP}/settings_all_spark.yaml"
    result=$(find_agent_for_model "gpt-5.3-codex-spark")
    [ "$result" = "ashigaru1" ]
}

@test "TC-FAM-008: Works even with no capability_tiers settings (backward compatibility)" {
    load_adapter_with "${TEST_TMP}/settings_no_tiers.yaml"
    # Even with no_tiers, if agents are defined, search and return Spark Ashigaru
    result=$(find_agent_for_model "gpt-5.3-codex-spark")
    [ "$result" = "ashigaru1" ]
}

@test "TC-FAM-009: Only Ashigaru are target (Karo, Gunshi are excluded)" {
    load_adapter_with "${TEST_TMP}/settings_mixed_cli.yaml"
    # Specifying model of Karo/Gunshi -> no match among Ashigaru -> fallback or first candidate
    result=$(find_agent_for_model "claude-sonnet-4-5-20250929")
    # Karo (claude-sonnet-4-5-20250929) is not included in the candidates
    # Fallback because no other Ashigaru has this model
    [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

# =============================================================================
# TC-PREF-001 to 007: bloom_model_preference routing
# =============================================================================

@test "TC-PREF-001: preference defined → first choice selected (range key L1-L2)" {
    load_adapter_with "${TEST_TMP}/settings_with_preference.yaml"
    # bloom_level=2, 1st in L1-L2 is gpt-5.3-codex-spark
    result=$(get_recommended_model 2)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

@test "TC-PREF-002: first preference capability insufficient → fallback to second" {
    load_adapter_with "${TEST_TMP}/settings_preference_cap_fallback.yaml"
    # bloom_level=4, 1st in L4-L5 is gpt-5.3-codex-spark(max_bloom=3 < 4) -> skip
    # 2nd is claude-sonnet-4-6(max_bloom=5 >= 4) -> selected
    result=$(get_recommended_model 4)
    [ "$result" = "claude-sonnet-4-6" ]
}

@test "TC-PREF-003: no preference defined → legacy cost_priority behavior" {
    load_adapter_with "${TEST_TMP}/settings_with_tiers.yaml"
    # settings_with_tiers.yaml has no bloom_model_preference -> legacy behavior
    # bloom_level=4: gpt-5.3(mb4,chatgpt_pro=0) vs sonnet(mb5,claude_max=1)
    # cost_priority: chatgpt_pro=0 prioritized -> gpt-5.3
    result=$(get_recommended_model 4)
    [ "$result" = "gpt-5.3" ]
}

@test "TC-PREF-004: single key L3 matches bloom_level=3 → gpt-5.3 selected" {
    load_adapter_with "${TEST_TMP}/settings_with_preference.yaml"
    # bloom_level=3, 1st in L3 (single key) is gpt-5.3
    result=$(get_recommended_model 3)
    [ "$result" = "gpt-5.3" ]
}

@test "TC-PREF-005: all preferred models unavailable → fallback to cost_priority with warning" {
    load_adapter_with "${TEST_TMP}/settings_preference_all_fail.yaml"
    # bloom=4, L4-L5: [spark(max3<4), haiku(max3<4)] -> all fail -> fallback
    # cost_priority fallback: only claude-sonnet-4-6(mb5,claude_max) is candidate
    result=$(get_recommended_model 4 2>/dev/null)
    [ "$result" = "claude-sonnet-4-6" ]
    # WARNING is output to stderr
    run bash -c "export CLI_ADAPTER_SETTINGS='${TEST_TMP}/settings_preference_all_fail.yaml'; export CLI_ADAPTER_PROJECT_ROOT='${PROJECT_ROOT}'; source '${PROJECT_ROOT}/lib/cli_adapter.sh' 2>/dev/null; get_recommended_model 4 2>&1 1>/dev/null"
    [[ "$output" =~ "WARNING" ]]
}

@test "TC-PREF-006: available_cost_groups exclusion with preference → skip excluded model, use next" {
    load_adapter_with "${TEST_TMP}/settings_preference_claude_only.yaml"
    # available_cost_groups=[claude_max] -> chatgpt_pro models excluded
    # bloom=2, L1-L2: [spark(chatgpt_pro -> excluded), haiku(claude_max -> OK)]
    result=$(get_recommended_model 2)
    [ "$result" = "claude-haiku-4-5-20251001" ]
}

@test "TC-PREF-007: no available_cost_groups → all models are candidates for preference" {
    load_adapter_with "${TEST_TMP}/settings_with_preference.yaml"
    # available_cost_groups undefined -> all cost_groups permitted
    # bloom=2, 1st in L1-L2 = gpt-5.3-codex-spark(chatgpt_pro) -> selected without exclusion
    result=$(get_recommended_model 2)
    [ "$result" = "gpt-5.3-codex-spark" ]
}

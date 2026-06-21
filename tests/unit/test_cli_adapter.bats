#!/usr/bin/env bats
# test_cli_adapter.bats — cli_adapter.sh Unit Test
# Multi-CLI Integration Design Spec §4.1 Compliant

# --- Setup ---

setup() {
    unset PERMISSION_FLAG

    # Tmp directory for testing
    TEST_TMP="$(mktemp -d)"

    # Project root
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # Default settings (no cli section = backward compatibility test)
    cat > "${TEST_TMP}/settings_none.yaml" << 'YAML'
language: ja
shell: bash
display_mode: shout
YAML

    # claude only settings
    cat > "${TEST_TMP}/settings_claude_only.yaml" << 'YAML'
cli:
  default: claude
YAML

    # mixed CLI settings (dict format)
    cat > "${TEST_TMP}/settings_mixed.yaml" << 'YAML'
cli:
  default: claude
  agents:
    shogun:
      type: claude
      model: opus
    orchestrator:
      type: claude
      model: opus
    explorer:
      type: claude
      model: sonnet
    librarian:
      type: claude
      model: sonnet
    designer:
      type: claude
      model: sonnet
    fixer:
      type: claude
      model: sonnet
    observer:
      type: codex
    oracle:
      type: codex
    council:
      type: copilot
    ashigaru8:
      type: copilot
YAML

    # String format of agent setting
    cat > "${TEST_TMP}/settings_string_agents.yaml" << 'YAML'
cli:
  default: claude
  agents:
    observer: codex
    council: copilot
YAML

    # Invalid CLI name
    cat > "${TEST_TMP}/settings_invalid_cli.yaml" << 'YAML'
cli:
  default: claudee
  agents:
    explorer: invalid_cli
YAML

    # Codex default
    cat > "${TEST_TMP}/settings_codex_default.yaml" << 'YAML'
cli:
  default: codex
YAML

    # Empty file
    cat > "${TEST_TMP}/settings_empty.yaml" << 'YAML'
YAML

    # YAML syntax error
    cat > "${TEST_TMP}/settings_broken.yaml" << 'YAML'
cli:
  default: [broken yaml
  agents: {{invalid
YAML

    # With model specified
    cat > "${TEST_TMP}/settings_with_models.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: haiku
    observer:
      type: codex
      model: gpt-5
models:
  orchestrator: sonnet
YAML

    # kimi CLI settings
    cat > "${TEST_TMP}/settings_kimi.yaml" << 'YAML'
cli:
  default: claude
  agents:
    designer:
      type: kimi
      model: k2.5
    fixer:
      type: kimi
YAML

    # kimi default settings
    cat > "${TEST_TMP}/settings_kimi_default.yaml" << 'YAML'
cli:
  default: kimi
YAML

    # opencode settings
    cat > "${TEST_TMP}/settings_opencode.yaml" << 'YAML'
cli:
  default: opencode
  agents:
    shogun:
      type: opencode
      model: openai/gpt-5.4-mini
    orchestrator:
      type: opencode
      model: gpt-5.4
    oracle:
      type: opencode
      model: anthropic/claude-opus-4-6
    explorer:
      type: opencode
      model: k2.5
    librarian:
      type: opencode
      model: moonshot-k2.5
    designer:
      type: opencode
      model: claude-sonnet-4-6
    fixer:
      type: opencode
      model: gpt-5.3-codex-spark
    observer:
      type: opencode
      model: openrouter/minimax/minimax-m2.5
      variant: xhigh
YAML

    # antigravity settings
    cat > "${TEST_TMP}/settings_antigravity.yaml" << 'YAML'
cli:
  default: antigravity
  agents:
    shogun:
      type: antigravity
    orchestrator:
      type: agy
      model: gemini-latest
    explorer:
      type: gemini
YAML
}

# =============================================================================
# normalize_opencode_model / shell quote tests
# =============================================================================

@test "normalize_opencode_model: empty string -> empty string" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(normalize_opencode_model "")
    [ "$result" = "" ]
}

@test "normalize_opencode_model: normalize known alias to provider/model" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model gpt-5.4-mini)" = "openai/gpt-5.4-mini" ]
    [ "$(normalize_opencode_model gpt-5.3-codex-spark)" = "openai/gpt-5.3-codex-spark" ]
    [ "$(normalize_opencode_model opus)" = "anthropic/claude-opus-4-6" ]
    [ "$(normalize_opencode_model sonnet)" = "anthropic/claude-sonnet-4-6" ]
    [ "$(normalize_opencode_model haiku)" = "anthropic/claude-haiku-4-5-20251001" ]
    [ "$(normalize_opencode_model k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model moonshot-k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model kimi-k2.5)" = "moonshot/kimi-k2.5" ]
    [ "$(normalize_opencode_model kimi-k2-turbo)" = "moonshot/kimi-k2-turbo" ]
}

@test "normalize_opencode_model: provider-qualified and unknown models left intact" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    [ "$(normalize_opencode_model anthropic/claude-sonnet-4-6)" = "anthropic/claude-sonnet-4-6" ]
    [ "$(normalize_opencode_model custom-provider/custom-model)" = "custom-provider/custom-model" ]
    [ "$(normalize_opencode_model unknown-model)" = "unknown-model" ]
}

@test "_cli_adapter_shell_quote: fallback to bash quote when .venv is missing" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    CLI_ADAPTER_PROJECT_ROOT="${TEST_TMP}/no_venv_root"
    mkdir -p "$CLI_ADAPTER_PROJECT_ROOT"

    sample='path with spaces $HOME'
    quoted=$(_cli_adapter_shell_quote "$sample")
    eval "roundtrip=$quoted"

    [ "$roundtrip" = "$sample" ]
}

teardown() {
    unset PERMISSION_FLAG
    rm -rf "$TEST_TMP"
}

# Helper: Load cli_adapter with a specific settings.yaml
load_adapter_with() {
    local settings_file="$1"
    export CLI_ADAPTER_SETTINGS="$settings_file"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
}

# =============================================================================
# get_cli_type tests
# =============================================================================

# --- Normal cases ---

@test "get_cli_type: no cli section -> claude (backward compatibility)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: claude only configuration -> claude" {
    load_adapter_with "${TEST_TMP}/settings_claude_only.yaml"
    result=$(get_cli_type "explorer")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed config shogun -> claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: mixed config observer -> codex" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "observer")
    [ "$result" = "codex" ]
}

@test "get_cli_type: mixed config council -> copilot" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "council")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: mixed config explorer -> claude (individual config)" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "explorer")
    [ "$result" = "claude" ]
}

@test "get_cli_type: string format observer -> codex" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "observer")
    [ "$result" = "codex" ]
}

@test "get_cli_type: string format council -> copilot" {
    load_adapter_with "${TEST_TMP}/settings_string_agents.yaml"
    result=$(get_cli_type "council")
    [ "$result" = "copilot" ]
}

@test "get_cli_type: kimi config designer -> kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "designer")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: kimi config fixer -> kimi (no model specified)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_cli_type "fixer")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: default settings kimi -> kimi" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_cli_type "explorer")
    [ "$result" = "kimi" ]
}

@test "get_cli_type: opencode config shogun -> opencode" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "opencode" ]
}

@test "get_cli_type: opencode default → opencode" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_cli_type "unknown_agent")
    [ "$result" = "opencode" ]
}

@test "get_cli_type: antigravity and legacy alias -> antigravity" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    [ "$(get_cli_type shogun)" = "antigravity" ]
    [ "$(get_cli_type orchestrator)" = "antigravity" ]
    [ "$(get_cli_type explorer)" = "antigravity" ]
    [ "$(get_cli_type librarian)" = "antigravity" ]
}

@test "get_cli_type: undefined agent -> inherits default" {
    load_adapter_with "${TEST_TMP}/settings_codex_default.yaml"
    result=$(get_cli_type "designer")
    [ "$result" = "codex" ]
}

@test "get_cli_type: empty agent_id -> claude" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_cli_type "")
    [ "$result" = "claude" ]
}

# --- All Ashigaru patterns ---

@test "get_cli_type: mixed configuration explorer-8 all patterns" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    [ "$(get_cli_type explorer)" = "claude" ]
    [ "$(get_cli_type librarian)" = "claude" ]
    [ "$(get_cli_type designer)" = "claude" ]
    [ "$(get_cli_type fixer)" = "claude" ]
    [ "$(get_cli_type observer)" = "codex" ]
    [ "$(get_cli_type oracle)" = "codex" ]
    [ "$(get_cli_type council)" = "copilot" ]
    [ "$(get_cli_type ashigaru8)" = "copilot" ]
}

# --- Error cases ---

@test "get_cli_type: Invalid CLI name -> claude fallback" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "explorer")
    [ "$result" = "claude" ]
}

@test "get_cli_type: Invalid default -> claude fallback" {
    load_adapter_with "${TEST_TMP}/settings_invalid_cli.yaml"
    result=$(get_cli_type "orchestrator")
    [ "$result" = "claude" ]
}

@test "get_cli_type: Empty YAML file -> claude" {
    load_adapter_with "${TEST_TMP}/settings_empty.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

@test "get_cli_type: YAML syntax error -> claude" {
    load_adapter_with "${TEST_TMP}/settings_broken.yaml"
    result=$(get_cli_type "explorer")
    [ "$result" = "claude" ]
}

@test "get_cli_type: Nonexistent file -> claude" {
    load_adapter_with "/nonexistent/path/settings.yaml"
    result=$(get_cli_type "shogun")
    [ "$result" = "claude" ]
}

# =============================================================================
# build_cli_command tests
# =============================================================================

@test "build_cli_command: claude + model → claude --model opus --dangerously-skip-permissions" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "shogun")
    [ "$result" = "claude --model opus --dangerously-skip-permissions" ]
}

@test "build_cli_command: PERMISSION_FLAG override → claude --permission-mode auto-approved" {
    PERMISSION_FLAG="--permission-mode auto-approved"
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "shogun")
    [ "$result" = "claude --model opus --permission-mode auto-approved" ]
}

@test "build_cli_command: claude + effort:max → --effort max" {
    cat > "${TEST_TMP}/settings_claude_effort.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-opus-4-8
      effort: max
YAML
    load_adapter_with "${TEST_TMP}/settings_claude_effort.yaml"
    result=$(build_cli_command "explorer")
    [ "$result" = "claude --model claude-opus-4-8 --effort max --dangerously-skip-permissions" ]
}

@test "build_cli_command: codex + default model → codex --model sonnet ..." {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    expected_prompt_arg=$(get_startup_prompt_arg "observer")
    result=$(build_cli_command "observer")
    [ "$result" = "codex --model sonnet --search --dangerously-bypass-approvals-and-sandbox --no-alt-screen $expected_prompt_arg" ]
}

@test "build_cli_command: copilot → copilot --yolo" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(build_cli_command "council")
    [ "$result" = "copilot --yolo" ]
}

@test "build_cli_command: kimi + model → kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "designer")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: kimi (no model specified) -> kimi --yolo --model k2.5" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(build_cli_command "fixer")
    [ "$result" = "kimi --yolo --model k2.5" ]
}

@test "build_cli_command: opencode shogun → --agent shogun + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "shogun")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=shogun OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openai/gpt-5.4-mini --agent shogun'* ]]
    # No OPENCODE_CONFIG_CONTENT — permissions are in .opencode/agents/shogun.md
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    # No --prompt — system prompt loaded from .opencode/agents/shogun.md
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode orchestrator → --agent orchestrator + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "orchestrator")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=orchestrator OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openai/gpt-5.4 --agent orchestrator'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode specialist → --agent explorer + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "explorer")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=explorer OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model moonshot/kimi-k2.5 --agent explorer'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode oracle → --agent oracle + pinned tui config" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "oracle")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=oracle OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model anthropic/claude-opus-4-6 --agent oracle'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: opencode deterministic output" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    first=$(build_cli_command "designer")
    second=$(build_cli_command "designer")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$first" == "$second" ]]
    [[ "$first" == "OPENCODE_AGENT_ID=designer OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$first" == *'opencode --model anthropic/claude-sonnet-4-6 --agent designer'* ]]
    [[ "$first" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$first" != *'--prompt'* ]]
}

@test "build_cli_command: opencode omits provider-specific variant from TUI args" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(build_cli_command "observer")
    expected_tui_config=$(_cli_adapter_shell_quote "${PROJECT_ROOT}/config/opencode-tui.json")
    [[ "$result" == "OPENCODE_AGENT_ID=observer OPENCODE_TUI_CONFIG=$expected_tui_config"* ]]
    [[ "$result" == *'opencode --model openrouter/minimax/minimax-m2.5 --agent observer-runtime'* ]]
    [[ "$result" != *'--variant'* ]]
    [[ "$result" != *'OPENCODE_CONFIG_CONTENT'* ]]
    [[ "$result" != *'--prompt'* ]]
}

@test "build_cli_command: antigravity default model uses host default" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(build_cli_command "shogun")
    [ "$result" = "agy --dangerously-skip-permissions" ]
}

@test "build_cli_command: antigravity explicit model passes --model" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(build_cli_command "orchestrator")
    [ "$result" = "agy --dangerously-skip-permissions --model gemini-latest" ]
}

@test "opencode tui config pins app_exit and keybinds" {
    grep -q '"app_exit": "none"' "${PROJECT_ROOT}/config/opencode-tui.json"
    grep -q '"session_interrupt": "escape"' "${PROJECT_ROOT}/config/opencode-tui.json"
    grep -q '"input_clear": "ctrl+c,ctrl+u"' "${PROJECT_ROOT}/config/opencode-tui.json"
}

@test "build_cli_command: no cli section -> claude fallback" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(build_cli_command "explorer")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

@test "build_cli_command: settings read failed -> claude fallback" {
    load_adapter_with "/nonexistent/settings.yaml"
    result=$(build_cli_command "explorer")
    [[ "$result" == claude*--dangerously-skip-permissions ]]
}

# =============================================================================
# get_instruction_file tests
# =============================================================================

@test "get_instruction_file: shogun + claude → instructions/shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/shogun.md" ]
}

@test "get_instruction_file: orchestrator + claude → instructions/orchestrator.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "orchestrator")
    [ "$result" = "instructions/orchestrator.md" ]
}

@test "get_instruction_file: explorer + claude → instructions/explorer.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "explorer")
    [ "$result" = "instructions/explorer.md" ]
}

@test "get_instruction_file: observer + codex → instructions/codex-observer.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "observer")
    [ "$result" = "instructions/codex-observer.md" ]
}

@test "get_instruction_file: council + copilot → instructions/generated/copilot-council.md" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_instruction_file "council")
    [ "$result" = "instructions/generated/copilot-council.md" ]
}

@test "get_instruction_file: designer + kimi → instructions/generated/kimi-designer.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_instruction_file "designer")
    [ "$result" = "instructions/generated/kimi-designer.md" ]
}

@test "get_instruction_file: shogun + kimi → instructions/generated/kimi-shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/generated/kimi-shogun.md" ]
}

@test "get_instruction_file: explicit spec via cli_type argument (codex)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "shogun" "codex")
    [ "$result" = "instructions/codex-shogun.md" ]
}

@test "get_instruction_file: explicit spec via cli_type argument (copilot)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_instruction_file "orchestrator" "copilot")
    [ "$result" = "instructions/generated/copilot-orchestrator.md" ]
}

@test "get_instruction_file: all CLI x all role combinations" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # claude
    [ "$(get_instruction_file shogun claude)" = "instructions/shogun.md" ]
    [ "$(get_instruction_file orchestrator claude)" = "instructions/orchestrator.md" ]
    [ "$(get_instruction_file explorer claude)" = "instructions/explorer.md" ]
    # codex
    [ "$(get_instruction_file shogun codex)" = "instructions/codex-shogun.md" ]
    [ "$(get_instruction_file orchestrator codex)" = "instructions/codex-orchestrator.md" ]
    [ "$(get_instruction_file designer codex)" = "instructions/codex-designer.md" ]
    # copilot
    [ "$(get_instruction_file shogun copilot)" = "instructions/generated/copilot-shogun.md" ]
    [ "$(get_instruction_file orchestrator copilot)" = "instructions/generated/copilot-orchestrator.md" ]
    [ "$(get_instruction_file observer copilot)" = "instructions/generated/copilot-observer.md" ]
    # kimi
    [ "$(get_instruction_file shogun kimi)" = "instructions/generated/kimi-shogun.md" ]
    [ "$(get_instruction_file orchestrator kimi)" = "instructions/generated/kimi-orchestrator.md" ]
    [ "$(get_instruction_file council kimi)" = "instructions/generated/kimi-council.md" ]
}

@test "get_instruction_file: unknown agent_id -> empty string + return 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run get_instruction_file "unknown_agent"
    [ "$status" -eq 1 ]
}

@test "get_instruction_file: copilot paths resolve to existing files (regression: bug #1)" {
    # Regression for the cli_adapter.sh path bug: copilot used to return
    # .github/copilot-instructions-{role}.md, which the build never created.
    # The path now must point at instructions/generated/copilot-{role}.md,
    # which build_instructions.sh actually emits.
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    for role in shogun orchestrator explorer librarian oracle designer fixer observer council telegram; do
        result=$(get_instruction_file "$role" "copilot")
        [ "$result" = "instructions/generated/copilot-${role}.md" ] || {
            echo "FAIL: role=$role got=$result"
            return 1
        }
        [ -f "${PROJECT_ROOT}/${result}" ] || {
            echo "FAIL: file missing for role=$role: ${result}"
            return 1
        }
    done
}

@test "get_instruction_file: opencode + any role → instructions/generated/opencode-shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/generated/opencode-shogun.md" ]
}

@test "get_instruction_file: antigravity + any role → instructions/generated/antigravity-shogun.md" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(get_instruction_file "shogun")
    [ "$result" = "instructions/generated/antigravity-shogun.md" ]
}

# =============================================================================
# get_startup_prompt tests
# =============================================================================

@test "get_startup_prompt: opencode shogun → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "shogun")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode orchestrator → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "orchestrator")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode oracle → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "oracle")
    [ -z "$result" ]
}

@test "get_startup_prompt: opencode explorer → empty (uses --agent, no prompt needed)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt "explorer")
    [ -z "$result" ]
}

@test "get_startup_prompt: antigravity → empty (uses CLI defaults)" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(get_startup_prompt "shogun")
    [ -z "$result" ]
}

# =============================================================================
# get_startup_prompt_arg tests
# =============================================================================

@test "get_startup_prompt_arg: codex → positional prompt" {
    load_adapter_with "${TEST_TMP}/settings_mixed.yaml"
    result=$(get_startup_prompt_arg "observer")
    [[ "$result" != --prompt* ]]
    [[ "$result" == *"Session Start"* ]]
}

@test "get_startup_prompt_arg: opencode → empty (uses --agent instead)" {
    load_adapter_with "${TEST_TMP}/settings_opencode.yaml"
    result=$(get_startup_prompt_arg "shogun")
    [[ "$result" == "" ]]
}

@test "get_startup_prompt_arg: antigravity → empty" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(get_startup_prompt_arg "shogun")
    [[ "$result" == "" ]]
}

# =============================================================================
# validate_cli_availability tests
# =============================================================================

@test "validate_cli_availability: claude -> 0 (installed)" {
    command -v claude >/dev/null 2>&1 || skip "claude not installed (CI environment)"
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "claude"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: Invalid CLI name -> 1 + error message" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability "invalid_type"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Unknown CLI type"* ]]
}

@test "validate_cli_availability: empty string -> 1" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    run validate_cli_availability ""
    [ "$status" -eq 1 ]
}

@test "validate_cli_availability: codex mock (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # Create mock codex command
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/codex"
    chmod +x "${TEST_TMP}/bin/codex"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "codex"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: copilot mock (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/copilot"
    chmod +x "${TEST_TMP}/bin/copilot"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "copilot"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi-cli mock (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi-cli"
    chmod +x "${TEST_TMP}/bin/kimi-cli"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: kimi mock (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/kimi"
    chmod +x "${TEST_TMP}/bin/kimi"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "kimi"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: opencode mock (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/opencode"
    chmod +x "${TEST_TMP}/bin/opencode"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "opencode"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: antigravity mock agy (PATH operations)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/agy"
    chmod +x "${TEST_TMP}/bin/agy"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "antigravity"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: legacy gemini alias uses antigravity mock" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    mkdir -p "${TEST_TMP}/bin"
    echo '#!/bin/bash' > "${TEST_TMP}/bin/agy"
    chmod +x "${TEST_TMP}/bin/agy"
    PATH="${TEST_TMP}/bin:$PATH" run validate_cli_availability "gemini"
    [ "$status" -eq 0 ]
}

@test "validate_cli_availability: codex not installed -> 1 + error message" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    # Exclude codex from PATH (empty PATH is dangerous, set minimal PATH)
    PATH="/usr/bin:/bin" run validate_cli_availability "codex"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Codex CLI not found"* ]]
}

@test "validate_cli_availability: kimi not installed -> 1 + error message" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    PATH="/usr/bin:/bin" run validate_cli_availability "kimi"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Kimi CLI not found"* ]]
}

# =============================================================================
# get_agent_model tests
# =============================================================================

@test "get_agent_model: no cli section shogun -> opus (default)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "shogun")
    [ "$result" = "opus" ]
}

@test "get_agent_model: no cli section orchestrator -> opus (default)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "orchestrator")
    [ "$result" = "opus" ]
}

@test "get_agent_model: no cli section explorer -> haiku (default)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "explorer")
    [ "$result" = "haiku" ]
}

@test "get_agent_model: no cli section observer -> sonnet (default)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "observer")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: YAML specified explorer -> haiku (override)" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "explorer")
    [ "$result" = "haiku" ]
}

@test "get_agent_model: retrieved from models section orchestrator -> sonnet" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "orchestrator")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: codex agent model observer -> gpt-5" {
    load_adapter_with "${TEST_TMP}/settings_with_models.yaml"
    result=$(get_agent_model "observer")
    [ "$result" = "gpt-5" ]
}

@test "get_agent_model: unknown agent -> sonnet (default)" {
    load_adapter_with "${TEST_TMP}/settings_none.yaml"
    result=$(get_agent_model "unknown_agent")
    [ "$result" = "sonnet" ]
}

@test "get_agent_model: kimi CLI designer -> k2.5 (YAML specified)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "designer")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI fixer -> k2.5 (default)" {
    load_adapter_with "${TEST_TMP}/settings_kimi.yaml"
    result=$(get_agent_model "fixer")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI shogun -> k2.5 (default)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "shogun")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: kimi CLI orchestrator -> k2.5 (default)" {
    load_adapter_with "${TEST_TMP}/settings_kimi_default.yaml"
    result=$(get_agent_model "orchestrator")
    [ "$result" = "k2.5" ]
}

@test "get_agent_model: antigravity CLI shogun -> auto (host settings)" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(get_agent_model "shogun")
    [ "$result" = "auto" ]
}

@test "get_model_display_name: Antigravity auto → Antigravity" {
    load_adapter_with "${TEST_TMP}/settings_antigravity.yaml"
    result=$(get_model_display_name "shogun")
    [ "$result" = "Antigravity" ]
}

# =============================================================================
# get_model_display_name tests
# =============================================================================

@test "get_model_display_name: Sonnet + thinking:true → Sonnet+T" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "explorer")
    [ "$result" = "Sonnet+T" ]
}

@test "get_model_display_name: Opus + thinking:true → Opus+T" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    oracle:
      type: claude
      model: claude-opus-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "oracle")
    [ "$result" = "Opus+T" ]
}

@test "get_model_display_name: Claude effort:max → Opus+max" {
    cat > "${TEST_TMP}/settings_display_effort.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-opus-4-8
      effort: max
YAML
    load_adapter_with "${TEST_TMP}/settings_display_effort.yaml"
    result=$(get_model_display_name "explorer")
    [ "$result" = "Opus+max" ]
}

@test "get_model_display_name: Haiku + thinking:false → Haiku" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    librarian:
      type: claude
      model: claude-haiku-4-5-20251001
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "librarian")
    [ "$result" = "Haiku" ]
}

@test "get_model_display_name: Sonnet + thinking unset -> Sonnet+T (default ON)" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    designer:
      type: claude
      model: claude-sonnet-4-6
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "designer")
    [ "$result" = "Sonnet+T" ]
}

@test "get_model_display_name: Codex Spark -> Spark (thinking irrelevant)" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    fixer:
      type: codex
      model: gpt-5.3-codex-spark
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "fixer")
    [ "$result" = "Spark" ]
}

@test "get_model_display_name: Codex 5.3 → Codex5.3" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: claude
  agents:
    observer:
      type: codex
      model: gpt-5.3-codex
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "observer")
    [ "$result" = "Codex5.3" ]
}

@test "get_model_display_name: Kimi → Kimi" {
    cat > "${TEST_TMP}/settings_display.yaml" << 'YAML'
cli:
  default: kimi
  agents:
    oracle:
      type: kimi
      model: k2.5
YAML
    load_adapter_with "${TEST_TMP}/settings_display.yaml"
    result=$(get_model_display_name "oracle")
    [ "$result" = "Kimi" ]
}

@test "get_model_display_name: all models x thinking combinations" {
    cat > "${TEST_TMP}/settings_display_all.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
    librarian:
      type: claude
      model: claude-opus-4-6
      thinking: false
    designer:
      type: claude
      model: claude-haiku-4-5-20251001
      thinking: true
    fixer:
      type: codex
      model: gpt-5.3-codex-spark
    observer:
      type: codex
      model: gpt-5.3-codex
YAML
    load_adapter_with "${TEST_TMP}/settings_display_all.yaml"
    [ "$(get_model_display_name explorer)" = "Sonnet+T" ]
    [ "$(get_model_display_name librarian)" = "Opus" ]
    [ "$(get_model_display_name designer)" = "Haiku+T" ]
    [ "$(get_model_display_name fixer)" = "Spark" ]
    [ "$(get_model_display_name observer)" = "Codex5.3" ]
}

# =============================================================================
# build_cli_command Thinking control tests
# =============================================================================

@test "build_cli_command: thinking:true -> no MAX_THINKING_TOKENS=0" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "explorer")
    [ "$result" = "claude --model claude-sonnet-4-6 --dangerously-skip-permissions" ]
}

@test "build_cli_command: invalid effort is ignored" {
    cat > "${TEST_TMP}/settings_effort_invalid.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-opus-4-8
      effort: turbo
YAML
    load_adapter_with "${TEST_TMP}/settings_effort_invalid.yaml"
    run build_cli_command "explorer"
    [ "$status" -eq 0 ]
    [[ "$output" == *"claude --model claude-opus-4-8 --dangerously-skip-permissions"* ]]
    [[ "$output" != *"--effort turbo"* ]]
}

@test "build_cli_command: thinking:false → MAX_THINKING_TOKENS=0 prefix" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-sonnet-4-6
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "explorer")
    [ "$result" = "MAX_THINKING_TOKENS=0 claude --model claude-sonnet-4-6 --dangerously-skip-permissions" ]
}

@test "build_cli_command: thinking unset -> no MAX_THINKING_TOKENS=0 (default Thinking ON)" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-sonnet-4-6
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "explorer")
    [ "$result" = "claude --model claude-sonnet-4-6 --dangerously-skip-permissions" ]
}

@test "build_cli_command: codex + thinking:false -> no MAX_THINKING_TOKENS=0 (irrelevant to Codex)" {
    cat > "${TEST_TMP}/settings_thinking.yaml" << 'YAML'
cli:
  default: claude
  agents:
    observer:
      type: codex
      model: gpt-5.3-codex
      thinking: false
YAML
    load_adapter_with "${TEST_TMP}/settings_thinking.yaml"
    result=$(build_cli_command "observer")
    [[ "$result" != MAX_THINKING_TOKENS* ]]
    [[ "$result" == codex* ]]
}

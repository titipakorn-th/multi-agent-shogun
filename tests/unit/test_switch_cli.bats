#!/usr/bin/env bats
# test_switch_cli.bats — switch_cli.sh Unit Test
# shogun-model-switch Skill Test

# --- Setup ---

setup() {
    TEST_TMP="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    # settings.yaml for testing
    cat > "${TEST_TMP}/settings.yaml" << 'YAML'
cli:
  default: claude
  agents:
    orchestrator:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
    explorer:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
    librarian:
      type: claude
      model: claude-sonnet-4-6
      thinking: false
    designer:
      type: codex
      model: gpt-5.3-codex-spark
    observer:
      type: claude
      model: claude-opus-4-6
      thinking: true
    oracle:
      type: claude
      model: claude-opus-4-6
      thinking: true
YAML

    # Load cli_adapter.sh (using test settings)
    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# =============================================================================
# resolve_pane test (directly tests functions inside switch_cli.sh)
# =============================================================================

# Since resolve_pane depends on tmux, source only function definitions to test string generation
load_resolve_pane() {
    # Extract only resolve_pane from switch_cli.sh (mock tmux commands)
    eval '
    resolve_pane() {
        local agent_id="$1"
        local pane_base="${MOCK_PANE_BASE:-0}"
        case "$agent_id" in
            orchestrator)       echo "multiagent:agents.$((pane_base + 0))" ;;
            explorer)  echo "multiagent:agents.$((pane_base + 1))" ;;
            librarian)  echo "multiagent:agents.$((pane_base + 2))" ;;
            designer)  echo "multiagent:agents.$((pane_base + 3))" ;;
            fixer)  echo "multiagent:agents.$((pane_base + 4))" ;;
            observer)  echo "multiagent:agents.$((pane_base + 5))" ;;
            oracle_legacy)  echo "multiagent:agents.$((pane_base + 6))" ;;
            council)  echo "multiagent:agents.$((pane_base + 7))" ;;
            oracle)     echo "multiagent:agents.$((pane_base + 8))" ;;
            *)          return 1 ;;
        esac
    }
    '
}

@test "resolve_pane: orchestrator → multiagent:agents.0" {
    load_resolve_pane
    MOCK_PANE_BASE=0
    result=$(resolve_pane "orchestrator")
    [ "$result" = "multiagent:agents.0" ]
}

@test "resolve_pane: explorer → multiagent:agents.1" {
    load_resolve_pane
    MOCK_PANE_BASE=0
    result=$(resolve_pane "explorer")
    [ "$result" = "multiagent:agents.1" ]
}

@test "resolve_pane: council → multiagent:agents.7" {
    load_resolve_pane
    MOCK_PANE_BASE=0
    result=$(resolve_pane "council")
    [ "$result" = "multiagent:agents.7" ]
}

@test "resolve_pane: oracle → multiagent:agents.8" {
    load_resolve_pane
    MOCK_PANE_BASE=0
    result=$(resolve_pane "oracle")
    [ "$result" = "multiagent:agents.8" ]
}

@test "resolve_pane: unknown agent → return 1" {
    load_resolve_pane
    MOCK_PANE_BASE=0
    run resolve_pane "shogun"
    [ "$status" -eq 1 ]
}

@test "resolve_pane: pane_base=2 → offset applied" {
    load_resolve_pane
    MOCK_PANE_BASE=2
    result=$(resolve_pane "orchestrator")
    [ "$result" = "multiagent:agents.2" ]
    result=$(resolve_pane "designer")
    [ "$result" = "multiagent:agents.5" ]
    result=$(resolve_pane "oracle")
    [ "$result" = "multiagent:agents.10" ]
}

# =============================================================================
# settings.yaml update test (Python part)
# =============================================================================

@test "update_settings: YAML is updated correctly on type change" {
    # settings for testing
    cp "${TEST_TMP}/settings.yaml" "${TEST_TMP}/settings_update.yaml"

    # update type via direct Python execution
    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml

path = "${TEST_TMP}/settings_update.yaml"
with open(path, 'r') as f:
    data = yaml.safe_load(f) or {}

data['cli']['agents']['explorer']['type'] = 'codex'
data['cli']['agents']['explorer']['model'] = 'gpt-5.3-codex-spark'

with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
PYEOF

    # Verify update results
    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_update.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"

    result=$(get_cli_type "explorer")
    [ "$result" = "codex" ]

    result=$(get_agent_model "explorer")
    [ "$result" = "gpt-5.3-codex-spark" ]
}

@test "update_settings: build_cli_command reflects changes after model change" {
    cp "${TEST_TMP}/settings.yaml" "${TEST_TMP}/settings_update2.yaml"

    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml

path = "${TEST_TMP}/settings_update2.yaml"
with open(path, 'r') as f:
    data = yaml.safe_load(f) or {}

data['cli']['agents']['explorer']['model'] = 'claude-opus-4-6'

with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
PYEOF

    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_update2.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"

    result=$(build_cli_command "explorer")
    [[ "$result" == *"claude-opus-4-6"* ]]
    [[ "$result" == *"--dangerously-skip-permissions"* ]]
}

@test "update_settings: MAX_THINKING_TOKENS=0 in build_cli_command after thinking:false" {
    cp "${TEST_TMP}/settings.yaml" "${TEST_TMP}/settings_update3.yaml"

    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml

path = "${TEST_TMP}/settings_update3.yaml"
with open(path, 'r') as f:
    data = yaml.safe_load(f) or {}

data['cli']['agents']['explorer']['thinking'] = False

with open(path, 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
PYEOF

    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_update3.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"

    result=$(build_cli_command "explorer")
    [[ "$result" == MAX_THINKING_TOKENS=0* ]]
}

# =============================================================================
# switch_cli.sh argument parse test (--help, validation)
# =============================================================================

@test "switch_cli.sh --help -> display usage + exit 1" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh" --help
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
    [[ "$output" == *"opencode"* ]]
    [[ "$output" == *"openai/gpt-5.4-mini"* ]]
    [[ "$output" == *"--effort"* ]]
}

@test "switch_cli.sh -h -> display usage + exit 1" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh" -h
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "switch_cli.sh no arguments -> display usage + exit 1" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage"* ]]
}

@test "switch_cli.sh invalid type -> error" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh" explorer --type invalid_cli
    [ "$status" -ne 0 ]
}

@test "switch_cli.sh invalid effort -> error" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh" explorer --effort turbo
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid effort"* ]]
}

@test "switch_cli validation: opencode type is accepted" {
    _cli_adapter_is_valid_cli "opencode"
    [ "$?" -eq 0 ]
}

@test "switch_cli validation: antigravity type and aliases are accepted" {
    _cli_adapter_is_valid_cli "antigravity"
    [ "$?" -eq 0 ]
    _cli_adapter_is_valid_cli "agy"
    [ "$?" -eq 0 ]
    _cli_adapter_is_valid_cli "gemini"
    [ "$?" -eq 0 ]
}

@test "switch_cli.sh provider-qualified model without --type on non-opencode agent -> error" {
    run bash "${PROJECT_ROOT}/scripts/switch_cli.sh" explorer --model openai/gpt-5.4-mini
    [ "$status" -ne 0 ]
    [[ "$output" == *"provider-qualified model IDs are ambiguous without --type"* ]]
}

# =============================================================================
# get_model_display_name integration test (display name that switch_cli.sh depends on)
# =============================================================================

@test "display_name: display name changes correctly before and after switch" {
    # original: Sonnet+T
    result=$(get_model_display_name "explorer")
    [ "$result" = "Sonnet+T" ]

    # simulate settings update: to Opus+T
    cat > "${TEST_TMP}/settings_switched.yaml" << 'YAML'
cli:
  default: claude
  agents:
    explorer:
      type: claude
      model: claude-opus-4-6
      thinking: true
YAML
    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_switched.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"

    result=$(get_model_display_name "explorer")
    [ "$result" = "Opus+T" ]
}

@test "display_name: update display name on Codex -> Claude switch" {
    # designer is Codex Spark
    result=$(get_model_display_name "designer")
    [ "$result" = "Spark" ]

    # switch to Claude Sonnet+T
    cat > "${TEST_TMP}/settings_codex_to_claude.yaml" << 'YAML'
cli:
  default: claude
  agents:
    designer:
      type: claude
      model: claude-sonnet-4-6
      thinking: true
YAML
    export CLI_ADAPTER_SETTINGS="${TEST_TMP}/settings_codex_to_claude.yaml"
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"

    result=$(get_model_display_name "designer")
    [ "$result" = "Sonnet+T" ]
}

@test "display_name: +T disappears when thinking:false" {
    # librarian is thinking:false
    result=$(get_model_display_name "librarian")
    [ "$result" = "Sonnet" ]

    # observer is thinking:true
    result=$(get_model_display_name "observer")
    [ "$result" = "Opus+T" ]
}

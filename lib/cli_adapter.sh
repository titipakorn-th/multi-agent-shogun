#!/usr/bin/env bash
# cli_adapter.sh — CLI abstraction layer
# Compliant with Multi-CLI Integration Design Doc (reports/design_multi_cli_support.md) §2.2
#
# Provided functions:
#   get_cli_type(agent_id)                  → "claude" | "codex" | "copilot" | "kimi" | "opencode" | "cursor"
#   get_cli_type(agent_id)                  → "claude" | "codex" | "copilot" | "kimi" | "opencode" | "antigravity"
#   build_cli_command(agent_id)             -> Complete command string
#   get_instruction_file(agent_id [,cli_type]) -> Instruction file path
#   validate_cli_availability(cli_type)     → 0=OK, 1=NG
#   get_agent_model(agent_id)               → "opus" | "sonnet" | "haiku" | "k2.5"
#   get_agent_effort(agent_id)              → "low" | "medium" | "high" | "xhigh" | "max" | ""
#   get_startup_prompt(agent_id)            -> Initial prompt string or ""
#   get_startup_prompt_arg(agent_id)        -> Prompt argument for startup command or ""

# Resolve settings.yaml path based on project root
CLI_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_ADAPTER_PROJECT_ROOT="$(cd "${CLI_ADAPTER_DIR}/.." && pwd)"
CLI_ADAPTER_SETTINGS="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

# Allowed CLI types
CLI_ADAPTER_ALLOWED_CLIS="claude codex copilot kimi opencode cursor"
CLI_ADAPTER_ALLOWED_CLIS="claude codex copilot kimi opencode antigravity"

# _cli_adapter_normalize_cli_type cli_type
# Normalize compatible CLI type aliases to canonical names.
_cli_adapter_normalize_cli_type() {
    local cli_type="${1:-}"
    cli_type=$(echo "$cli_type" | tr '[:upper:]' '[:lower:]')
    case "$cli_type" in
        gemini|agy) echo "antigravity" ;;
        *)          echo "$cli_type" ;;
    esac
}

# normalize_opencode_model(model)
# Normalize model names to provider-qualified format for OpenCode.
normalize_opencode_model() {
    local model="${1:-}"

    if [[ -z "$model" ]]; then
        echo ""
        return 0
    fi

    if [[ "$model" == */* ]]; then
        echo "$model"
        return 0
    fi

    case "$model" in
        gpt-5.4-mini|gpt-5.4|gpt-5.3-codex|gpt-5.3-codex-spark|gpt-5*)
            echo "openai/${model}"
            ;;
        claude-opus-4-8)
            echo "anthropic/claude-opus-4-8"
            ;;
        claude-opus-4-7)
            echo "anthropic/claude-opus-4-7"
            ;;
        claude-opus-4-6|opus)
            echo "anthropic/claude-opus-4-6"
            ;;
        claude-sonnet-4-6|sonnet)
            echo "anthropic/claude-sonnet-4-6"
            ;;
        claude-haiku-4-5-20251001|haiku)
            echo "anthropic/claude-haiku-4-5-20251001"
            ;;
        moonshot-k2.5|k2.5)
            echo "moonshot/kimi-k2.5"
            ;;
        kimi-*)
            echo "moonshot/kimi-${model#kimi-}"
            ;;
        *)
            echo "$model"
            ;;
    esac
}

# --- Internal Helpers ---

# _cli_adapter_read_yaml key [fallback]
# Read value from settings.yaml using python3
_cli_adapter_read_yaml() {
    local key_path="$1"
    local fallback="${2:-}"
    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    keys = '${key_path}'.split('.')
    val = cfg
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            val = None
            break
    if val is not None:
        print(val)
    else:
        print('${fallback}')
except Exception:
    print('${fallback}')
" 2>/dev/null)
    if [[ -z "$result" ]]; then
        echo "$fallback"
    else
        echo "$result"
    fi
}

# _cli_adapter_shell_quote value
# Quote value to safely embed as a shell argument
_cli_adapter_shell_quote() {
    local value="$1"
    local venv_python="$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3"

    if [[ -x "$venv_python" ]]; then
        "$venv_python" -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$value" 2>/dev/null && return 0
    fi

    printf '%q\n' "$value"
}

# _cli_adapter_get_agent_env_prefix agent_id
# Returns KEY=VALUE strings from settings.yaml's cli.agents.{id}.env
# e.g.: "OPENAI_BASE_URL=http://... OPENAI_API_KEY=sk-xxx "
_cli_adapter_get_agent_env_prefix() {
    local agent_id="$1"
    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, shlex, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    env = cfg.get('cli', {}).get('agents', {}).get('${agent_id}', {})
    if not isinstance(env, dict):
        sys.exit(0)
    env = env.get('env', {})
    if not isinstance(env, dict):
        sys.exit(0)
    parts = [shlex.quote(f'{k}={v}') for k, v in env.items()]
    if parts:
        print(' '.join(parts) + ' ')
except Exception:
    pass
" 2>/dev/null)
    echo "${result:-}"
}

# _cli_adapter_is_valid_cli cli_type
# Check if it is an allowed CLI type
_cli_adapter_is_valid_cli() {
    local cli_type
    cli_type=$(_cli_adapter_normalize_cli_type "${1:-}")
    local allowed
    for allowed in $CLI_ADAPTER_ALLOWED_CLIS; do
        [[ "$cli_type" == "$allowed" ]] && return 0
    done
    return 1
}

# --- Public API ---

# get_cli_type(agent_id)
# Returns the CLI type that the specified agent should use
# Fallback: cli.agents.{id}.type -> cli.agents.{id} (string) -> cli.default -> "claude"
get_cli_type() {
    local agent_id="$1"
    if [[ -z "$agent_id" ]]; then
        echo "claude"
        return 0
    fi

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
allowed = ('claude', 'codex', 'copilot', 'kimi', 'opencode', 'cursor', 'antigravity')
def normalize_cli(value):
    value = str(value or '').lower()
    if value in ('gemini', 'agy'):
        return 'antigravity'
    return value
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    cli = cfg.get('cli', {})
    if not isinstance(cli, dict):
        print('claude'); sys.exit(0)
    agents = cli.get('agents', {})
    if not isinstance(agents, dict):
        default = normalize_cli(cli.get('default', 'claude'))
        print(default if default in allowed else 'claude')
        sys.exit(0)
    agent_cfg = agents.get('${agent_id}')
    if isinstance(agent_cfg, dict):
        t = normalize_cli(agent_cfg.get('type', ''))
        if t in allowed:
            print(t); sys.exit(0)
    elif isinstance(agent_cfg, str):
        t = normalize_cli(agent_cfg)
        if t in allowed:
            print(t); sys.exit(0)
    default = normalize_cli(cli.get('default', 'claude'))
    if default in allowed:
        print(default)
    else:
        print('claude', file=sys.stderr)
        print('claude')
except Exception as e:
    print('claude', file=sys.stderr)
    print('claude')
" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "claude"
    else
        result=$(_cli_adapter_normalize_cli_type "$result")
        if ! _cli_adapter_is_valid_cli "$result"; then
            echo "[WARN] Invalid CLI type '$result' for agent '$agent_id'. Falling back to 'claude'." >&2
            echo "claude"
        else
            echo "$result"
        fi
    fi
}

# build_cli_command(agent_id)
# Returns the complete command string to start the agent
# settings.yaml's thinking: false -> prepend MAX_THINKING_TOKENS=0
build_cli_command() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")
    local model
    model=$(get_agent_model "$agent_id")
    local thinking
    thinking=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.thinking" "")
    local effort
    effort=$(get_agent_effort "$agent_id")
    local permission_flag="${PERMISSION_FLAG:---dangerously-skip-permissions}"

    # thinking prefix: Only valid for Claude CLI
    # thinking: true or unset -> leave as is (Thinking ON by default)
    # thinking: false -> prepend MAX_THINKING_TOKENS=0
    local prefix=""
    if [[ "$cli_type" == "claude" ]] && [[ "$thinking" == "false" || "$thinking" == "False" ]]; then
        prefix="MAX_THINKING_TOKENS=0 "
    fi

    local agent_env_prefix
    agent_env_prefix=$(_cli_adapter_get_agent_env_prefix "$agent_id")

    local cmd=""
    case "$cli_type" in
        claude)
            cmd="claude"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            if [[ -n "$effort" ]]; then
                cmd="$cmd --effort $effort"
            fi
            cmd="$cmd $permission_flag"
            ;;
        codex)
            cmd="codex"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            cmd="$cmd --search --dangerously-bypass-approvals-and-sandbox --no-alt-screen"
            ;;
        opencode)
            local normalized_model
            local tui_config_path
            local variant
            local launch_agent_id
            normalized_model=$(normalize_opencode_model "$model")
            tui_config_path=$(_cli_adapter_shell_quote "$CLI_ADAPTER_PROJECT_ROOT/config/opencode-tui.json")
            variant=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.variant" "")
            launch_agent_id="$agent_id"
            if [[ -n "$variant" ]]; then
                launch_agent_id="${agent_id}-runtime"
            fi
            local quoted_agent_id
            quoted_agent_id=$(_cli_adapter_shell_quote "$agent_id")
            cmd="opencode"
            if [[ -n "$normalized_model" ]]; then
                cmd="$cmd --model $normalized_model"
            fi
            # Use --agent to load the pre-built agent definition from .opencode/agents/<name>.md.
            # Permissions are also embedded in the agent definition YAML frontmatter at build time.
            # OpenCode TUI does not accept `--variant`; provider-specific variants
            # are synchronized into an ignored runtime agent by build_instructions.sh
            # or switch_cli.sh.
            cmd="$cmd --agent $launch_agent_id"
            # Use a project-pinned TUI config so tmux automation sees stable keybinds
            # even when the user has a different global tui.json.
            cmd="OPENCODE_AGENT_ID=$quoted_agent_id OPENCODE_TUI_CONFIG=$tui_config_path $cmd"
            ;;
        copilot)
            cmd="copilot --yolo"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            ;;
        kimi)
            cmd="kimi --yolo"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            ;;
        cursor)
            local bin="agent"
            command -v cursor-agent &>/dev/null && bin="cursor-agent"
            cmd="$bin --yolo"
            if [[ -n "$model" ]]; then
                cmd="$cmd --model $model"
            fi
            ;;
        antigravity)
            cmd="agy --dangerously-skip-permissions"
            if [[ -n "$model" && "$model" != "auto" && "$model" != "default" ]]; then
                cmd="$cmd --model $model"
            fi
            ;;
        *)
            cmd="claude $permission_flag"
            ;;
    esac

    local startup_prompt_arg
    startup_prompt_arg=$(get_startup_prompt_arg "$agent_id")
    if [[ -n "$startup_prompt_arg" ]]; then
        cmd="$cmd $startup_prompt_arg"
    fi

    echo "${agent_env_prefix}${prefix}${cmd}"
}

# get_instruction_file(agent_id [,cli_type])
# Returns the path of the instruction file that the CLI should auto-load
get_instruction_file() {
    local agent_id="$1"
    local cli_type="${2:-$(get_cli_type "$agent_id")}"
    local role
    cli_type=$(_cli_adapter_normalize_cli_type "$cli_type")

    case "$agent_id" in
        shogun)        role="shogun" ;;
        orchestrator)  role="orchestrator" ;;
        explorer|librarian|oracle|designer|fixer|observer|council)
                      role="$agent_id" ;;
        telegram)      role="telegram" ;;
        *)
            echo "" >&2
            return 1
            ;;
    esac

    case "$cli_type" in
        claude)  echo "instructions/${role}.md" ;;
        codex)   echo "instructions/codex-${role}.md" ;;
        copilot) echo ".github/copilot-instructions-${role}.md" ;;
        kimi)    echo "instructions/generated/kimi-${role}.md" ;;
        opencode) echo "instructions/generated/opencode-${role}.md" ;;
        cursor)  echo "instructions/generated/cursor-${role}.md" ;;
        antigravity) echo "instructions/generated/antigravity-${role}.md" ;;
        *)       echo "instructions/${role}.md" ;;
    esac
}

# validate_cli_availability(cli_type)
# Check if the specified CLI is installed on the system
# 0=available, 1=unavailable
validate_cli_availability() {
    local cli_type
    cli_type=$(_cli_adapter_normalize_cli_type "${1:-}")
    case "$cli_type" in
        claude)
            command -v claude &>/dev/null || {
                echo "[ERROR] Claude Code CLI not found. Install from https://claude.ai/download" >&2
                return 1
            }
            ;;
        codex)
            command -v codex &>/dev/null || {
                echo "[ERROR] OpenAI Codex CLI not found. Install with: npm install -g @openai/codex" >&2
                return 1
            }
            ;;
        opencode)
            command -v opencode &>/dev/null || {
                echo "[ERROR] OpenCode CLI not found. Install from https://opencode.ai" >&2
                return 1
            }
            ;;
        copilot)
            command -v copilot &>/dev/null || {
                echo "[ERROR] GitHub Copilot CLI not found. Install with: brew install copilot-cli" >&2
                return 1
            }
            ;;
        kimi)
            if ! command -v kimi-cli &>/dev/null && ! command -v kimi &>/dev/null; then
                echo "[ERROR] Kimi CLI not found. Install from https://platform.moonshot.cn/" >&2
                return 1
            fi
            ;;
        cursor)
            if ! command -v agent &>/dev/null && ! command -v cursor-agent &>/dev/null; then
                echo "[ERROR] Cursor Agent CLI not found. Install: curl https://cursor.com/install -fsS | bash (Linux/WSL2) / brew install cursor-agent (macOS)" >&2
                return 1
            fi
            ;;
        antigravity)
            if ! command -v agy &>/dev/null && ! command -v antigravity &>/dev/null; then
                echo "[ERROR] Antigravity CLI not found. Install and authenticate Google's Antigravity CLI, then ensure 'agy' is on PATH." >&2
                return 1
            fi
            ;;
        *)
            echo "[ERROR] Unknown CLI type: '$cli_type'. Allowed: $CLI_ADAPTER_ALLOWED_CLIS" >&2
            return 1
            ;;
    esac
    return 0
}

# get_agent_model(agent_id)
# Returns the model name that the agent should use
get_agent_model() {
    local agent_id="$1"

    # First check settings.yaml's cli.agents.{id}.model
    local model_from_yaml
    model_from_yaml=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.model" "")

    if [[ -n "$model_from_yaml" ]]; then
        echo "$model_from_yaml"
        return 0
    fi

    # Check existing models section
    local model_from_models
    model_from_models=$(_cli_adapter_read_yaml "models.${agent_id}" "")

    if [[ -n "$model_from_models" ]]; then
        echo "$model_from_models"
        return 0
    fi

    # Default logic (initial value depending on CLI type)
    local cli_type
    cli_type=$(get_cli_type "$agent_id")

    case "$cli_type" in
        kimi)
            # Default model for Kimi CLI
            case "$agent_id" in
                shogun|orchestrator)               echo "k2.5" ;;
                explorer|librarian|oracle|designer|fixer|observer|council) echo "k2.5" ;;
                *)                                 echo "k2.5" ;;
            esac
            ;;
        cursor)
            # Default model for Cursor Agent CLI (model name is passed through)
            case "$agent_id" in
                shogun|orchestrator|oracle|council) echo "claude-sonnet-4-6" ;;
                *)                                 echo "claude-sonnet-4-6" ;;
            esac
            ;;
        antigravity)
            # Antigravity CLI uses the default/last model settings on the host side.
            echo "auto"
            ;;
        copilot)
            # Copilot CLI manages model selection internally; no default
            echo ""
            ;;
        *)
            # Default model for Claude Code/Codex (v2 specialist team)
            case "$agent_id" in
                shogun|orchestrator|oracle|council) echo "opus" ;;
                explorer)                          echo "haiku" ;;
                librarian|designer|fixer|observer) echo "sonnet" ;;
                *)                                 echo "sonnet" ;;
            esac
            ;;
    esac
}

# get_agent_effort(agent_id)
# Returns the reasoning effort to pass to the Claude CLI --effort flag.
# Empty string for unspecified/invalid values to maintain backward compatibility.
get_agent_effort() {
    local agent_id="$1"
    local effort
    effort=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.effort" "")

    case "$effort" in
        low|medium|high|xhigh|max)
            echo "$effort"
            ;;
        "")
            echo ""
            ;;
        *)
            echo "[WARN] Invalid effort '$effort' for agent '$agent_id'. Ignoring." >&2
            echo ""
            ;;
    esac
}

# get_model_display_name(agent_id)
# Returns a short display name for pane-border-format
# Format: "{ShortName}" or "{ShortName}+T" (thinking enabled)
# Examples: Sonnet, Opus+T, Haiku, Codex, Spark
get_model_display_name() {
    local agent_id="$1"
    local model
    model=$(get_agent_model "$agent_id")
    local cli_type
    cli_type=$(get_cli_type "$agent_id")
    local thinking
    thinking=$(_cli_adapter_read_yaml "cli.agents.${agent_id}.thinking" "")
    local effort
    effort=$(get_agent_effort "$agent_id")

    if [[ "$cli_type" == "opencode" ]]; then
        if [[ "$model" == */* ]]; then
            echo "OpenCode (${model#*/})"
        else
            echo "OpenCode (${model})"
        fi
        return 0
    fi

    if [[ "$cli_type" == "cursor" ]]; then
        echo "Cursor (${model})"
        return 0
    fi

    if [[ "$cli_type" == "antigravity" ]]; then
        if [[ -n "$model" && "$model" != "auto" && "$model" != "default" ]]; then
            echo "Antigravity (${model})"
        else
            echo "Antigravity"
        fi
        return 0
    fi

    # Model name -> short display name
    local short=""
    case "$model" in
        *spark*)                short="Spark" ;;
        gpt-5.3-codex)          short="Codex5.3" ;;
        *codex*|gpt-5.3)        short="Codex" ;;
        *opus*)                 short="Opus" ;;
        *sonnet*)               short="Sonnet" ;;
        *haiku*)                short="Haiku" ;;
        *k2.5*|*kimi*)          short="Kimi" ;;
        *)
            # Infer from CLI type
            case "$cli_type" in
                codex)   short="Codex" ;;
                copilot) short="Copilot" ;;
                kimi)    short="Kimi" ;;
                *)       short="$model" ;;
            esac
            ;;
    esac

    # Thinking display: Claude is ON by default, hide only when false
    # Claude: thinking: false -> none, others (true/unset) -> "+T"
    # Codex/others: No thinking -> always none
    if [[ "$cli_type" == "claude" ]]; then
        if [[ -n "$effort" ]]; then
            echo "${short}+${effort}"
        elif [[ "$thinking" == "false" || "$thinking" == "False" ]]; then
            echo "$short"
        else
            echo "${short}+T"
        fi
    else
        echo "$short"
    fi
}

# get_startup_prompt(agent_id)
# Returns the initial prompt that the CLI should run automatically at first startup
# Codex CLI: Passed as [PROMPT] argument (root fix for suggest UI freeze)
# Claude Code: Empty (CLAUDE.md auto-load boots Session Start)
# Copilot/Kimi: Empty (future support)
# OpenCode: Empty (.opencode/agents/ auto-loaded)
get_startup_prompt() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")

    case "$cli_type" in
        codex)
            echo "Session Start — do ALL of this in one turn, do NOT stop early: 1) tmux display-message -t \"\$TMUX_PANE\" -p '#{@agent_id}' to identify yourself. 2) Read queue/tasks/${agent_id}.yaml. 3) Read queue/inbox/${agent_id}.yaml, mark read:true. 4) Read files listed in context_files. 5) Execute the assigned task to completion — edit files, run commands, write reports. Keep working until the task is done."
            ;;
        *)
            echo ""
            ;;
    esac
}

# get_startup_prompt_arg(agent_id)
# Returns CLI-specific initial prompt argument to embed in startup command
# Codex: positional prompt
# Others: Empty
get_startup_prompt_arg() {
    local agent_id="$1"
    local cli_type
    cli_type=$(get_cli_type "$agent_id")
    local startup_prompt
    startup_prompt=$(get_startup_prompt "$agent_id")

    if [[ -z "$startup_prompt" ]]; then
        echo ""
        return 0
    fi

    local quoted_prompt
    quoted_prompt=$(_cli_adapter_shell_quote "$startup_prompt")

    case "$cli_type" in
        codex)
            echo "$quoted_prompt"
            ;;
        *)
            echo ""
            ;;
    esac
}

# =============================================================================
# Dynamic Model Routing — Issue #53 Phase 1
# capability_tier read, recommended model selection, cost group retrieval
# =============================================================================

# get_capability_tier(model_name)
# Returns the Bloom level upper limit for the specified model
# capability_tiers section undefined or model undefined -> 6 (no limit)
# Note: Do not use _cli_adapter_read_yaml because model name may contain dots
get_capability_tier() {
    local model_name="$1"

    if [[ -z "$model_name" ]]; then
        echo "6"
        return 0
    fi

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    tiers = cfg.get('capability_tiers')
    if not tiers or not isinstance(tiers, dict):
        print('6'); sys.exit(0)
    spec = tiers.get('${model_name}')
    if not spec or not isinstance(spec, dict):
        print('6'); sys.exit(0)
    mb = spec.get('max_bloom', 6)
    if isinstance(mb, int) and 1 <= mb <= 6:
        print(mb)
    else:
        print('6')
except Exception:
    print('6')
" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "6"
    else
        echo "$result"
    fi
}

# get_cost_group(model_name)
# Returns the cost group for the specified model
# Undefined -> "unknown"
# Note: Do not use _cli_adapter_read_yaml because model name may contain dots
get_cost_group() {
    local model_name="$1"

    if [[ -z "$model_name" ]]; then
        echo "unknown"
        return 0
    fi

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    tiers = cfg.get('capability_tiers')
    if not tiers or not isinstance(tiers, dict):
        print('unknown'); sys.exit(0)
    spec = tiers.get('${model_name}')
    if not spec or not isinstance(spec, dict):
        print('unknown'); sys.exit(0)
    cg = spec.get('cost_group', 'unknown')
    print(cg if cg else 'unknown')
except Exception:
    print('unknown')
" 2>/dev/null)

    if [[ -z "$result" ]]; then
        echo "unknown"
    else
        echo "$result"
    fi
}

# get_available_cost_groups()
# Returns the user's subscription pattern
# 1) available_cost_groups defined in settings.yaml -> return as is
# 2) Undefined -> auto-estimate from capability_tiers (aggregate cost_groups of defined models)
# 3) capability_tiers absent -> empty string
# Output: space-separated cost_group list (e.g. "claude_max chatgpt_pro")
get_available_cost_groups() {
    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}

    # 1) Use explicit definition if exists
    explicit = cfg.get('available_cost_groups')
    if explicit and isinstance(explicit, list):
        print(' '.join(str(g) for g in explicit))
        sys.exit(0)

    # 2) Auto-estimate from capability_tiers
    tiers = cfg.get('capability_tiers')
    if not tiers or not isinstance(tiers, dict):
        print('')
        sys.exit(0)

    groups = set()
    for model, spec in tiers.items():
        if isinstance(spec, dict):
            cg = spec.get('cost_group')
            if cg:
                groups.add(cg)
    print(' '.join(sorted(groups)))
except Exception:
    print('')
" 2>/dev/null)

    echo "$result"
}

# get_recommended_model(bloom_level)
# Returns the most cost-efficient model for the specified Bloom level
# Filtered by available_cost_groups. Stderr warning on capability gap.
# capability_tiers section absent -> empty string
# bloom_level out of range (not 1-6) -> empty string + exit code 1
get_recommended_model() {
    local bloom_level="$1"

    # Range check
    if [[ ! "$bloom_level" =~ ^[1-6]$ ]]; then
        echo ""
        return 1
    fi

    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

    # Python: stdout=model name, stderr=warning (passed through to caller stderr)
    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys

def parse_bloom_range(key):
    '''parse 'L1-L3' -> [1,2,3], 'L4-L5' -> [4,5], 'L6' -> [6]'''
    key = key.strip()
    if '-' in key[1:]:  # e.g. L1-L3
        parts = key.split('-')
        start = int(parts[0].lstrip('Ll'))
        end = int(parts[1].lstrip('Ll'))
        return list(range(start, end + 1))
    else:  # e.g. L6
        return [int(key.lstrip('Ll'))]

try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    tiers = cfg.get('capability_tiers')
    if not tiers or not isinstance(tiers, dict):
        sys.exit(0)

    bloom = int('${bloom_level}')
    cost_priority = {'chatgpt_pro': 0, 'claude_max': 1}

    # available_cost_groups: explicit definition or None (all allowed)
    explicit_groups = cfg.get('available_cost_groups')
    if explicit_groups and isinstance(explicit_groups, list):
        allowed_groups = set(str(g) for g in explicit_groups)
    else:
        allowed_groups = None

    # bloom_model_preference: defined -> priority routing
    preference = cfg.get('bloom_model_preference')
    if preference and isinstance(preference, dict):
        # Identify range key corresponding to input bloom_level
        matched_list = None
        for range_key, model_list in preference.items():
            try:
                levels = parse_bloom_range(range_key)
                if bloom in levels:
                    matched_list = model_list
                    break
            except (ValueError, IndexError):
                continue

        if matched_list and isinstance(matched_list, list):
            # Traverse models in list order
            for pref_model in matched_list:
                spec = tiers.get(pref_model)
                if not isinstance(spec, dict):
                    continue
                mb = spec.get('max_bloom', 6)
                cg = spec.get('cost_group', 'unknown')
                # (a) available_cost_groups exclusion check
                if allowed_groups is not None and cg not in allowed_groups:
                    continue
                # (b) capability_tiers max_bloom >= bloom_level
                if isinstance(mb, int) and mb >= bloom:
                    print(pref_model)
                    sys.exit(0)
            # None matched -> fallback + warning
            print('WARNING: All preferred models unavailable for bloom level ' + str(bloom) + ', falling back to cost_priority', file=sys.stderr)
            # fallthrough to legacy cost_priority logic

    # Traditional cost_priority auto-selection (backward compatibility)
    candidates = []
    all_models = []
    for model, spec in tiers.items():
        if not isinstance(spec, dict):
            continue
        mb = spec.get('max_bloom', 6)
        cg = spec.get('cost_group', 'unknown')
        if allowed_groups is not None and cg not in allowed_groups:
            continue
        all_models.append((mb, cg, model))
        if isinstance(mb, int) and mb >= bloom:
            candidates.append((cost_priority.get(cg, 99), mb, model))

    if not all_models:
        sys.exit(0)

    if not candidates:
        best = max(all_models, key=lambda x: x[0])
        print(best[2])
        print(f'[WARN] insufficient: {best[2]} (max_bloom={best[0]}) cannot handle bloom level {bloom}', file=sys.stderr)
    else:
        candidates.sort(key=lambda x: (x[1], x[0]))
        chosen_mb = candidates[0][1]
        chosen_model = candidates[0][2]
        print(chosen_model)
        if chosen_mb - bloom >= 2:
            print(f'[WARN] overqualified: {chosen_model} (max_bloom={chosen_mb}) for bloom level {bloom}. Consider adding a lower-tier model.', file=sys.stderr)
except Exception:
    pass
")

    echo "$result"
}

# =============================================================================
# Dynamic Model Routing — Issue #53 Phase 2
# model_switch judgment, recommended action, CLI compatibility check
# =============================================================================

# needs_model_switch(current_model, bloom_level)
# Judge whether current model can handle specified Bloom level
# Output: "yes" (switch required) | "no" (not required) | "skip" (unable to judge)
needs_model_switch() {
    local current_model="$1"
    local bloom_level="$2"

    # bloom_level unspecified -> skip judgment
    if [[ -z "$bloom_level" || ! "$bloom_level" =~ ^[1-6]$ ]]; then
        echo "skip"
        return 0
    fi

    # capability_tiers presence check
    local max_bloom
    max_bloom=$(get_capability_tier "$current_model")

    # Check if capability_tiers section is absent (when all models return 6)
    local has_tiers
    has_tiers=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${CLI_ADAPTER_SETTINGS}') as f:
        cfg = yaml.safe_load(f) or {}
    tiers = cfg.get('capability_tiers')
    print('yes' if tiers and isinstance(tiers, dict) else 'no')
except:
    print('no')
" 2>/dev/null)

    if [[ "$has_tiers" != "yes" ]]; then
        echo "skip"
        return 0
    fi

    if [[ "$bloom_level" -gt "$max_bloom" ]]; then
        echo "yes"
    else
        echo "no"
    fi
}

# get_switch_recommendation(current_model, bloom_level)
# Returns switch judgment + recommended model + cost group transition
# Output: "no_switch" | "{recommended_model}:{transition_type}"
#   transition_type: "same_cost_group" | "cross_cost_group"
get_switch_recommendation() {
    local current_model="$1"
    local bloom_level="$2"

    local switch_needed
    switch_needed=$(needs_model_switch "$current_model" "$bloom_level")

    if [[ "$switch_needed" != "yes" ]]; then
        echo "no_switch"
        return 0
    fi

    local recommended
    recommended=$(get_recommended_model "$bloom_level")

    if [[ -z "$recommended" ]]; then
        echo "no_switch"
        return 0
    fi

    local current_cg recommended_cg transition
    current_cg=$(get_cost_group "$current_model")
    recommended_cg=$(get_cost_group "$recommended")

    if [[ "$current_cg" = "$recommended_cg" ]]; then
        transition="same_cost_group"
    else
        transition="cross_cost_group"
    fi

    echo "${recommended}:${transition}"
}

# can_model_switch(cli_type)
# Judge whether model_switch is possible for specified CLI type
# Output: "full" (Claude: /model command supported) | "limited" (Codex: within same CLI only) | "none"
can_model_switch() {
    local cli_type="$1"

    case "$cli_type" in
        claude)  echo "full" ;;
        codex)   echo "limited" ;;
        copilot) echo "none" ;;
        kimi)    echo "none" ;;
        cursor)  echo "full" ;;
        *)       echo "none" ;;
    esac
}

# =============================================================================
# Dynamic Model Routing — Issue #53 Phase 3
# oracle_analysis.yaml validation, Bloom analysis trigger judgment
# (v2: oracle does deep analysis, council does evaluation)
# =============================================================================

# get_bloom_routing()
# Read + validate bloom_routing setting from settings.yaml
# Output: "auto" | "manual" | "off"
# Invalid value -> "off" + stderr warning
get_bloom_routing() {
    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

    local raw
    raw=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys
try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    val = cfg.get('bloom_routing')
    if val is None:
        print('off')
    elif val is False:
        print('off')
    else:
        print(str(val))
except Exception:
    print('off')
" 2>/dev/null)

    case "$raw" in
        auto|manual|off)
            echo "$raw"
            ;;
        *)
            echo "off"
            echo "[WARN] bloom_routing: invalid value '${raw}', falling back to 'off'" >&2
            ;;
    esac
}

# validate_oracle_analysis(yaml_path)
# Schema validation for oracle_analysis.yaml
# Output: "valid" (normal) | error message (abnormal)
# Exit code: 0 (normal) | 1 (abnormal)
validate_oracle_analysis() {
    local yaml_path="$1"

    if [[ ! -f "$yaml_path" ]]; then
        echo "error: file not found: ${yaml_path}"
        return 1
    fi

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys

try:
    with open('${yaml_path}') as f:
        doc = yaml.safe_load(f)
except Exception as e:
    print(f'error: YAML parse failed: {e}')
    sys.exit(1)

if not isinstance(doc, dict):
    print('error: root must be a mapping')
    sys.exit(1)

# Required fields
if 'task_id' not in doc:
    print('error: missing required field: task_id')
    sys.exit(1)
if 'timestamp' not in doc:
    print('error: missing required field: timestamp')
    sys.exit(1)

analysis = doc.get('analysis')
if not isinstance(analysis, dict):
    print('error: missing or invalid analysis section')
    sys.exit(1)

# bloom_level: integer 1-6
bl = analysis.get('bloom_level')
if bl is None:
    print('error: missing analysis.bloom_level')
    sys.exit(1)
if not isinstance(bl, int) or bl < 1 or bl > 6:
    print(f'error: bloom_level must be integer 1-6, got {bl}')
    sys.exit(1)

# confidence: float 0.0-1.0
conf = analysis.get('confidence')
if conf is not None:
    if not isinstance(conf, (int, float)) or conf < 0.0 or conf > 1.0:
        print(f'error: confidence must be 0.0-1.0, got {conf}')
        sys.exit(1)

# #48 fields are optional — no validation needed
print('valid')
" 2>&1)

    if [[ "$result" == "valid" ]]; then
        echo "valid"
        return 0
    else
        echo "$result"
        return 1
    fi
}

# v2_bloom_routing(level)
# Map a Bloom taxonomy level (L1..L6, or EVAL) to a v2 specialist role.
#   L1 (remember)    -> explorer  (factual lookup, no analysis)
#   L2 (understand)  -> orchestrator (comprehension / task framing)
#   L3 (apply)       -> orchestrator (apply known patterns)
#   L4 (analyze)     -> oracle  (deep analysis)
#   L5 (evaluate)    -> council (multi-model evaluation)
#   L6 (create)      -> oracle  (synthesis) + council (review)
#   EVAL             -> council (pure evaluation)
v2_bloom_routing() {
    local level="${1:-L1}"
    case "$level" in
        L1)      echo "explorer" ;;
        L2|L3)   echo "orchestrator" ;;
        L4|L6)   echo "oracle" ;;
        L5|EVAL) echo "council" ;;
        *)       echo "orchestrator" ;;
    esac
}

# should_trigger_bloom_analysis(bloom_routing, bloom_analysis_required, oracle_available)
# Judge whether to trigger Bloom analysis
# $1: bloom_routing — "auto" | "manual" | "off"
# $2: bloom_analysis_required — "true" | "false" (flag in task YAML)
# $3: oracle_available — "yes" | "no" (defaults to "yes")
# Output: "yes" | "no" | "fallback"
should_trigger_bloom_analysis() {
    local bloom_routing="${1:-off}"
    local bloom_analysis_required="${2:-false}"
    local oracle_available="${3:-yes}"

    # Oracle not started -> Phase 2 fallback
    if [[ "$oracle_available" = "no" ]]; then
        echo "fallback"
        return 0
    fi

    case "$bloom_routing" in
        auto)
            echo "yes"
            ;;
        manual)
            if [[ "$bloom_analysis_required" = "true" ]]; then
                echo "yes"
            else
                echo "no"
            fi
            ;;
        off|*)
            echo "no"
            ;;
    esac
}

# =============================================================================
# Dynamic Model Routing — Issue #53 Phase 4
# Accumulate and aggregate quality feedback
# =============================================================================

# append_model_performance(yaml_path, task_id, task_type, bloom_level, model_used, qc_result, qc_score)
# Append QC result as one line to model_performance.yaml
# Output: none. exit code 0=success, 1=failure
append_model_performance() {
    local yaml_path="$1"
    local task_id="$2"
    local task_type="$3"
    local bloom_level="$4"
    local model_used="$5"
    local qc_result="$6"
    local qc_score="$7"

    "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys, os
from datetime import datetime, timezone

yaml_path = '${yaml_path}'
entry = {
    'task_id': '${task_id}',
    'task_type': '${task_type}',
    'bloom_level': int('${bloom_level}'),
    'model_used': '${model_used}',
    'qc_result': '${qc_result}',
    'qc_score': float('${qc_score}'),
    'timestamp': datetime.now(timezone.utc).isoformat()
}

try:
    if os.path.exists(yaml_path):
        with open(yaml_path) as f:
            doc = yaml.safe_load(f) or {}
    else:
        doc = {}

    if 'history' not in doc or not isinstance(doc.get('history'), list):
        doc['history'] = []

    doc['history'].append(entry)

    with open(yaml_path, 'w') as f:
        yaml.dump(doc, f, default_flow_style=False, allow_unicode=True)
except Exception as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null
}

# get_model_performance_summary(yaml_path, task_type, bloom_level)
# Returns aggregation by task_type x bloom_level
# Output: "total:N pass:M fail:F pass_rate:R"
get_model_performance_summary() {
    local yaml_path="$1"
    local task_type="$2"
    local bloom_level="$3"

    "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys, os

yaml_path = '${yaml_path}'
task_type = '${task_type}'
bloom_level = int('${bloom_level}')

try:
    if not os.path.exists(yaml_path):
        print('total:0 pass:0 fail:0 pass_rate:0.00')
        sys.exit(0)

    with open(yaml_path) as f:
        doc = yaml.safe_load(f) or {}

    history = doc.get('history', [])
    filtered = [h for h in history
                if h.get('task_type') == task_type
                and h.get('bloom_level') == bloom_level]

    total = len(filtered)
    if total == 0:
        print('total:0 pass:0 fail:0 pass_rate:0.00')
        sys.exit(0)

    pass_count = sum(1 for h in filtered if h.get('qc_result') == 'pass')
    fail_count = total - pass_count
    pass_rate = round(pass_count / total, 2)

    print(f'total:{total} pass:{pass_count} fail:{fail_count} pass_rate:{pass_rate}')
except Exception as e:
    print('total:0 pass:0 fail:0 pass_rate:0.00')
" 2>/dev/null
}

# =============================================================================
# Subscription Pattern Validation
# Verification of user subscription pattern
# =============================================================================

# validate_subscription_coverage()
# Verify if all Bloom levels (1-6) are covered by available models
# Output:
#   "ok" — all levels covered
#   "unconfigured" — capability_tiers undefined
#   "gap:N,M max_available:X" — levels N,M not covered. max available level is X
validate_subscription_coverage() {
    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys

try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    tiers = cfg.get('capability_tiers')
    if not tiers or not isinstance(tiers, dict):
        print('unconfigured')
        sys.exit(0)

    # available_cost_groups filter
    explicit_groups = cfg.get('available_cost_groups')
    if explicit_groups and isinstance(explicit_groups, list):
        allowed_groups = set(str(g) for g in explicit_groups)
    else:
        allowed_groups = None

    # Collect max_bloom of available models
    max_blooms = []
    for model, spec in tiers.items():
        if not isinstance(spec, dict):
            continue
        cg = spec.get('cost_group', 'unknown')
        if allowed_groups is not None and cg not in allowed_groups:
            continue
        mb = spec.get('max_bloom', 6)
        if isinstance(mb, int):
            max_blooms.append(mb)

    if not max_blooms:
        print('unconfigured')
        sys.exit(0)

    max_available = max(max_blooms)

    # Check if there is a model with max_bloom >= level for each Bloom level (1-6)
    gaps = []
    for level in range(1, 7):
        if not any(mb >= level for mb in max_blooms):
            gaps.append(str(level))

    if gaps:
        print(f'gap:{','.join(gaps)} max_available:{max_available}')
    else:
        print('ok')
except Exception:
    print('unconfigured')
" 2>/dev/null)

    echo "$result"
}

# find_agent_for_model() — Issue #53 Phase 2
# Find an idle Ashigaru using the specified model.
#
# Core Design Principle (Lord's Policy):
#   - Busy Pane: Never touch (risk of interruption and data loss)
#   - Idle Pane: CLI switch OK (stop -> start)
#   e.g. If Codex 5.3 is required but only Claude Code is idle, downgrade to Claude Code is OK
#   e.g. If Claude Code is required but only Codex is idle, kill Codex and start Claude Code is OK
#   Actual restart logic for CLI switching is handled by orchestrator.md (this function only returns agent_id)
#
# Arguments:
#   $1: recommended_model — return value of get_recommended_model()
#
# Returns:
#   Idle specialist ID (e.g. "designer") — exact match or fallback
#   All busy -> "QUEUE"
#   Error -> "" (empty string)
#
# Usage Example:
#   agent=$(find_agent_for_model "claude-sonnet-4-6")
#   case "$agent" in
#     QUEUE) echo "add to queue" ;;
#     "")    echo "error" ;;
#     *)     echo "Specialist: assign to $agent (orchestrator.md decides CLI switch)" ;;
#   esac
find_agent_for_model() {
    local recommended_model="$1"

    if [[ -z "$recommended_model" ]]; then
        return 1
    fi

    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"

    # Extract v2 task-eligible specialists using recommended_model from settings.yaml's roles:
    local candidates
    candidates=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml, sys

try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    cli_cfg = cfg.get('cli', {})
    agents = cli_cfg.get('agents', {})
    task_eligible = {'explorer', 'librarian', 'oracle', 'designer', 'fixer', 'observer', 'council'}

    results = []
    for agent_id, spec in agents.items():
        # v2 task-eligible specialists only (exclude shogun, orchestrator, telegram)
        if agent_id not in task_eligible:
            continue
        if not isinstance(spec, dict):
            continue
        agent_model = spec.get('model', '')
        if agent_model == '${recommended_model}':
            results.append(agent_id)

    # Stable order: explorer, librarian, oracle, designer, fixer, observer, council
    order = {r: i for i, r in enumerate(task_eligible)}
    results.sort(key=lambda x: order.get(x, 99))
    print(' '.join(results))
except Exception:
    pass
" 2>/dev/null)

    # Check candidate specialists in order (find idle)
    # Re-use agent_status.sh's agent_is_busy_check
    local agent_status_lib="${CLI_ADAPTER_PROJECT_ROOT}/lib/agent_status.sh"

    if [[ -f "$agent_status_lib" ]]; then
        if ! declare -f agent_is_busy_check >/dev/null 2>&1; then
            # shellcheck disable=SC1090
            source "$agent_status_lib" 2>/dev/null
        fi
    fi

    local candidate
    for candidate in $candidates; do
        # Reverse look up tmux pane target using @agent_id
        local pane_target
        pane_target=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' 2>/dev/null \
            | awk -v agent="$candidate" '$2 == agent {print $1}' | head -1)

        if [[ -z "$pane_target" ]]; then
            # tmux session does not exist (e.g., unit test environment) -> return candidate as is
            echo "$candidate"
            return 0
        fi

        # Busy check
        if declare -f agent_is_busy_check >/dev/null 2>&1; then
            local busy_rc
            agent_is_busy_check "$pane_target" 2>/dev/null
            busy_rc=$?
            # 0=busy, 1=idle, 2=not_found
            if [[ $busy_rc -eq 1 ]]; then
                echo "$candidate"
                return 0
            fi
        else
            # If agent_is_busy_check is unavailable, return first candidate (fallback)
            echo "$candidate"
            return 0
        fi
    done

    # Phase 2: Exact match is all busy -> fallback to any idle v2 specialist
    # Lord's Policy: "If Codex 5.3 is wanted but only Claude Code is idle, Claude Code is acceptable"
    # Never kill/restart. Reuse the idle pane.
    local all_agents
    all_agents=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml

try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    agents = cfg.get('cli', {}).get('agents', {})
    task_eligible = ['explorer', 'librarian', 'oracle', 'designer', 'fixer', 'observer', 'council']
    results = [k for k in agents if k in task_eligible]
    results.sort(key=lambda x: task_eligible.index(x) if x in task_eligible else 99)
    print(' '.join(results))
except Exception:
    pass
" 2>/dev/null)

    local fallback
    for fallback in $all_agents; do
        # Skip if already checked in candidates
        if [[ " $candidates " == *" $fallback "* ]]; then
            continue
        fi

        local fb_pane
        fb_pane=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' 2>/dev/null \
            | awk -v agent="$fallback" '$2 == agent {print $1}' | head -1)

        if [[ -z "$fb_pane" ]]; then
        # No tmux session (test environment) -> return fallback candidate
            echo "$fallback"
            return 0
        fi

        if declare -f agent_is_busy_check >/dev/null 2>&1; then
            agent_is_busy_check "$fb_pane" 2>/dev/null
            local fb_rc=$?
            if [[ $fb_rc -eq 1 ]]; then
                echo "$fallback"
                return 0
            fi
        fi
    done

    # All specialists busy -> queue wait
    echo "QUEUE"
    return 0
}

# get_specialist_ids()
# Returns the v2 task-eligible specialist list (the 7 specialists: explorer,
# librarian, oracle, designer, fixer, observer, council) in canonical order.
# Fallback to the canonical 7 if settings.yaml is absent or malformed.
get_specialist_ids() {
    local settings="${CLI_ADAPTER_SETTINGS:-${CLI_ADAPTER_PROJECT_ROOT}/config/settings.yaml}"
    local result
    result=$("$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml
try:
    with open('${settings}') as f:
        cfg = yaml.safe_load(f) or {}
    agents = cfg.get('cli', {}).get('agents', {})
    task_eligible = ['explorer', 'librarian', 'oracle', 'designer', 'fixer', 'observer', 'council']
    found = [k for k in task_eligible if k in agents]
    print(' '.join(found if found else task_eligible))
except Exception:
    print(' '.join(['explorer', 'librarian', 'oracle', 'designer', 'fixer', 'observer', 'council']))
" 2>/dev/null)
    if [[ -n "$result" ]]; then
        echo "$result"
    else
        echo "explorer librarian oracle designer fixer observer council"
    fi
}

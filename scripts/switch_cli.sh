# ═══════════════════════════════════════════════════════════════
# switch_cli.sh — Safely switch agent CLI sessions
#
# Usage:
#   bash scripts/switch_cli.sh <agent_id> [--type <cli_type>] [--model <model_name>] [--effort <level>] [--variant <variant>]
#
# Examples:
#   # Restart with current settings.yaml values (no CLI type or model change)
#   bash scripts/switch_cli.sh designer
#
#   # Switch from Codex Spark to Claude Sonnet
#   bash scripts/switch_cli.sh designer --type claude --model claude-sonnet-4-6
#
#   # Directly specify provider/model in OpenCode (role definition is --agent, model change takes effect on restart)
#   bash scripts/switch_cli.sh designer --type opencode --model openai/gpt-5.4-mini
#
#   # OpenCode provider-specific reasoning variant
#   bash scripts/switch_cli.sh designer --type opencode --model openrouter/minimax/minimax-m2.5 --variant xhigh
#
#   # Change model and Claude effort within the same CLI (Sonnet -> Opus/max)
#   bash scripts/switch_cli.sh designer --model claude-opus-4-8 --effort max
#
#   # Bulk switch all specialists
#   for r in explorer librarian oracle designer fixer observer council; do bash scripts/switch_cli.sh "$r" --type claude --model claude-sonnet-4-6; done
#
# Flow:
#   1. (Optional) Update settings.yaml
#   2. Send /exit to the current CLI
#   3. Wait for shell prompt to return
#   4. Construct the new CLI command using build_cli_command()
#   5. Launch the new CLI using tmux send-keys
#   6. Update tmux pane metadata (@agent_cli, @model_name)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SETTINGS_FILE="${PROJECT_ROOT}/config/settings.yaml"
LOG_FILE="${PROJECT_ROOT}/logs/switch_cli.log"

# Load cli_adapter.sh
source "${PROJECT_ROOT}/lib/cli_adapter.sh"
source "${PROJECT_ROOT}/lib/agent_registry.sh"

# ─── Log ───
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [switch_cli] $*"
    echo "$msg" >&2
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Usage ───
usage() {
    echo "Usage: $0 <agent_id> [--type <cli_type>] [--model <model_name>] [--effort <level>] [--variant <variant>]"
    echo ""
    echo "  agent_id   Agent configured in config/settings.yaml (e.g. orchestrator, explorer, oracle)"
    echo "  --type     claude | codex | copilot | kimi | opencode | cursor"
    echo "  --model    claude-sonnet-4-6 | claude-opus-4-8 | gpt-5.3-codex | openai/gpt-5.4-mini | etc."
    echo "  --effort   Claude effort level: low | medium | high | xhigh | max"
    echo "  --type     claude | codex | copilot | kimi | opencode | antigravity"
    echo "  --model    claude-sonnet-4-6 | claude-opus-4-6 | gpt-5.3-codex | openai/gpt-5.4-mini | etc."
    echo "  --variant  OpenCode model variant such as xhigh, high, max, minimal"
    echo ""
    echo "If --type/--model omitted, uses current settings.yaml values."
    exit 1
}

# ─── Resolve Agent ID to tmux pane ───
# Search panes dynamically from @agent_id metadata (handles shifted pane indices)
# Fallback: If metadata is not found, use traditional fixed mapping
resolve_pane() {
    local agent_id="$1"

    # Phase 1: Dynamic search from @agent_id metadata
    local pane_count
    pane_count=$(tmux list-panes -t "multiagent:agents" 2>/dev/null | wc -l)
    if [[ "$pane_count" -gt 0 ]]; then
        for i in $(seq 0 $((pane_count - 1))); do
            local aid
            aid=$(tmux display-message -t "multiagent:agents.$i" -p '#{@agent_id}' 2>/dev/null)
            if [[ "$aid" == "$agent_id" ]]; then
                echo "multiagent:agents.$i"
                return 0
            fi
        done
        log "WARN: @agent_id=$agent_id not found in any pane. Falling back to fixed mapping."
    fi

    # Phase 2: Fallback (resolve based on settings.yaml ordering)
    local pane_base
    pane_base=$(tmux show-options -t multiagent -v @pane_base 2>/dev/null || echo "0")

    if agent_registry_multiagent_pane_for_agent "$agent_id" "$pane_base"; then
        return 0
    fi

    log "ERROR: Unknown agent_id: $agent_id"
    return 1
}

# ─── Update settings.yaml (using Python) ───
update_settings_yaml() {
    local agent_id="$1"
    local new_type="${2:-}"
    local new_model="${3:-}"
    local new_variant="${4:-}"
    local new_effort="${5:-}"

    if [[ -z "$new_type" && -z "$new_model" && -z "$new_variant" && -z "$new_effort" ]]; then
        return 0
    fi

    log "Updating settings.yaml: ${agent_id} → type=${new_type:-<unchanged>}, model=${new_model:-<unchanged>}, effort=${new_effort:-<unchanged>}, variant=${new_variant:-<unchanged>}"

    "${PROJECT_ROOT}/.venv/bin/python3" << PYEOF
import yaml, sys, os, datetime

settings_path = "${SETTINGS_FILE}"
agent_id = "${agent_id}"
new_type = "${new_type}" or None
new_model = "${new_model}" or None
new_variant = "${new_variant}" or None
new_effort = "${new_effort}" or None

with open(settings_path, 'r', encoding='utf-8') as f:
    content = f.read()

with open(settings_path, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

cli = data.setdefault('cli', {})
agents = cli.setdefault('agents', {})
agent_cfg = agents.get(agent_id)
if not isinstance(agent_cfg, dict):
    agent_cfg = {}
    agents[agent_id] = agent_cfg

timestamp = datetime.datetime.now().strftime('%Y-%m-%d')
comment = f"# {timestamp}: Switched via switch_cli.sh"

if new_type:
    agent_cfg['type'] = new_type
if new_model:
    agent_cfg['model'] = new_model
if new_variant:
    agent_cfg['variant'] = new_variant
if new_effort:
    agent_cfg['effort'] = new_effort

data['cli']['agents'][agent_id] = agent_cfg

# To keep comments, it is safer to use sed for replacing the target agent line, but
# yaml.dump is used for completeness. Comments will be lost.
# -> Instead, a sed-like approach is used: rewrite only the target block

# Simple approach: read lines, find agent block, replace
lines = content.split('\n')
new_lines = []
in_agent_block = False
agent_indent = None
skip_until_next = False
agent_block_found = False

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.lstrip()

    # Detect our agent's block start
    if stripped.startswith(f'{agent_id}:'):
        agent_block_found = True
        in_agent_block = True
        agent_indent = len(line) - len(stripped)
        new_lines.append(line)
        # Write the updated block. Preserve unspecified existing fields so
        # passing --effort alone cannot accidentally drop type/model/thinking.
        inner_indent = ' ' * (agent_indent + 2)
        ordered_keys = ['type', 'model', 'effort', 'thinking', 'variant']
        ordered_keys.extend(k for k in agent_cfg.keys() if k not in ordered_keys)

        def format_scalar(value):
            if isinstance(value, bool):
                return 'true' if value else 'false'
            dumped = yaml.safe_dump(value, allow_unicode=True, default_flow_style=True).strip()
            if dumped.endswith('\n...'):
                dumped = dumped[:-4].strip()
            if dumped == '...':
                dumped = ''
            return dumped

        changed_keys = set()
        if new_type:
            changed_keys.add('type')
        if new_model:
            changed_keys.add('model')
        if new_variant:
            changed_keys.add('variant')
        if new_effort:
            changed_keys.add('effort')

        for key in ordered_keys:
            if key not in agent_cfg:
                continue
            suffix = f'  {comment}' if key in changed_keys else ''
            new_lines.append(f'{inner_indent}{key}: {format_scalar(agent_cfg[key])}{suffix}')
        # Skip old sub-fields
        i += 1
        while i < len(lines):
            next_line = lines[i]
            next_stripped = next_line.lstrip()
            if next_stripped == '' or next_stripped.startswith('#'):
                # Keep blank lines and comments between blocks
                if next_stripped.startswith('#') and len(next_line) - len(next_stripped) > agent_indent:
                    i += 1
                    continue
                break
            next_indent = len(next_line) - len(next_stripped)
            if next_indent <= agent_indent:
                break  # Next agent or section
            i += 1
        in_agent_block = False
        continue
    else:
        new_lines.append(line)
    i += 1

if not agent_block_found:
    # Agent block not found: fall back to yaml.dump (adds new block, comments lost)
    with open(settings_path, 'w', encoding='utf-8') as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False)
else:
    with open(settings_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_lines))
        if not content.endswith('\n'):
            pass
        else:
            f.write('\n') if not '\n'.join(new_lines).endswith('\n') else None

print("OK")
PYEOF
}

# ─── Sync OpenCode runtime agent frontmatter ───
# OpenCode TUI does not accept --variant, unlike 'opencode run'.
# Provider-specific variants are synced to git-ignored .opencode/agents/<agent>-runtime.md.
sync_opencode_agent_frontmatter() {
    local agent_id="$1"
    local model="${2:-}"
    local variant="${3:-}"
    local base_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}.md"
    local runtime_file="${PROJECT_ROOT}/.opencode/agents/${agent_id}-runtime.md"
    local normalized_model

    [[ -f "$base_file" ]] || return 0

    normalized_model="$(normalize_opencode_model "$model")"

    if [[ -z "$variant" ]]; then
        rm -f "$runtime_file"
        return 0
    fi

    log "Syncing OpenCode runtime agent: ${agent_id}-runtime → model=${normalized_model:-<unset>}, variant=${variant}"

    "${PROJECT_ROOT}/.venv/bin/python3" - "$base_file" "$runtime_file" "$normalized_model" "$variant" <<'PYEOF'
import sys
from pathlib import Path

import yaml

source = Path(sys.argv[1])
dest = Path(sys.argv[2])
model = sys.argv[3] or None
variant = sys.argv[4] or None

text = source.read_text(encoding="utf-8")
if not text.startswith("---\n"):
    raise SystemExit(0)

parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(0)

body = parts[2]
route = {}
if model:
    route["model"] = model
if variant:
    route["variant"] = variant
route_lines = yaml.safe_dump(route, allow_unicode=True, sort_keys=False).splitlines() if route else []

frontmatter_lines = parts[1].lstrip("\n").splitlines()
new_lines = []
inserted = False
for line in frontmatter_lines:
    stripped = line.lstrip()
    indent = len(line) - len(stripped)
    if indent == 0 and (stripped.startswith("model:") or stripped.startswith("variant:")):
        continue
    if not inserted and indent == 0 and stripped.startswith("permission:"):
        new_lines.extend(route_lines)
        inserted = True
    new_lines.append(line)

if not inserted:
    new_lines.extend(route_lines)

frontmatter_text = "\n".join(new_lines).rstrip()

dest.write_text(f"---\n{frontmatter_text}\n---{body}", encoding="utf-8")
PYEOF
}

# ─── Get current CLI type (tmux metadata) ───
get_current_pane_cli() {
    local pane="$1"
    tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null | tr -d '[:space:]' || echo "claude"
}

# ─── Send /exit ───
send_exit() {
    local pane="$1"
    local current_cli="$2"

    log "Sending exit command to ${pane} (current CLI: ${current_cli})"

    case "$current_cli" in
        codex)
            # Codex: suggestion UI dismissal → Ctrl-C → /exit
            tmux send-keys -t "$pane" Escape 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" C-c 2>/dev/null || true
            sleep 0.5
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        claude)
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        copilot|kimi|antigravity)
            tmux send-keys -t "$pane" C-c 2>/dev/null || true
            sleep 0.5
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
        cursor)
            tmux send-keys -t "$pane" "/quit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" "" Enter 2>/dev/null || true
            ;;
        *)
            tmux send-keys -t "$pane" "/exit" 2>/dev/null || true
            sleep 0.3
            tmux send-keys -t "$pane" Enter 2>/dev/null || true
            ;;
    esac
}

# ─── Wait for shell prompt (max 15s) ───
wait_for_shell_prompt() {
    local pane="$1"
    local max_wait=15
    local waited=0

    log "Waiting for shell prompt on ${pane}..."

    while [ "$waited" -lt "$max_wait" ]; do
        sleep 1
        waited=$((waited + 1))

        local last_lines
        last_lines=$(tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^$' | tail -3)

        # Shell prompt detection patterns
        # PS1 contains a custom prompt (from shutsujin) or standard $/%
        if echo "$last_lines" | grep -qE '[\$%#❯►] *$'; then
            log "Shell prompt detected after ${waited}s"
            return 0
        fi

        # Detect CLI exit messages like "exit" / "Bye"
        if echo "$last_lines" | grep -qiE '(bye|goodbye|exiting|exit)'; then
            sleep 1  # Wait a bit after exit message before prompt appears
            log "CLI exit message detected after ${waited}s"
            return 0
        fi
    done

    log "WARN: Shell prompt not detected after ${max_wait}s. Proceeding anyway."
    return 0  # Proceed even on timeout (worst case is command gets sent anyway)
}

# ─── Normalize model display name (using get_model_display_name from cli_adapter.sh) ───
# get_model_display_name is already sourced from cli_adapter.sh

# ─── Update tmux pane metadata ───
update_pane_metadata() {
    local pane="$1"
    local new_cli_type="$2"
    local display_name="$3"

    log "Updating pane metadata: @agent_cli=${new_cli_type}, @model_name=${display_name}"

    tmux set-option -p -t "$pane" @agent_cli "$new_cli_type" 2>/dev/null || true
    tmux set-option -p -t "$pane" @model_name "$display_name" 2>/dev/null || true
    tmux select-pane -t "$pane" -T "$display_name" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Main logic
# ═══════════════════════════════════════════════════════════════

# Parse arguments
if [ $# -lt 1 ]; then
    usage
fi

# If --help is the first argument
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
fi

AGENT_ID="$1"
shift

NEW_TYPE=""
NEW_MODEL=""
NEW_VARIANT=""
NEW_EFFORT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --type)
            NEW_TYPE="$2"
            shift 2
            ;;
        --model)
            NEW_MODEL="$2"
            shift 2
            ;;
        --effort)
            NEW_EFFORT="$2"
            shift 2
            ;;
        --variant)
            NEW_VARIANT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Validation
if [[ -n "$NEW_TYPE" ]] && ! _cli_adapter_is_valid_cli "$NEW_TYPE"; then
    log "ERROR: Invalid CLI type: ${NEW_TYPE}. Allowed: ${CLI_ADAPTER_ALLOWED_CLIS}"
    exit 1
fi
if [[ -n "$NEW_TYPE" ]]; then
    NEW_TYPE=$(_cli_adapter_normalize_cli_type "$NEW_TYPE")
fi

if [[ -n "$NEW_EFFORT" && ! "$NEW_EFFORT" =~ ^(low|medium|high|xhigh|max)$ ]]; then
    log "ERROR: Invalid effort: ${NEW_EFFORT}. Allowed: low, medium, high, xhigh, max"
    exit 1
fi

# Step 0: Resolve pane
PANE_TARGET=$(resolve_pane "$AGENT_ID")
if [ -z "$PANE_TARGET" ]; then
    exit 1
fi
log "=== Starting CLI switch for ${AGENT_ID} (pane: ${PANE_TARGET}) ==="

# Step 0.5: If --model is specified but --type is not, safely infer CLI type
if [[ -n "$NEW_MODEL" && -z "$NEW_TYPE" ]]; then
    case "$NEW_MODEL" in
        gpt-5.3-codex*|gpt-5-codex*)
            NEW_TYPE="codex"
            log "Auto-inferred type=codex from model=${NEW_MODEL}"
            ;;
        */*)
            if [[ "$(get_cli_type "$AGENT_ID")" == "opencode" ]]; then
                NEW_TYPE="opencode"
                log "Preserving type=opencode for provider-qualified model=${NEW_MODEL}"
            else
                log "ERROR: provider-qualified model IDs are ambiguous without --type; use --type opencode --model ${NEW_MODEL}"
                exit 1
            fi
            ;;
        claude-*)
            NEW_TYPE="claude"
            log "Auto-inferred type=claude from model=${NEW_MODEL}"
            ;;
    esac
fi

# Step 1: Update settings.yaml (only when --type/--model/--variant is specified)
if [[ -n "$NEW_TYPE" || -n "$NEW_MODEL" || -n "$NEW_VARIANT" || -n "$NEW_EFFORT" ]]; then
    update_settings_yaml "$AGENT_ID" "$NEW_TYPE" "$NEW_MODEL" "$NEW_VARIANT" "$NEW_EFFORT"
fi

# Step 2: Retrieve CLI info after switching (after settings.yaml updates)
TARGET_CLI_TYPE=$(get_cli_type "$AGENT_ID")
TARGET_MODEL=$(get_agent_model "$AGENT_ID")
TARGET_EFFORT=$(get_agent_effort "$AGENT_ID")
TARGET_VARIANT=$(_cli_adapter_read_yaml "cli.agents.${AGENT_ID}.variant" "")
if [[ "$TARGET_CLI_TYPE" == "opencode" ]]; then
    sync_opencode_agent_frontmatter "$AGENT_ID" "$TARGET_MODEL" "$TARGET_VARIANT"
fi
TARGET_CMD=$(build_cli_command "$AGENT_ID")

log "Target: cli=${TARGET_CLI_TYPE}, model=${TARGET_MODEL}, effort=${TARGET_EFFORT:-<unset>}, cmd=${TARGET_CMD}"

# Step 3: Exit current CLI using /exit
CURRENT_CLI=$(get_current_pane_cli "$PANE_TARGET")
log "Current CLI: ${CURRENT_CLI}"
send_exit "$PANE_TARGET" "$CURRENT_CLI"

# Step 4: Wait for shell prompt
wait_for_shell_prompt "$PANE_TARGET"

# Step 5: Send the new CLI command
log "Launching new CLI: ${TARGET_CMD}"
tmux send-keys -t "$PANE_TARGET" "$TARGET_CMD" 2>/dev/null || true
sleep 0.3
tmux send-keys -t "$PANE_TARGET" Enter 2>/dev/null || true

# Step 6: Update tmux pane metadata
DISPLAY_NAME=$(get_model_display_name "$AGENT_ID")
update_pane_metadata "$PANE_TARGET" "$TARGET_CLI_TYPE" "$DISPLAY_NAME"

log "=== CLI switch complete: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL} (${DISPLAY_NAME}) ==="
echo "OK: ${AGENT_ID} → ${TARGET_CLI_TYPE}/${TARGET_MODEL}"

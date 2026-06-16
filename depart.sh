#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# depart.sh — V2 specialist team departure
#
# Brings up the v2 topology: 1 shogun pane + 8 specialist panes across 2
# multiagent windows. Launches inbox_watcher for each pane, optionally starts
# the Telegram/ntfy listener, runs an MCP health check, and prints a final
# formation map.
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
    cat <<'HELP'
🏯 multi-agent-shogun Departure Script (V2 specialist team)

Usage: ./depart.sh [options]

Options:
  -c, --clean             Clean start: backup + reset queue + init dashboard.
                          If omitted, reuse existing sessions (idempotent).
  -s, --setup-only        Setup tmux session only; do not launch agent CLIs.
  -S, --silent            Silent mode (saves API costs on completion echoes).
  -shell, --shell SH      Set shell prompt (bash or zsh). Default from settings.yaml.
  --auto-mode-on          Launch with --permission-mode auto-approved.
  --permission-mode M     Explicitly specify CLI permission mode.
  -h, --help              Show this help.

Examples:
  ./depart.sh                       # Launch all (default; idempotent)
  ./depart.sh -c                    # Clean start
  ./depart.sh -s                    # Setup panes only
  ./depart.sh --permission-mode plan  # Plan mode for Claude
  PERMISSION_FLAG=--yolo ./depart.sh  # Use --yolo for Copilot

Formations (V2 specialist team):
  shogun                  → Opus   (Commander)
  orchestrator            → Opus   (Task manager)
  oracle                  → Opus   (Analysis L4-L6)
  council                 → Opus   (Evaluation)
  explorer                → Haiku  (Recon)
  librarian, designer, fixer, observer → Sonnet (Execution)

Display:
  tmux attach -t shogun        # Shogun's camp
  tmux attach -t multiagent    # Specialists (ops + research windows)

Companion scripts:
  ./cleanup.sh                  # Kill sessions for a fresh restart
HELP
}

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "${SCRIPT_DIR}/scripts/shutsujin_v2_constants.sh"

set -u

# ─── Defaults ───────────────────────────────────────────────────────────────
PERMISSION_FLAG="${PERMISSION_FLAG:---dangerously-skip-permissions}"
CLI_DEFAULT="${CLI_DEFAULT:-claude}"
SHOGUN_NO_THINKING=false

# ponytail: BSD sed on macOS doesn't support \U; use awk for portability
title_case() { awk '{print toupper(substr($0,1,1)) substr($0,2)}'; }
CLEAN_MODE=false
SETUP_ONLY=false
SILENT_MODE=false
SHELL_SETTING="bash"
if [ -f "./config/settings.yaml" ]; then
    SHELL_SETTING=$(grep "^shell:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "bash")
fi
LANG_SETTING="en"
if [ -f "./config/settings.yaml" ]; then
    LANG_SETTING=$(grep "^language:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "en")
fi

# ─── Option parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)         CLEAN_MODE=true; shift ;;
        -s|--setup-only)    SETUP_ONLY=true; shift ;;
        -S|--silent)        SILENT_MODE=true; shift ;;
        -shell|--shell)
            [[ -n "$2" && "$2" != -* ]] || { echo "Error: --shell requires bash or zsh"; exit 1; }
            SHELL_SETTING="$2"; shift 2 ;;
        --auto-mode-on)
            PERMISSION_FLAG="--permission-mode auto-approved"; shift ;;
        --shogun-no-thinking)
            SHOGUN_NO_THINKING=true; shift ;;
        --permission-mode)
            [[ -n "$2" && "$2" != -* ]] || { echo "Error: --permission-mode requires a value"; exit 1; }
            PERMISSION_FLAG="--permission-mode $2"; shift 2 ;;
        -h|--help)
            show_help; exit 0 ;;
        *)
            echo "Unknown option: $1. Run ./depart.sh -h for help."; exit 1 ;;
    esac
done

# ─── Logging (Sengoku style) ────────────────────────────────────────────────
log_info()    { echo -e "\033[1;33m[INFO]\033[0m    $*"; }
log_success() { echo -e "\033[1;32m[SUCCESS]\033[0m $*"; }
log_war()     { echo -e "\033[1;31m[ALERT]\033[0m   $*"; }
log_step()    { echo -e "\n\033[1;36m━━━ $* ━━━\033[0m"; }

# ─── Preflight: tmux installed? ─────────────────────────────────────────────
if ! command -v tmux &> /dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] tmux not found!                              ║"
    echo "  ║  Run ./first_setup.sh first.                          ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    exit 1
fi

# ─── Preflight: .venv exists? (cli_adapter.sh and others need it) ──────────
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -f "$VENV_DIR/bin/python3" ] || ! "$VENV_DIR/bin/python3" -c "import yaml" 2>/dev/null; then
    log_war "Python venv missing or broken. Creating at $VENV_DIR..."
    if command -v python3 &>/dev/null; then
        python3 -m venv "$VENV_DIR" || { echo "venv creation failed"; exit 1; }
        "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q || { echo "pip install failed"; exit 1; }
        log_success "Python venv ready"
    else
        echo "python3 not found. Run ./first_setup.sh first."; exit 1
    fi
fi

# ─── Banner ─────────────────────────────────────────────────────────────────
clear || true
echo ""
echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m███████╗██╗  ██╗██╗   ██╗████████╗███████╗██╗   ██╗     ██╗██╗███╗   ██╗\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m██╔════╝██║  ██║██║   ██║╚══██╔══╝██╔════╝██║   ██║     ██║██║████╗  ██║\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m███████╗███████║██║   ██║   ██║   ███████╗██║   ██║     ██║██║██╔██╗ ██║\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m╚════██║██╔══██║██║   ██║   ██║   ╚════██║██║   ██║██   ██║██║██║╚██╗██║\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m███████║██║  ██║╚██████╔╝   ██║   ███████║╚██████╔╝╚█████╔╝██║██║ ╚████║\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m \033[1;33m╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝  ╚════╝ ╚═╝╚═╝  ╚═══╝\033[0m \033[1;31m║\033[0m"
echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════════╣\033[0m"
echo -e "\033[1;31m║\033[0m      \033[1;37mDEPARTING FOR BATTLE!!!\033[0m  \033[1;36m⚔\033[0m  \033[1;35mTENKA FUBU!\033[0m                          \033[1;31m║\033[0m"
echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════════╝\033[0m"
echo ""
echo -e "\033[1;33m  Tenka Fubu! Setting up the battlefield... (Lang: $LANG_SETTING, Shell: $SHELL_SETTING)\033[0m"
echo ""

# ponytail: clear stale idle flags from crashed sessions — prevents watcher confusion
rm -f /tmp/shogun_idle_* 2>/dev/null || true

# ─── CLI helper functions (top-level — used by STEP 3 + STEP 5) ──────────────
# Stagger OpenCode launches (SIGILL on WSL2 if launched too fast)
# ponytail: must always return 0 — `[ ... ]` returning false (1) under set -e
# would silently exit the whole script before any CLI launches.
opencode_stagger() {
    [ "$CLI_DEFAULT" = "opencode" ] && sleep 0.1
    return 0
}

# ponytail: regex pattern matching each CLI's "ready" banner — used to wait
# for the CLI to be ready before launching the next agent (avoids race conditions)
cli_ready_pattern() {
    case "$1" in
        claude)      echo "bypass permissions|Do you trust|Claude Code" ;;
        codex)       echo 'context left|\? for shortcuts|Codex' ;;
        opencode)    echo "esc.*interrupt|OpenCode|opencode" ;;
        antigravity) echo "Antigravity|agy|type a message|Type a message|message" ;;
        *)           echo "." ;;
    esac
}

# ponytail: poll pane output up to 30s for the CLI's ready banner. Returns 0
# if banner seen, 1 on timeout (caller may still proceed; this is non-fatal).
wait_for_cli_ready() {
    local pane_target=$1 cli_type=$2
    local pattern
    pattern=$(cli_ready_pattern "$cli_type")
    for _ in {1..30}; do
        if tmux capture-pane -t "$pane_target" -p 2>/dev/null | grep -qiE "$pattern"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# ponytail: poll pane for a shell prompt (PS1 marker at end of last lines).
# Returns 0 if found within 15s, 1 on timeout. Caller may proceed either way.
wait_for_shell_prompt() {
    local pane_target=$1
    local max_wait=15 waited=0
    while [ "$waited" -lt "$max_wait" ]; do
        sleep 1
        waited=$((waited + 1))
        local last_lines
        last_lines=$(tmux capture-pane -t "$pane_target" -p 2>/dev/null | grep -v '^$' | tail -3)
        if echo "$last_lines" | grep -qE '[\$%#❯►] *$'; then
            return 0
        fi
    done
    return 1
}

# ponytail: poll ALL panes in parallel for CLI banner. Returns 0 if all
# ready within 30s, 1 if any timed out. Stdout lists which panes are ready.
wait_for_all_cli_ready() {
    local cli_type=$1; shift
    local panes=("$@")
    local pattern
    pattern=$(cli_ready_pattern "$cli_type")
    local max_wait=30 waited=0
    local ready_count=0 total=${#panes[@]}
    while [ "$waited" -lt "$max_wait" ] && [ "$ready_count" -lt "$total" ]; do
        ready_count=0
        for p in "${panes[@]}"; do
            if tmux capture-pane -t "$p" -p 2>/dev/null | grep -qiE "$pattern"; then
                ready_count=$((ready_count + 1))
            fi
        done
        if [ "$ready_count" -eq "$total" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# ponytail: poll ALL panes in parallel for shell prompt.
wait_for_all_shell_prompts() {
    local panes=("$@")
    local max_wait=10 waited=0
    local ready_count=0 total=${#panes[@]}
    while [ "$waited" -lt "$max_wait" ] && [ "$ready_count" -lt "$total" ]; do
        ready_count=0
        for p in "${panes[@]}"; do
            if tmux capture-pane -t "$p" -p 2>/dev/null | grep -qE '[\$%#❯►] *$'; then
                ready_count=$((ready_count + 1))
            fi
        done
        if [ "$ready_count" -eq "$total" ]; then
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1: Always kill + recreate our own sessions (fast restart)
#
# We own shogun + multiagent. Killing them on every run avoids the per-pane
# /exit dance and 15s prompt polls. --clean adds queue/dashboard reset on top.
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 1: Session setup"
log_info "♻️  Restarting shogun + multiagent sessions (we own them)..."
for s in shogun multiagent; do
    tmux kill-session -t "$s" 2>/dev/null && log_info "  └─ killed: $s" || log_info "  └─ not found: $s"
done
if [ "$CLEAN_MODE" = true ]; then
    log_info "🧹 --clean: also resetting queue + dashboard..."
    bash "$SCRIPT_DIR/cleanup.sh" >/dev/null 2>&1 || true
    sleep 1
    log_success "  └─ clean slate ready (sessions + queue + dashboard)"
else
    log_info "📜 Preserving queue + dashboard (idempotent). Use -c to also reset those."
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2: --clean → backup + reset queue + init dashboard
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 2: Queue + dashboard"
if [ "$CLEAN_MODE" = true ]; then
    # Backup if previous records exist
    if [ -f "$SCRIPT_DIR/queue/shogun_to_orchestrator.yaml" ] || [ -f "$SCRIPT_DIR/dashboard.md" ]; then
        BACKUP_DIR="$SCRIPT_DIR/logs/backup_$(date '+%Y%m%d_%H%M%S')"
        mkdir -p "$BACKUP_DIR"
        [ -f "$SCRIPT_DIR/dashboard.md" ] && cp "$SCRIPT_DIR/dashboard.md" "$BACKUP_DIR/" 2>/dev/null
        [ -d "$SCRIPT_DIR/queue/reports" ] && cp -r "$SCRIPT_DIR/queue/reports" "$BACKUP_DIR/" 2>/dev/null
        [ -d "$SCRIPT_DIR/queue/tasks" ]   && cp -r "$SCRIPT_DIR/queue/tasks"   "$BACKUP_DIR/" 2>/dev/null
        [ -f "$SCRIPT_DIR/queue/shogun_to_orchestrator.yaml" ] && cp "$SCRIPT_DIR/queue/shogun_to_orchestrator.yaml" "$BACKUP_DIR/" 2>/dev/null
        log_info "📦 Backed up to $BACKUP_DIR"
    fi

    # Reset queue files
    mkdir -p queue/inbox queue/reports queue/tasks queue/archive
    echo "messages: []" > queue/inbox/shogun.yaml
    for r in $(v2_role_list | tr ' ' '\n' | grep -v '^shogun$'); do
        echo "messages: []" > "queue/inbox/${r}.yaml"
        cat > "queue/tasks/${r}.yaml" <<EOF
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
        cat > "queue/reports/${r}_report.yaml" <<EOF
worker_id: ${r}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    done
    : > queue/shogun_to_orchestrator.yaml  # truncate
    log_success "📜 Queue + tasks + reports reset"

    # Reset dashboard
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M")
    cat > dashboard.md <<EOF
# 📊 Battle Status Report
Last Updated: ${TIMESTAMP}

## 🚨 Action Required - Awaiting Lord's Decision
None

## 🔄 In Progress - Currently in Battle
None

## ✅ Today's Achievements
| Time | Battlefield | Mission | Result |
|------|-------------|---------|--------|

## 🎯 Skill Candidates - Pending Approval
None

## 🛠️ Generated Skills
None

## ⏸️ Standby
None

## ❓ Questions for Lord
None
EOF
    log_success "📊 Dashboard initialized"
else
    log_info "📜 Retaining previous queue, reports, and dashboard"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3: Shogun session
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 3: Shogun main camp"
if ! tmux has-session -t shogun 2>/dev/null; then
    tmux new-session -d -s shogun -n main
fi
tmux set-option -g window-size latest
tmux set-option -g aggressive-resize on

# cd + custom PS1 + clear (matches old behavior)
case "$SHELL_SETTING" in
    zsh) PS1_FORMAT="(%F{magenta}%BShogun%b%f) %F{green}%B%~%b%f%# " ;;
    *)   PS1_FORMAT='(\[\033[1;35m\]Shogun\[\033[0m\]) \[\033[1;32m\]\w\[\033[0m\]\$ ' ;;
esac
tmux send-keys -t shogun:main "cd \"$(pwd)\" && export PS1='${PS1_FORMAT}' && clear" Enter
wait_for_shell_prompt "shogun:main" || log_war "👑 Shogun shell prompt not detected within 15s"
tmux select-pane -t shogun:main -P 'bg=#002b36'
tmux set-option -p -t shogun:main @agent_id "shogun"
SHOGUN_MODEL_DISPLAY=$(v2_model_for shogun | title_case)
tmux set-option -p -t shogun:main @model_name "$SHOGUN_MODEL_DISPLAY"
tmux set-option -p -t shogun:main @current_task ""

# Show model name in pane border
tmux set-option -t shogun -w pane-border-status top
tmux set-option -t shogun -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'
log_success "👑 Shogun main camp established"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4: Multiagent session + 2 windows with 4 panes each
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 4: Multiagent camps (ops + research)"

if ! tmux has-session -t multiagent 2>/dev/null; then
    tmux new-session -d -s multiagent -n ops
    tmux new-window -t multiagent -n research
fi

# Pane-border format for multiagent
tmux set-option -t multiagent -w pane-border-status top
tmux set-option -t multiagent -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

# ─── Pane creation helper ──────────────────────────────────────────────────
# Usage: start_specialist_pane <role> <session> <window> <pane_index> <cli>
#
# Idempotent: if pane already exists with correct @agent_id, no-op. Otherwise
# split-window only if no pane exists at the target index, then configure.
start_specialist_pane() {
    local role=$1 session=$2 window=$3 pane_idx=$4 cli=$5
    local target="${session}:${window}.${pane_idx}"

    # Idempotency: skip if already correctly configured
    local existing expected
    existing=$(tmux list-panes -t "${session}:${window}" -F '#{pane_index}:#{@agent_id}' \
        2>/dev/null | sed -n "$((pane_idx + 1))p" || true)
    expected="${pane_idx}:${role}"
    [ "$existing" = "$expected" ] && return 0

    # Split only if no pane at target index (repair unconfigured panes in place)
    # ponytail: split the previous pane (pane_idx - 1) so the new pane always
    # lands at the target index — keeps indexes stable across multiple splits.
    local pane_exists
    pane_exists=$(tmux list-panes -t "${session}:${window}" -F '#{pane_index}' \
        2>/dev/null | grep -w "^${pane_idx}$" || true)
    if [ -z "$pane_exists" ]; then
        if [ "$pane_idx" -gt 0 ]; then
            tmux split-window -h -t "${session}:${window}.$((pane_idx - 1))"
        else
            # Initial pane 0 already exists from new-session; nothing to split
            :
        fi
    fi

    # Configure
    local model color model_display
    model=$(v2_model_for "$role")
    color=$(v2_color_for "$role")
    model_display=$(echo "$model" | title_case)
    tmux set-option -p -t "$target" @agent_id "$role"
    tmux set-option -p -t "$target" @model_name "$model_display"
    tmux set-option -p -t "$target" @current_task ""
    tmux select-pane -t "$target" -T "$role"
    tmux select-pane -t "$target" -P "bg=${color}"
}

# Ops window: orchestrator, fixer, designer, observer
OPS_ROLES=(orchestrator fixer designer observer)
for idx in "${!OPS_ROLES[@]}"; do
    start_specialist_pane "${OPS_ROLES[$idx]}" "multiagent" "ops" "$idx" "$CLI_DEFAULT"
done
tmux select-layout -t multiagent:ops even-horizontal
log_success "⚔️  ops window: orchestrator, fixer, designer, observer"

# Research window: explorer, librarian, oracle, council
RESEARCH_ROLES=(explorer librarian oracle council)
for idx in "${!RESEARCH_ROLES[@]}"; do
    start_specialist_pane "${RESEARCH_ROLES[$idx]}" "multiagent" "research" "$idx" "$CLI_DEFAULT"
done
tmux select-layout -t multiagent:research even-horizontal
log_success "🔬 research window: explorer, librarian, oracle, council"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 5: Launch CLIs (skip if --setup-only)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$SETUP_ONLY" = false ]; then
    log_step "STEP 5: Launching CLIs"

    # ponytail: --shogun-no-thinking -> set roles.shogun.thinking=false in settings.yaml
    if [ "$SHOGUN_NO_THINKING" = true ] && [ -f ./config/settings.yaml ]; then
        "$VENV_DIR/bin/python3" - <<'PY' 2>/dev/null && log_info "👑 shogun thinking disabled for this session" || true
import yaml
f = './config/settings.yaml'
with open(f) as fh:
    d = yaml.safe_load(fh) or {}
d.setdefault('roles', {}).setdefault('shogun', {})['thinking'] = False
with open(f, 'w') as fh:
    yaml.safe_dump(d, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
    fi

    # CLI availability check
    if ! command -v "$CLI_DEFAULT" &> /dev/null; then
        log_war "$CLI_DEFAULT not found. Run ./first_setup.sh first."
        exit 1
    fi

    # Phase A: collect all 8 pane targets + send claude command to each
    # (fire-and-forget — no per-pane wait between sends).
    declare -a ALL_PANES=()
    declare -a ROLE_MODEL=()
    ALL_PANES+=("shogun:main")
    ROLE_MODEL+=("shogun")
    for r in $(v2_role_list | tr ' ' '\n' | grep -v '^shogun$'); do
        pane="$(v2_pane_for "$r")"
        ALL_PANES+=("$pane")
        ROLE_MODEL+=("$r")
    done

    # Phase B: wait for all 8 shells to be at a prompt (parallel poll, 10s).
    wait_for_all_shell_prompts "${ALL_PANES[@]}" || log_war "Some shell prompts not detected within 10s"

    # Phase C: fire the claude launch command at every pane in one pass.
    for i in "${!ALL_PANES[@]}"; do
        tmux send-keys -t "${ALL_PANES[$i]}" "${CLI_DEFAULT} --model $(v2_model_for "${ROLE_MODEL[$i]}") ${PERMISSION_FLAG}" Enter
    done
    opencode_stagger

    # Phase D: wait for ALL 8 CLI banners in parallel (single 30s poll).
    if wait_for_all_cli_ready "$CLI_DEFAULT" "${ALL_PANES[@]}"; then
        log_success "👑 All 8 agents summoned ($(v2_model_for shogun) shogun + 7 specialists)"
    else
        log_war "Some CLIs did not show ready banner within 30s (continuing anyway)"
    fi

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 6: Ninja ASCII art
    # ═══════════════════════════════════════════════════════════════════════
    log_step "STEP 6: Battle cry"
    echo -e "\033[1;35m  ┌──────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m  │\033[0m                  \033[1;37m[ NINJA WARRIOR ]\033[0m  Ryu Hayabusa (CC0)                  \033[1;35m│\033[0m"
    echo -e "\033[1;35m  └──────────────────────────────────────────────────────────────────────────┘\033[0m"
    cat <<'NINJA_EOF'
...................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░▒▒▒▒          ▒▒▒▒▒▒▒▒░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒                             ...................................
NINJA_EOF
    echo ""
    echo -e "                                    \033[1;35m\" Tenka Fubu! Seize victory! \"\033[0m"
    echo ""
else
    log_info "STEP 5: --setup-only, skipping CLI launch"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 7: Inbox watchers (one per pane)
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 7: Inbox watchers"

# Kill any leftover watcher processes (idempotent for re-runs)
pkill -f "inbox_watcher.sh" 2>/dev/null || true
sleep 0.5

LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
for role in $(v2_role_list); do
    pane_target="$(v2_pane_for "$role")"
    if ! pgrep -f "inbox_watcher.sh ${role} " >/dev/null 2>&1 \
       && ! pgrep -f "inbox_watcher.sh ${role}\$" >/dev/null 2>&1; then
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "$role" "$pane_target" "$CLI_DEFAULT" \
            >"${LOG_DIR}/inbox_watcher_${role}.log" 2>&1 &
        log_success "  └─ watcher started: $role"
    else
        log_info "  └─ watcher already running: $role"
    fi
done

# Shogun → Telegram relay (outbound)
pkill -f "shogun_telegram_relay.sh" 2>/dev/null || true
nohup bash "$SCRIPT_DIR/scripts/shogun_telegram_relay.sh" \
    >>"$LOG_DIR/shogun_telegram_relay.log" 2>&1 &
log_success "  └─ shogun_telegram_relay started (pid $!)"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8: Telegram / ntfy listener (inbound)
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 8: Inbound listener"

TELEGRAM_ENV="./config/telegram.env"
TELEGRAM_CONFIGURED=false
if [ -f "$TELEGRAM_ENV" ]; then
    # shellcheck disable=SC1090
    source "$TELEGRAM_ENV"
    if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ "$TELEGRAM_BOT_TOKEN" != "your_bot_token_here" ] \
       && [ -n "${TELEGRAM_CHAT_ID:-}" ]  && [ "$TELEGRAM_CHAT_ID" != "your_chat_id_here" ]; then
        TELEGRAM_CONFIGURED=true
    fi
fi

if [ "$TELEGRAM_CONFIGURED" = true ]; then
    pkill -f "telegram_listener.py" 2>/dev/null || true
    nohup "$VENV_DIR/bin/python3" "$SCRIPT_DIR/scripts/telegram_listener.py" \
        >>"$LOG_DIR/telegram_listener.log" 2>&1 &
    log_success "📱 Telegram listener started (pid $!)"
else
    NTFY_TOPIC=$(grep 'ntfy_topic:' ./config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
    if [ -n "$NTFY_TOPIC" ]; then
        pkill -f "ntfy_listener.sh" 2>/dev/null || true
        nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
        disown
        log_success "📱 ntfy listener started (topic: $NTFY_TOPIC)"
    else
        log_info "📱 No inbound listener configured (set TELEGRAM_BOT_TOKEN/CHAT_ID or ntfy_topic)"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 8.5: Archive old ntfy_inbox (older than 7 days, processed)
# ═════════════════════════════════════════════════════════════════════════════
if [ -f ./queue/ntfy_inbox.yaml ]; then
    _archive_result=$("$VENV_DIR/bin/python3" -c "
import yaml, sys
from datetime import datetime, timedelta, timezone

INBOX = './queue/ntfy_inbox.yaml'
ARCHIVE = './queue/ntfy_inbox_archive.yaml'
DAYS = 7

with open(INBOX) as f:
    data = yaml.safe_load(f) or {}

entries = data.get('inbox', []) or []
if not entries:
    sys.exit(0)

cutoff = datetime.now(timezone(timedelta(hours=9))) - timedelta(days=DAYS)
recent, old = [], []

for e in entries:
    ts = e.get('timestamp', '')
    try:
        dt = datetime.fromisoformat(str(ts))
        if dt < cutoff and e.get('status') == 'processed':
            old.append(e)
        else:
            recent.append(e)
    except Exception:
        recent.append(e)

if not old:
    sys.exit(0)

try:
    with open(ARCHIVE) as f:
        archive = yaml.safe_load(f) or {}
except FileNotFoundError:
    archive = {}
archive_entries = archive.get('inbox', []) or []
archive_entries.extend(old)
with open(ARCHIVE, 'w') as f:
    yaml.dump({'inbox': archive_entries}, f, allow_unicode=True, default_flow_style=False)

with open(INBOX, 'w') as f:
    yaml.dump({'inbox': recent}, f, allow_unicode=True, default_flow_style=False)

print(f'Archived {len(old)} entries, kept {len(recent)} entries')
" 2>/dev/null) || true
    if [ -n "$_archive_result" ]; then
        log_info "📱 ntfy_inbox: $_archive_result → ntfy_inbox_archive.yaml"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 9: MCP health check
# ═════════════════════════════════════════════════════════════════════════════
log_step "STEP 9: MCP health check"
if [ -f "$SCRIPT_DIR/scripts/mcp_health_check.sh" ]; then
    log_info "  └─ waiting 8s for agents to initialize..."
    sleep 8
    if bash "$SCRIPT_DIR/scripts/mcp_health_check.sh" >>"$LOG_DIR/mcp_health.log" 2>&1; then
        log_success "  └─ MCP health OK"
    else
        log_war "  └─ MCP health check returned errors — see logs/mcp_health.log"
    fi
else
    log_info "  └─ mcp_health_check.sh not found, skipping"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 10: Final formation map
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📺 Tmux Sessions                                        │"
echo "  └──────────────────────────────────────────────────────────┘"
tmux list-sessions 2>/dev/null | sed 's/^/     /'
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📋 Battle Formation Map                                 │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "     [shogun session] Shogun Main Camp"
echo "     ┌─────────────────────────────┐"
echo "     │  shogun:main.0              │  ← Commander / Project Overseer"
echo "     └─────────────────────────────┘"
echo ""
echo "     [multiagent session] ops window (4 specialists)"
echo "     ┌─────────┬─────────┬─────────┬─────────┐"
echo "     │orchestr.│  fixer  │designer │observer │"
echo "     │  (Opus) │ (Sonnet)│ (Sonnet)│ (Sonnet)│"
echo "     └─────────┴─────────┴─────────┴─────────┘"
echo ""
echo "     [multiagent session] research window (4 specialists)"
echo "     ┌─────────┬─────────┬─────────┬─────────┐"
echo "     │ explorer│librarian│ oracle  │ council │"
echo "     │ (Haiku) │ (Sonnet)│  (Opus) │  (Opus) │"
echo "     └─────────┴─────────┴─────────┴─────────┘"
echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  🏯 DEPARTURE PREPARATIONS COMPLETE! TENKA FUBU!         ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Next steps:"
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  Attach to Shogun:                                       │"
echo "  │     tmux attach-session -t shogun   (alias: css)         │"
echo "  │                                                          │"
echo "  │  Attach to specialists:                                  │"
echo "  │     tmux attach-session -t multiagent   (alias: csm)     │"
echo "  │                                                          │"
echo "  │  Each agent has already loaded its instructions.         │"
echo "  │  You can start commanding immediately.                   │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ════════════════════════════════════════════════════════════"
echo "   Tenka Fubu! Seize victory!"
echo "  ════════════════════════════════════════════════════════════"
echo ""

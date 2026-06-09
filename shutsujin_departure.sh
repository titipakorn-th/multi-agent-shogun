#!/usr/bin/env bash
# 🏯 multi-agent-shogun Departure Script (For daily startup)
# Daily Deployment Script for Multi-Agent Orchestration System
#
# Usage:
#   ./shutsujin_departure.sh           # Launch all agents (maintain previous state)
#   ./shutsujin_departure.sh -c        # Reset queue and launch (clean start)
#   ./shutsujin_departure.sh -s        # Setup only (no agent launch)
#   ./shutsujin_departure.sh --auto-mode-on          # Launch Claude with permissions auto-approved
#   ./shutsujin_departure.sh --permission-mode plan  # Explicitly specify Claude permission mode
#   ./shutsujin_departure.sh -h        # Display help

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Read language setting (default: ja)
LANG_SETTING="ja"
if [ -f "./config/settings.yaml" ]; then
    LANG_SETTING=$(grep "^language:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "ja")
fi

# Read shell setting (default: bash)
SHELL_SETTING="bash"
if [ -f "./config/settings.yaml" ]; then
    SHELL_SETTING=$(grep "^shell:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "bash")
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Python venv preflight check
# ───────────────────────────────────────────────────────────────────────────────
# inbox_write.sh, inbox_watcher.sh, and cli_adapter.sh depend on .venv/bin/python3.
# If venv does not exist, automatically create it (safety measure for first run after git pull).
# ═══════════════════════════════════════════════════════════════════════════════
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -f "$VENV_DIR/bin/python3" ] || ! "$VENV_DIR/bin/python3" -c "import yaml" 2>/dev/null; then
    echo -e "\033[1;33m[INFO]\033[0m Setting up Python venv..."
    if command -v python3 &>/dev/null; then
        python3 -m venv "$VENV_DIR" 2>/dev/null || {
            echo -e "\033[1;31m[ERROR]\033[0m python3 -m venv failed. The python3-venv package might be required."
            echo "  Ubuntu/Debian: sudo apt-get install python3-venv"
            exit 1
        }
        "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q 2>/dev/null || {
            echo -e "\033[1;31m[ERROR]\033[0m pip install failed."
            exit 1
        }
        echo -e "\033[1;32m[SUCCESS]\033[0m Python venv setup complete."
    else
        echo -e "\033[1;31m[ERROR]\033[0m python3 not found. Please run first_setup.sh."
        exit 1
    fi
fi

# Load CLI Adapter (Multi-CLI Support)
if [ -f "$SCRIPT_DIR/lib/cli_adapter.sh" ]; then
    source "$SCRIPT_DIR/lib/cli_adapter.sh"
    CLI_ADAPTER_LOADED=true
else
    CLI_ADAPTER_LOADED=false
fi

# Dynamically retrieve Ashigaru ID list and count (from settings.yaml)
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    _ASHIGARU_IDS_STR=$(get_ashigaru_ids)
else
    _ASHIGARU_IDS_STR="ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"
fi
_ASHIGARU_COUNT=$(echo "$_ASHIGARU_IDS_STR" | wc -w | tr -d ' ')

# Colored logging functions (Sengoku style)
log_info() {
    echo -e "\033[1;33m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m[SUCCESS]\033[0m $1"
}

log_war() {
    echo -e "\033[1;31m[ALERT]\033[0m $1"
}

# OpenCode can trigger SIGILL on WSL2 if multiple processes are launched in quick succession,
# so we add a short sleep delay specifically when launching OpenCode agents.
opencode_startup_delay() {
    local cli_type="$1"
    if [ "$cli_type" = "opencode" ]; then
        sleep 0.1
    fi
}

cli_ready_pattern() {
    local cli_type="$1"
    case "$cli_type" in
        claude)      echo "bypass permissions|Do you trust|Claude Code" ;;
        codex)       echo "context left|\\? for shortcuts|Codex" ;;
        opencode)    echo "esc.*interrupt|OpenCode|opencode" ;;
        antigravity) echo "Antigravity|agy|type a message|Type a message|message" ;;
        *)           echo "." ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# Prompt generator function (bash/zsh compatible)
# ───────────────────────────────────────────────────────────────────────────────
# Usage: generate_prompt "label" "color" "shell"
# Colors: red, green, blue, magenta, cyan, yellow
# ═══════════════════════════════════════════════════════════════════════════════
generate_prompt() {
    local label="$1"
    local color="$2"
    local shell_type="$3"

    if [ "$shell_type" == "zsh" ]; then
        # For zsh: %F{color}%B...%b%f format
        echo "(%F{${color}}%B${label}%b%f) %F{green}%B%~%b%f%# "
    else
        # For bash: \[\033[...m\] format
        local color_code
        case "$color" in
            red)     color_code="1;31" ;;
            green)   color_code="1;32" ;;
            yellow)  color_code="1;33" ;;
            blue)    color_code="1;34" ;;
            magenta) color_code="1;35" ;;
            cyan)    color_code="1;36" ;;
            *)       color_code="1;37" ;;  # white (default)
        esac
        echo "(\[\033[${color_code}m\]${label}\[\033[0m\]) \[\033[1;32m\]\w\[\033[0m\]\$ "
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Parse options
# ═══════════════════════════════════════════════════════════════════════════════
SETUP_ONLY=false
OPEN_TERMINAL=false
CLEAN_MODE=false
KESSEN_MODE=false
SHOGUN_NO_THINKING=false
SILENT_MODE=false
SHELL_OVERRIDE=""
# Permission flag (default: dangerously-skip-permissions for backward compat)
PERMISSION_FLAG="--dangerously-skip-permissions"

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--setup-only)
            SETUP_ONLY=true
            shift
            ;;
        -c|--clean)
            CLEAN_MODE=true
            shift
            ;;
        -k|--kessen)
            KESSEN_MODE=true
            shift
            ;;
        -t|--terminal)
            OPEN_TERMINAL=true
            shift
            ;;
        --shogun-no-thinking)
            SHOGUN_NO_THINKING=true
            shift
            ;;
        --auto-mode-on)
            PERMISSION_FLAG="--permission-mode auto-approved"
            shift
            ;;
        --permission-mode)
            if [[ -n "$2" && "$2" != -* ]]; then
                PERMISSION_FLAG="--permission-mode $2"
                shift 2
            else
                echo "Error: Please specify a mode name for the --permission-mode option"
                exit 1
            fi
            ;;
        -S|--silent)
            SILENT_MODE=true
            shift
            ;;
        -shell|--shell)
            if [[ -n "$2" && "$2" != -* ]]; then
                SHELL_OVERRIDE="$2"
                shift 2
            else
                echo "Error: Please specify 'bash' or 'zsh' for the -shell option"
                exit 1
            fi
            ;;
        -h|--help)
            echo ""
            echo "🏯 multi-agent-shogun Departure Script"
            echo ""
            echo "Usage: ./shutsujin_departure.sh [options]"
            echo ""
            echo "Options:"
            echo "  -c, --clean         Clean start (reset queue and dashboard)"
            echo "                      If omitted, maintains previous state"
            echo "  -k, --kessen        Decisive battle formation (launch all Ashigaru using Opus)"
            echo "                      If omitted, normal formation (Ashigaru 1-7=Sonnet, Gunshi=Opus)"
            echo "  -s, --setup-only    Setup tmux session only (does not launch agents)"
            echo "  -t, --terminal      Open a new tab in Windows Terminal"
            echo "  -shell, --shell SH  Specify shell (bash or zsh)"
            echo "                      If omitted, uses setting from config/settings.yaml"
            echo "  --auto-mode-on      Launch Claude with --permission-mode auto-approved"
            echo "  --permission-mode M Explicitly specify permission mode for Claude"
            echo "  -S, --silent        Silent mode (disable Sengoku completion echoes to save API costs)"
            echo "                      If omitted, shout mode (Sengoku-style completion echoes)"
            echo "  -h, --help          Display this help message"
            echo ""
            echo "Examples:"
            echo "  ./shutsujin_departure.sh              # Launch maintaining previous state"
            echo "  ./shutsujin_departure.sh -c           # Clean start (reset queue)"
            echo "  ./shutsujin_departure.sh -s           # Setup only (no agent launch)"
            echo "  ./shutsujin_departure.sh -t           # Launch all agents + open Windows Terminal tabs"
            echo "  ./shutsujin_departure.sh -shell bash  # Launch with bash prompt"
            echo "  ./shutsujin_departure.sh -k           # Decisive battle formation (all Ashigaru=Opus)"
            echo "  ./shutsujin_departure.sh -c -k        # Clean start + Decisive battle formation"
            echo "  ./shutsujin_departure.sh -shell zsh   # Launch with zsh prompt"
            echo "  ./shutsujin_departure.sh --shogun-no-thinking  # Disable shogun thinking (specialized for relaying)"
            echo "  ./shutsujin_departure.sh --auto-mode-on        # Launch with permission auto-approved"
            echo "  ./shutsujin_departure.sh --permission-mode plan  # Explicitly specify permission mode"
            echo "  ./shutsujin_departure.sh -S           # Silent mode (no echoes)"
            echo ""
            echo "Model Configurations:"
            echo "  Shogun:      Opus (default; disable with --shogun-no-thinking)"
            echo "  Karo:        Sonnet (fast task management)"
            echo "  Gunshi:      Opus (strategic analysis & design decisions)"
            echo "  Ashigaru1-7: Sonnet (implementation force)"
            echo ""
            echo "Formations:"
            echo "  Normal Formation (default): Ashigaru 1-7=Sonnet, Gunshi=Opus"
            echo "  Decisive Battle Formation (--kessen): All Ashigaru=Opus, Gunshi=Opus"
            echo ""
            echo "Display Modes:"
            echo "  shout (default):  Sengoku-style completion echoes"
            echo "  silent (--silent):   no echoes (saves API costs)"
            echo ""
            echo "Aliases:"
            echo "  csst  → cd $HOME/multi-agent-shogun && ./shutsujin_departure.sh"
            echo "  css   → tmux attach-session -t shogun"
            echo "  csm   → tmux attach-session -t multiagent"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Run ./shutsujin_departure.sh -h to display help"
            exit 1
            ;;
    esac
done

# Override shell settings (command line options take precedence)
if [ -n "$SHELL_OVERRIDE" ]; then
    if [[ "$SHELL_OVERRIDE" == "bash" || "$SHELL_OVERRIDE" == "zsh" ]]; then
        SHELL_SETTING="$SHELL_OVERRIDE"
    else
        echo "Error: Please specify 'bash' or 'zsh' for the -shell option (specified value: $SHELL_OVERRIDE)"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Display Departure Banner (using CC0 licensed ASCII art)
# ───────────────────────────────────────────────────────────────────────────────
# [Copyright / License Display]
# Ninja ASCII art: syntax-samurai/ryu - CC0 1.0 Universal (Public Domain)
# Source: https://github.com/syntax-samurai/ryu
# "all files and scripts in this repo are released CC0 / kopimi!"
# ═══════════════════════════════════════════════════════════════════════════════
show_battle_cry() {
    clear

    # Title banner (colored)
    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗██╗  ██╗██╗   ██╗████████╗███████╗██╗   ██╗     ██╗██╗███╗   ██╗\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔════╝██║  ██║██║   ██║╚══██╔══╝██╔════╝██║   ██║     ██║██║████╗  ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗███████║██║   ██║   ██║   ███████╗██║   ██║     ██║██║██╔██╗ ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚════██║██╔══██║██║   ██║   ██║   ╚════██║██║   ██║██   ██║██║██║╚██╗██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████║██║  ██║╚██████╔╝   ██║   ███████║╚██████╔╝╚█████╔╝██║██║ ╚████║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝  ╚════╝ ╚═╝╚═╝  ╚═══╝\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m      \033[1;37mDEPARTING FOR BATTLE!!!\033[0m  \033[1;36m⚔\033[0m  \033[1;35mTENKA FUBU!\033[0m                       \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # Ashigaru formation (original)
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;34m  ╔═════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m              \033[1;37m[ ASHIGARU FORMATION - 7 MEMBERS + STRATEGIST ]\033[0m            \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚═════════════════════════════════════════════════════════════════════════════╝\033[0m"

    cat << 'ASHIGARU_EOF'

       /\      /\      /\      /\      /\      /\      /\      /\
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
     /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\
       ||      ||      ||      ||      ||      ||      ||      ||
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
      /  \    /  \    /  \    /  \    /  \    /  \    /  \    /  \
     [Ash1]  [Ash2]  [Ash3]  [Ash4]  [Ash5]  [Ash6]  [Ash7]  [Gnsi]

ASHIGARU_EOF

    echo -e "                    \033[1;36m\"\"\" Ha! Departing for battle! \"\"\"\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # System Information
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m🏯 multi-agent-shogun\033[0m  ~ \033[1;36mSengoku Multi-Agent Orchestration System\033[0m ~         \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35mShogun\033[0m: Lead  \033[1;31mKaro\033[0m: Admin  \033[1;33mGunshi\033[0m: Strategy(Opus)  \033[1;34mAshigaru\033[0m: Work x7  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# Execute banner display
show_battle_cry

echo -e "  \033[1;33mTenka Fubu! Setting up the battlefield...\033[0m"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Clean up existing sessions
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 Clearing existing camps..."
tmux kill-session -t multiagent 2>/dev/null && log_info "  └─ multiagent session cleared" || log_info "  └─ multiagent session not found"
tmux kill-session -t shogun 2>/dev/null && log_info "  └─ shogun session cleared" || log_info "  └─ shogun session not found"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1.5: Backup previous records (only during --clean, if content exists)
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    BACKUP_DIR="./logs/backup_$(date '+%Y%m%d_%H%M%S')"
    NEED_BACKUP=false

    if [ -f "./dashboard.md" ]; then
        if grep -q "cmd_" "./dashboard.md" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    # Added after checking existing dashboard.md
    if [ -f "./queue/shogun_to_karo.yaml" ]; then
        if grep -q "id: cmd_" "./queue/shogun_to_karo.yaml" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    if [ "$NEED_BACKUP" = true ]; then
        mkdir -p "$BACKUP_DIR" || true
        cp "./dashboard.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/reports" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/tasks" "$BACKUP_DIR/" 2>/dev/null || true
        cp "./queue/shogun_to_karo.yaml" "$BACKUP_DIR/" 2>/dev/null || true
        log_info "📦 Backed up previous records: $BACKUP_DIR"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Secure Queue Directory + Reset (only during --clean)
# ═══════════════════════════════════════════════════════════════════════════════

# Create queue directory if it does not exist (required for first startup)
[ -d ./queue/reports ] || mkdir -p ./queue/reports
[ -d ./queue/tasks ] || mkdir -p ./queue/tasks
# Symbolically link inbox to Linux FS (because inotifywait does not work under WSL2's /mnt/c/)
# Symlink not required on macOS since it uses fswatch
if [ "$(uname -s)" != "Darwin" ]; then
    INBOX_LINUX_DIR="$HOME/.local/share/multi-agent-shogun/inbox"
    mkdir -p "$INBOX_LINUX_DIR"  # Always run (idempotent) — prevents dangling symlink
    if [ ! -L ./queue/inbox ]; then
        [ -d ./queue/inbox ] && cp ./queue/inbox/*.yaml "$INBOX_LINUX_DIR/" 2>/dev/null && rm -rf ./queue/inbox
        ln -sf "$INBOX_LINUX_DIR" ./queue/inbox
        log_info "  └─ Created symbolic link: inbox -> Linux FS ($INBOX_LINUX_DIR)"
    fi
else
    [ -d ./queue/inbox ] || mkdir -p ./queue/inbox
fi

if [ "$CLEAN_MODE" = true ]; then
    log_info "📜 Discarding previous council records..."

    # Reset Ashigaru task files
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/tasks/ashigaru${i}.yaml << EOF
# Ashigaru ${i} Dedicated Task File
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
    done

    # Reset Strategist task file
    cat > ./queue/tasks/gunshi.yaml << EOF
# Strategist Dedicated Task File
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF

    # Reset Ashigaru report files
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/reports/ashigaru${i}_report.yaml << EOF
worker_id: ashigaru${i}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    done

    # Reset Strategist report file
    cat > ./queue/reports/gunshi_report.yaml << EOF
worker_id: gunshi
task_id: null
timestamp: ""
status: idle
result: null
EOF

    # Reset ntfy inbox
    echo "inbox:" > ./queue/ntfy_inbox.yaml

    # Reset agent inbox
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        echo "messages:" > "./queue/inbox/${agent}.yaml"
    done

    log_success "✅ Battlefield reset complete"
else
    log_info "📜 Deploying with the previous formation..."
    log_success "✅ Continuing with existing queue and reports"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Dashboard Initialization (only during --clean)
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    log_info "📊 Initializing battle status board..."
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

    # Unified English Dashboard Template (absolutely no Japanese)
    cat > ./dashboard.md << EOF
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

    log_success "  └─ Dashboard initialization complete (Lang: $LANG_SETTING, Shell: $SHELL_SETTING)"
else
    log_info "📊 Retaining previous dashboard"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Check if tmux is installed
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v tmux &> /dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] tmux not found!                              ║"
    echo "  ║  tmux not found                                       ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║  Run first_setup.sh first:                            ║"
    echo "  ║  Please run first_setup.sh first:                     ║"
    echo "  ║     ./first_setup.sh                                  ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Create shogun Session (ensuring 1 pane / window 0)
# ═══════════════════════════════════════════════════════════════════════════════
log_war "👑 Constructing Shogun's main camp..."

# Create shogun session if not exists (so shogun always exists even with -s option)
# Create window 0 named 'main' (limit to 1 window because creating a second window opens empty panes upon attach)
if ! tmux has-session -t shogun 2>/dev/null; then
    tmux new-session -d -s shogun -n main
fi

# Enable aggressive-resize + latest to handle smaller clients (e.g. mobile)
# css function handles mobile sizes without interfering with PC terminals
tmux set-option -g window-size latest
tmux set-option -g aggressive-resize on

# Specify shogun main pane as "main" (works even with base-index 1)
SHOGUN_PROMPT=$(generate_prompt "Shogun" "magenta" "$SHELL_SETTING")
tmux send-keys -t shogun:main "cd \"$(pwd)\" && export PS1='${SHOGUN_PROMPT}' && clear" Enter
tmux select-pane -t shogun:main -P 'bg=#002b36'  # Shogun's Solarized Dark
tmux set-option -p -t shogun:main @agent_id "shogun"

log_success "  └─ Shogun's main camp established"
echo ""

# Get pane-base-index (in environments where index starts at 1, panes will be 1, 2, ...)
PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.1: Create multiagent session (9 panes: karo + ashigaru 1-7 + gunshi)
# ═══════════════════════════════════════════════════════════════════════════════
log_war "⚔️ Deploying Karo, Ashigaru, and Gunshi (9 members)..."

# Create first pane
if ! tmux new-session -d -s multiagent -n "agents" 2>/dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] Failed to create tmux session 'multiagent'      ║"
    echo "  ║  tmux session 'multiagent' creation failed               ║"
    echo "  ╠════════════════════════════════════════════════════════════╣"
    echo "  ║  An existing session may be running.                     ║"
    echo "  ║  Please check and kill the existing session if needed.   ║"
    echo "  ║                                                          ║"
    echo "  ║  Check: tmux ls                                          ║"
    echo "  ║  Kill:  tmux kill-session -t multiagent                  ║"
    echo "  ╚════════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# DISPLAY_MODE: shout (default) or silent (--silent flag)
if [ "$SILENT_MODE" = true ]; then
    tmux set-environment -t multiagent DISPLAY_MODE "silent"
    echo "  📢 Display Mode: Silent (no echoes)"
else
    tmux set-environment -t multiagent DISPLAY_MODE "shout"
fi

# Create a 3x3 grid (total 9 panes)
# Pane numbers depend on pane-base-index (0 or 1)
# Split into 3 columns first
tmux split-window -h -t "multiagent:agents"
tmux split-window -h -t "multiagent:agents"

# Split each column into 3 rows
tmux select-pane -t "multiagent:agents.${PANE_BASE}"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+3))"
tmux split-window -v
tmux split-window -v

tmux select-pane -t "multiagent:agents.$((PANE_BASE+6))"
tmux split-window -v
tmux split-window -v

# Pane labels, agent IDs, and color settings — dynamically constructed from settings.yaml
PANE_LABELS=("karo")
AGENT_IDS=("karo")
PANE_COLORS=("red")
for _ai in $_ASHIGARU_IDS_STR; do
    PANE_LABELS+=("$_ai")
    AGENT_IDS+=("$_ai")
    PANE_COLORS+=("blue")
done
PANE_LABELS+=("gunshi")
AGENT_IDS+=("gunshi")
PANE_COLORS+=("yellow")

# Model name settings (dynamically constructed to show persistently in pane-border-format)
MODEL_NAMES=()
for _ai in "${AGENT_IDS[@]}"; do
    if [[ "$_ai" == "gunshi" ]]; then
        MODEL_NAMES+=("Opus")
    elif [ "$KESSEN_MODE" = true ]; then
        MODEL_NAMES+=("Opus")
    else
        MODEL_NAMES+=("Sonnet")
    fi
done

# Set uniform model display names via CLI Adapter
# get_model_display_name(): Returns shortened names like Sonnet, Opus+T, Haiku, Codex, Spark, etc.
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    for i in "${!AGENT_IDS[@]}"; do
        _agent="${AGENT_IDS[$i]}"
        MODEL_NAMES[$i]=$(get_model_display_name "$_agent")
    done
fi

for i in "${!AGENT_IDS[@]}"; do
    p=$((PANE_BASE + i))
    tmux select-pane -t "multiagent:agents.${p}" -T "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @agent_id "${AGENT_IDS[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "${MODEL_NAMES[$i]}"
    tmux set-option -p -t "multiagent:agents.${p}" @current_task ""
    PROMPT_STR=$(generate_prompt "${PANE_LABELS[$i]}" "${PANE_COLORS[$i]}" "$SHELL_SETTING")
    tmux send-keys -t "multiagent:agents.${p}" "cd \"$(pwd)\" && export PS1='${PROMPT_STR}' && clear" Enter
done

# Karo/Gunshi background colors (visual distinction)
# Note: commented out because colors do not persist in grouped sessions (2026-02-14)
# tmux select-pane -t "multiagent:agents.${PANE_BASE}" -P 'bg=#501515'          # Karo: Red
# tmux select-pane -t "multiagent:agents.$((PANE_BASE+8))" -P 'bg=#454510'      # Gunshi: Gold

# Always show model name in pane-border-format
tmux set-option -t multiagent -w pane-border-status top
tmux set-option -t multiagent -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

log_success "  └─ Karo, Ashigaru, and Gunshi camps established"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: Launch Agent CLIs (Skip if -s / --setup-only)
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SETUP_ONLY" = false ]; then
    # CLI availability check
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _default_cli=$(get_cli_type "")
        if ! validate_cli_availability "$_default_cli"; then
            exit 1
        fi
    else
        if ! command -v claude &> /dev/null; then
            log_info "⚠️  claude command not found"
            echo "  Please run first_setup.sh again:"
            echo "    ./first_setup.sh"
            exit 1
        fi
    fi

    # Clear stale flags from previous session
    rm -f /tmp/shogun_idle_*
    echo "idle flags cleared"

    log_war "👑 Summoning Agent CLIs for the army..."

    # Shogun: Build command via CLI Adapter
    _shogun_cli_type="claude"
    _shogun_cmd="claude --model opus --effort max $PERMISSION_FLAG"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _shogun_cli_type=$(get_cli_type "shogun")
        _shogun_cmd=$(build_cli_command "shogun")
    fi
    # --shogun-no-thinking -> temporarily set settings.yaml thinking=false
    if [ "$SHOGUN_NO_THINKING" = true ] && [ "$CLI_ADAPTER_LOADED" = true ]; then
        "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml
f = '${CLI_ADAPTER_SETTINGS}'
with open(f) as fh: d = yaml.safe_load(fh) or {}
d.setdefault('cli',{}).setdefault('agents',{}).setdefault('shogun',{})['thinking'] = False
with open(f,'w') as fh: yaml.safe_dump(d, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
" 2>/dev/null
        _shogun_cmd=$(build_cli_command "shogun")
        log_info "  └─ Shogun settings.yaml thinking=false configured"
    fi
    tmux set-option -p -t "shogun:main" @agent_cli "$_shogun_cli_type"
    tmux send-keys -t shogun:main "$_shogun_cmd"
    tmux send-keys -t shogun:main Enter
    opencode_startup_delay "$_shogun_cli_type"
    _shogun_display=$(get_model_display_name "shogun" 2>/dev/null || echo "Opus")
    tmux set-option -p -t "shogun:main" @model_name "$_shogun_display" 2>/dev/null || true
    log_info "  └─ Shogun (${_shogun_cli_type} / ${_shogun_display}) summoned"

    # Wait briefly for stability
    sleep 1

    # Karo (pane 0): Build command via CLI Adapter (Default: Sonnet)
    p=$((PANE_BASE + 0))
    _karo_cli_type="claude"
    _karo_cmd="claude --model sonnet --effort max $PERMISSION_FLAG"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _karo_cli_type=$(get_cli_type "karo")
        _karo_cmd=$(build_cli_command "karo")
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_karo_cli_type"
    tmux send-keys -t "multiagent:agents.${p}" "$_karo_cmd"
    tmux send-keys -t "multiagent:agents.${p}" Enter
    opencode_startup_delay "$_karo_cli_type"
    _karo_display=$(get_model_display_name "karo" 2>/dev/null || echo "Sonnet")
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "$_karo_display" 2>/dev/null || true
    log_info "  └─ Karo (${_karo_display}) summoned"

    if [ "$KESSEN_MODE" = true ]; then
        # Decisive Battle formation: Build via CLI Adapter (claude forced to Opus)
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model opus --effort max $PERMISSION_FLAG"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                if [ "$_ashi_cli_type" = "claude" ]; then
                    _ashi_cmd="claude --model opus --effort max $PERMISSION_FLAG"
                else
                    _ashi_cmd=$(build_cli_command "ashigaru${i}")
                fi
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_ashi_cli_type"
            tmux send-keys -t "multiagent:agents.${p}" "$_ashi_cmd"
            tmux send-keys -t "multiagent:agents.${p}" Enter
            opencode_startup_delay "$_ashi_cli_type"
        done
        log_info "  └─ Ashigaru 1-${_ASHIGARU_COUNT} (Decisive Battle formation) summoned"
    else
        # Normal formation: Build via CLI Adapter (Default: Sonnet for all Ashigaru)
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model sonnet --effort max $PERMISSION_FLAG"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                _ashi_cmd=$(build_cli_command "ashigaru${i}")
            fi
            tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_ashi_cli_type"
            tmux send-keys -t "multiagent:agents.${p}" "$_ashi_cmd"
            tmux send-keys -t "multiagent:agents.${p}" Enter
            opencode_startup_delay "$_ashi_cli_type"
        done
        log_info "  └─ Ashigaru 1-${_ASHIGARU_COUNT} (Normal formation) summoned"
    fi

    # Gunshi (pane _ASHIGARU_COUNT+1): Opus Thinking — Dedicated to strategy & design decisions
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_cli_type="claude"
    _gunshi_cmd="claude --model opus --effort max $PERMISSION_FLAG"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _gunshi_cli_type=$(get_cli_type "gunshi")
        _gunshi_cmd=$(build_cli_command "gunshi")
    fi
    tmux set-option -p -t "multiagent:agents.${p}" @agent_cli "$_gunshi_cli_type"
    tmux send-keys -t "multiagent:agents.${p}" "$_gunshi_cmd"
    tmux send-keys -t "multiagent:agents.${p}" Enter
    opencode_startup_delay "$_gunshi_cli_type"
    _gunshi_display=$(get_model_display_name "gunshi" 2>/dev/null || echo "Opus+T")
    tmux set-option -p -t "multiagent:agents.${p}" @model_name "$_gunshi_display" 2>/dev/null || true
    log_info "  └─ Gunshi (${_gunshi_display}) summoned"

    if [ "$KESSEN_MODE" = true ]; then
        log_success "✅ Deploying in Decisive Battle formation! All Opus!"
    else
        log_success "✅ Deploying in Normal formation (Karo=Sonnet, Ashigaru=Sonnet, Gunshi=Opus)"
    fi
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.5: Read instruction sheets to each agent
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "📜 Reading instruction sheets to each agent..."
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # NINJA WARRIOR (syntax-samurai/ryu - CC0 1.0 Public Domain)
    # ═══════════════════════════════════════════════════════════════════════════
    echo -e "\033[1;35m  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m  │\033[0m                            \033[1;37m[ NINJA WARRIOR ]\033[0m  Ryu Hayabusa (CC0 Public Domain)                        \033[1;35m│\033[0m"
    echo -e "\033[1;35m  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘\033[0m"

    cat << 'NINJA_EOF'
...................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒▒                         ...................................
..................................░░░░░░░░░░░░░░░░▒▒▒▒          ▒▒▒▒▒▒▒▒░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒                             ...................................
..................................░░░░░░░░░░░░░░▒▒▒▒               ▒▒▒▒▒░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                ...................................
..................................░░░░░░░░░░░░░▒▒▒                    ▒▒▒▒░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                    ...................................
..................................░░░░░░░░░░░░▒                            ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                                        ...................................
..................................░░░░░░░░░░░      ░░░░░░░░░░░░░                                      ░░░░░░░░░░░░       ▒          ...................................
..................................░░░░░░░░░░ ▒    ░░░▓▓▓▓▓▓▓▓▓▓▓▓░░                                 ░░░░░░░░░░░░░░░ ░               ...................................
..................................░░░░░░░░░░     ░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░                          ░░░░░░░░░░░░░░░░░░░                ...................................
..................................░░░░░░░░░ ▒  ░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░             ░░▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░  ░   ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░ ░  ▒         ...................................
..................................░░░░░░░░ ░  ░░░░░░░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░  ░    ▒        ...................................
..................................░░░░░░░░░▒  ░ ░               ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░▓▓▓▓▓▓▓▓▓▓▓░                 ░            ...................................
.................................░░░░░░░░░░   ░░░  ░                 ▓▓▓▓▓▓▓▓░▓▓▓▓░░░▓░░░░░░▓▓▓▓▓                    ░ ░   ▒         ..................................
.................................░░░░░░░░▒▒   ░░░░░ ░                  ▓▓▓▓▓▓░▓▓▓▓░░▓▓▓░░░░░░▓▓                    ░  ░ ░  ▒         ..................................
.................................░░░░░░░░▒    ░░░░░░░░░ ░                 ░▓░░▓▓▓▓▓░▓▓▓░░░░░                   ░ ░░ ░░ ░   ▒         ..................................
.................................░░░░░░░▒▒    ░░░░░░░   ░░                    ▓▓▓▓▓▓▓▓▓░░                   ░░    ░ ░░ ░    ▒        ..................................
.................................░░░░░░░▒▒    ░░░░░░░░░░                      ░▓▓▓▓▓▓▓░░░                     ░░░  ░  ░ ░   ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░                         ░░░▓▓▓░▓░░░░      ░                  ░ ░░ ░    ▒        ..................................
.................................░░░░░░░ ▒    ░░░░░░░     ▓▓        ▓  ░░ ░░░░░░░░░░░░░  ░   ░░  ▓        █▓       ░  ░ ░   ▒▒       ..................................
..................................░░░░░▒ ▒    ░░░░░░░░  ▓▓██  ▓  ██ ██▓  ▓ ░░░▓░  ░ ░ ░░░░  ▓   ██ ▓█  ▓  ██▓▓  ░░░░  ░ ░    ▒      ...................................
..................................░░░░░▒ ▒▒   ░░░░░░░░░  ▓██  ▓▓  ▓ ██▓  ▓░░░░▓▓░  ░░░░░░░░ ▓  ▓██ ▓   ▓  ██▓▓ ░░░░░░░ ░     ▒      ...................................
..................................░░░░░  ▒░   ░░░░░░░▓░░ ▓███  ▓▓▓▓ ███░  ░░░░▓▓░░░░░░░░░░    ░▓██  ▓▓▓  ███▓ ░░▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░  ▒░    ░░░░▓▓▓▓▓▓░  ███    ██      ░░░░░▓▓▓▓▓░░░░░░░     ███   ████ ░░▓▓▓▓░░  ░    ▒ ▒      ...................................
...................................░░░░ ▒ ░▒    ░░▓▓▓▓▓▓▓▓▓▓ ██████  ▓▓▓░░ ░░░░▓▓▓▓▓▓░░░░░░░░░▓▓▓   █████  ▓▓▓▓▓▓▓░░░░    ▒▒ ▒      ...................................
...................................░░░░ ░ ░░     ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓█░░░░░░░▓▓▓▓▓▓▓░░░░ ░░   ░░▓░▓▓░░░░░░░▓▓▓▓▓▓░░      ▒▒ ▒      ...................................
...................................░░░░ ░ ░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓██  ░░░░░░░▓▓▓▓▓▓▓░░░░  ░░░░░   ░░░░░░░░░▓▓▓▓▓░░ ░    ▒▒  ▒      ...................................
...................................░░░░▒░░▒░░      ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░▓▓▓▓▓▓▓▓░░░  ░░░░░░░░░░░░░░░░░░▓▓░░░░      ▒▒  ▒     ....................................
...................................░░░░▒░░ ░░       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░▓▓▓▓▓▓▓▓▓░░░░  ░░░░░░░░░░░░░░░░░░░░░        ▒▒  ▒     ....................................
...................................░░░░░░░ ▒░▒       ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░▓▓▓░░   ░░░░░  ░░░░░░░░░░░░░░░░░░░░         ▒   ▒     ....................................
...................................░░░░░░░░░░░           ░▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓              ░    ░░░░░░░░░░░░░░░            ▒   ▒     ....................................
....................................░░░░░░░░░░░▒  ▒▒        ▓▓▓▓▓▓▓▓▓▓▓▓▓  ░░░░░░░░░░▒▒                         ▒▒▒▒▒   ▒    ▒    .....................................
....................................░░░░░░░░░░ ░▒ ▒▒▒░░░        ▓▓▓▓▓▓   ░░░░░░░░░░░░░▒▒▒      ▒▒▒▒▒░░░░▒▒    ▒▒▒▒▒▒▒  ▒▒    ▒    .....................................
....................................░░░░░░░░░░ ░░░ ▒▒▒░░░░░░          ░░░░░ ░░░░░░░░░░▒░▒     ▒▒▒▒▒▒░░░░░░▒▒▒▒▒░▒▒▒▒   ▒▒         .....................................
.....................................░░░░░░░░░░ ░░░░░  ▒▒░░░░░░░░░░░░░    ░░░░░░░░░  ▒░▒▒    ▒▒▒▒▒░░░░▒▒▒▒▒▒░░▒▒▒   ▒▒▒         ......................................
.....................................░░░░░░░░░░░░░░░░░░  ▒░░░░░░░░░░░   ░░░░░░░░░░░░░░   ▒   ▒▒▒▒▒▒▒░▒▒▒▒▒▒░░░░▒▒▒   ▒▒          ......................................
.....................................░░░░░░░░░░░ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░      ▒▒▒▒▒▒▒    ▒  ░░░▒▒▒▒  ▒▒▒          ......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ ▒░▒▒▒ ▒▒▒    ▒░░░░░░░░░░▒   ▒▒▒▒      ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒  ░░▒▒▒▒▒▒░░░░░░░░░░░░░▒  ░▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒ ▒▒░▒▒▒▒▒▒▒░░░░░░░░░░  ░░▒▒▒▒▒       ▒   .......................................
......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒ ░▒▒▒▒▒▒▒▒▒░░▒░░░░░░ ░░▒▒▒▒▒▒      ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒░░▒░▒▒▒ ▒▒▒▒▒░░░░░░░░░▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒░▒▒▒▒▒     ░░░░░░░░▒▒▒▒▒▒        ▒    .......................................
.......................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒░░▒░▒▒▒▒▒▒  ▒░░░░░░░▒▒▒▒▒▒        ▒     .......................................
NINJA_EOF

    echo ""
    echo -e "                                    \033[1;35m\" Tenka Fubu! Seize victory! \"\033[0m"
    echo ""
    echo -e "                               \033[0;36m[ASCII Art: syntax-samurai/ryu - CC0 1.0 Public Domain]\033[0m"
    echo ""

    echo "  Waiting for agent CLI startup (max 30s)..."

    # Verify Shogun startup (wait max 30s)
    _shogun_ready_pattern=$(cli_ready_pattern "$_shogun_cli_type")
    for i in {1..30}; do
        if tmux capture-pane -t shogun:main -p | grep -qiE "$_shogun_ready_pattern"; then
            echo "  └─ Shogun CLI startup confirmed (${i}s, ${_shogun_cli_type})"
            break
        fi
        sleep 1
    done

    # ═══════════════════════════════════════════════════════════════════
    # STEP 6.6: Launch inbox_watcher (all agents)
    # ═══════════════════════════════════════════════════════════════════
    log_info "📬 Launching mailbox monitoring..."

    # Initialize inbox directory (create on the Linux FS mapped via symlink)
    mkdir -p "$SCRIPT_DIR/logs"
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        [ -f "$SCRIPT_DIR/queue/inbox/${agent}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    done

    # Kill existing watchers and orphaned inotifywait/fswatch
    pkill -f "inbox_watcher.sh" 2>/dev/null || true
    pkill -f "inotifywait.*queue/inbox" 2>/dev/null || true
    pkill -f "fswatch.*queue/inbox" 2>/dev/null || true
    sleep 1

    # Shogun's watcher (required for auto-wake-up on receiving ntfy)
    # Safety mode: phase2/phase3 escalations are disabled, timeout periodic processing is also disabled (event-driven only)
    _shogun_watcher_cli=$(tmux show-options -p -t "shogun:main" -v @agent_cli 2>/dev/null || echo "claude")
    nohup env ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0 \
        bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" shogun "shogun:main" "$_shogun_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_shogun.log" 2>&1 &
    disown

    # Karo's watcher
    _karo_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${PANE_BASE}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" karo "multiagent:agents.${PANE_BASE}" "$_karo_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_karo.log" 2>&1 &
    disown

    # Ashigaru's watcher
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        p=$((PANE_BASE + i))
        _ashi_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "ashigaru${i}" "multiagent:agents.${p}" "$_ashi_watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_ashigaru${i}.log" 2>&1 &
        disown
    done

    # Gunshi's watcher
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_watcher_cli=$(tmux show-options -p -t "multiagent:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "gunshi" "multiagent:agents.${p}" "$_gunshi_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_gunshi.log" 2>&1 &
    disown

    log_success "  └─ inbox_watcher started for $((_ASHIGARU_COUNT + 3)) agents (Shogun + Karo + Ashigaru ${_ASHIGARU_COUNT} + Gunshi)"

    # STEP 6.7 is obsolete — each agent autonomously reads its own instructions/*.md
    # via CLAUDE.md Session Start (step 1: tmux agent_id). Verified (2026-02-08).
    log_info "📜 Instructions loaded autonomously by each agent (CLAUDE.md Session Start)"
    echo ""
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.7.5: Archive old ntfy_inbox messages (older than 7 days and processed)
# ═══════════════════════════════════════════════════════════════════════════════
if [ -f ./queue/ntfy_inbox.yaml ]; then
    _archive_result=$(python3 -c "
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

# Append to archive
try:
    with open(ARCHIVE) as f:
        archive = yaml.safe_load(f) or {}
except FileNotFoundError:
    archive = {}
archive_entries = archive.get('inbox', []) or []
archive_entries.extend(old)
with open(ARCHIVE, 'w') as f:
    yaml.dump({'inbox': archive_entries}, f, allow_unicode=True, default_flow_style=False)

# Write back recent only
with open(INBOX, 'w') as f:
    yaml.dump({'inbox': recent}, f, allow_unicode=True, default_flow_style=False)

print(f'Archived {len(old)} entries, kept {len(recent)} entries')
" 2>/dev/null) || true
    if [ -n "$_archive_result" ]; then
        log_info "📱 Cleaned up ntfy_inbox: $_archive_result → ntfy_inbox_archive.yaml"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.8: Start Input Listener (Telegram / ntfy)
# ═══════════════════════════════════════════════════════════════════════════════
TELEGRAM_ENV="./config/telegram.env"
TELEGRAM_CONFIGURED=false

if [ -f "$TELEGRAM_ENV" ]; then
    # Simple check if token is filled
    if grep -q "TELEGRAM_BOT_TOKEN=" "$TELEGRAM_ENV" && ! grep -q "your_bot_token_here" "$TELEGRAM_ENV"; then
        TELEGRAM_CONFIGURED=true
    fi
fi

if [ "$TELEGRAM_CONFIGURED" = true ]; then
    pkill -f "telegram_listener.py" 2>/dev/null || true
    [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
    
    # Start Telegram Listener daemon in the background
    nohup "$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/scripts/telegram_listener.py" >> "$SCRIPT_DIR/logs/telegram_listener.log" 2>&1 &
    disown
    
    # Split shogun:main to create the telegram agent pane (takes 25% height)
    tmux split-window -v -p 25 -t shogun:main
    
    PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
    TELEGRAM_PANE="shogun:main.$((PANE_BASE + 1))"
    
    tmux select-pane -t "$TELEGRAM_PANE" -T "Telegram Agent"
    tmux set-option -p -t "$TELEGRAM_PANE" @agent_id "telegram"
    
    # Set CLI type and model display name dynamically from settings.yaml
    _telegram_cli_type=$(get_cli_type "telegram" 2>/dev/null || echo "claude")
    _telegram_display=$(get_model_display_name "telegram" 2>/dev/null || echo "Haiku")
    _telegram_cmd=$(build_cli_command "telegram" 2>/dev/null || echo "claude --model haiku $PERMISSION_FLAG")
    
    tmux set-option -p -t "$TELEGRAM_PANE" @agent_cli "$_telegram_cli_type"
    tmux set-option -p -t "$TELEGRAM_PANE" @model_name "$_telegram_display" 2>/dev/null || true
    
    # Summon the Telegram CLI Agent
    tmux send-keys -t "$TELEGRAM_PANE" "$_telegram_cmd" Enter
    
    # Launch inbox_watcher for the telegram agent
    [ -f "$SCRIPT_DIR/queue/inbox/telegram.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/telegram.yaml"
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" telegram "$TELEGRAM_PANE" "$_telegram_cli_type" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_telegram.log" 2>&1 &
    disown
    
    # Switch active pane back to Shogun main pane
    tmux select-pane -t "shogun:main.${PANE_BASE}"
    
    # Enable borders on shogun session so we see agent pane names clearly
    tmux set-option -t shogun -w pane-border-status top
    tmux set-option -t shogun -w pane-border-format '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] #{?@model_name,(#{@model_name}),}'
    
    log_info "📱 Started Telegram background listener and summoned Telegram agent (${_telegram_display}) in shogun:main pane $((PANE_BASE + 1))"
else
    NTFY_TOPIC=$(grep 'ntfy_topic:' ./config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [ -n "$NTFY_TOPIC" ]; then
        pkill -f "ntfy_listener.sh" 2>/dev/null || true
        [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
        nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
        disown
        log_info "📱 Started ntfy input listener (topic: $NTFY_TOPIC)"
    else
        log_info "📱 Listener skipped: Neither Telegram nor ntfy configured"
    fi
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6.9: MCP Health Check (verify MCP initialization state of Codex Ashigaru)
# ═══════════════════════════════════════════════════════════════════════════════
log_info ""
log_info "STEP 6.9: MCP Health Check..."
log_info "  └─ Waiting 10 seconds for all agents to start up..."
sleep 10
if bash "$SCRIPT_DIR/scripts/mcp_health_check.sh" 2>&1 | tee -a "$SCRIPT_DIR/logs/mcp_health.log"; then
    log_success "  └─ MCP Health Check: All normal"
else
    log_error "  └─ ⚠️ Detected MCP initialization failure. Check logs/mcp_health.log"
    log_error "     Recommended to restart the affected agent using 'bash scripts/switch_cli.sh <agent>'"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 7: Check Environment and Completion Message
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🔍 Confirming troop formation..."
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📺 Tmux Session Formations                              │"
echo "  └──────────────────────────────────────────────────────────┘"
tmux list-sessions | sed 's/^/     /'
echo ""
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  📋 Battle Formation Map                                 │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "     [shogun session] Shogun Main Camp"
echo "     ┌─────────────────────────────┐"
echo "     │  Pane 0: Shogun (SHOGUN)    │  ← Commander-in-Chief / Project Overseer"
echo "     └─────────────────────────────┘"
echo ""
echo "     [multiagent session] Karo, Ashigaru, and Gunshi Camp (3x3 = 9 panes)"
echo "     ┌─────────┬─────────┬─────────┐"
echo "     │  karo   │ashigaru3│ashigaru6│"
echo "     │ (Karo)  │(Ashigaru3)│(Ashigaru6)│"
echo "     ├─────────┼─────────┼─────────┤"
echo "     │ashigaru1│ashigaru4│ashigaru7│"
echo "     │(Ashigaru1)│(Ashigaru4)│(Ashigaru7)│"
echo "     ├─────────┼─────────┼─────────┤"
echo "     │ashigaru2│ashigaru5│ gunshi  │"
echo "     │(Ashigaru2)│(Ashigaru5)│ (Gunshi) │"
echo "     └─────────┴─────────┴─────────┘"
echo ""

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  🏯 DEPARTURE PREPARATIONS COMPLETE! TENKA FUBU!         ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

if [ "$SETUP_ONLY" = true ]; then
    echo "  ⚠️  Setup-only mode: Claude Code has not been launched"
    echo ""
    echo "  To launch Claude Code manually:"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  # Summon the Shogun                                     │"
    echo "  │  tmux send-keys -t shogun:main \\                         │"
    echo "  │    'claude ${PERMISSION_FLAG}' Enter         │"
    echo "  │                                                          │"
    echo "  │  # Summon Karo & Ashigaru all at once                    │"
    echo "  │  for p in \$(seq $PANE_BASE $((PANE_BASE+8))); do                                 │"
    echo "  │      tmux send-keys -t multiagent:agents.\$p \\            │"
    echo "  │      'claude ${PERMISSION_FLAG}' Enter       │"
    echo "  │  done                                                    │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
fi

echo "  Next steps:"
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  Attach to Shogun's main camp to start commanding:       │"
echo "  │     tmux attach-session -t shogun   (or: css)            │"
echo "  │                                                          │"
echo "  │  Check the Karo and Ashigaru camp:                       │"
echo "  │     tmux attach-session -t multiagent   (or: csm)        │"
echo "  │                                                          │"
echo "  │  * Each agent has already loaded their instructions.    │"
echo "  │    You can start commanding immediately.                 │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
echo "  ════════════════════════════════════════════════════════════"
echo "   Tenka Fubu! Seize victory!"
echo "  ════════════════════════════════════════════════════════════"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: Launching tabs in Windows Terminal (only when -t option is set)
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$OPEN_TERMINAL" = true ]; then
    log_info "📺 Launching tabs in Windows Terminal..."

    # Check if Windows Terminal is available
    if command -v wt.exe &> /dev/null; then
        wt.exe -w 0 new-tab wsl.exe -e bash -c "tmux attach-session -t shogun" \; new-tab wsl.exe -e bash -c "tmux attach-session -t multiagent"
        log_success "  └─ Terminal tabs successfully launched"
    else
        log_info "  └─ wt.exe not found. Please attach manually."
    fi
    echo ""
fi

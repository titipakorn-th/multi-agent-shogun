#!/usr/bin/env bash
# ============================================================
# first_setup.sh - multi-agent-shogun Initial Setup Script
# Environment construction tool for Ubuntu / WSL / Mac
# ============================================================
# Run method:
#   chmod +x first_setup.sh
#   ./first_setup.sh
# ============================================================

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Logging functions with icons
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}\n"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Variables for result tracking
RESULTS=()
HAS_ERROR=false

echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  🏯 multi-agent-shogun Installer                              ║"
echo "  ║     Initial Setup Script for Ubuntu / WSL                    ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  This script is for the initial setup."
echo "  It verifies dependencies and creates the directory structure."
echo ""
echo "  Installation destination: $SCRIPT_DIR"
echo ""

# ============================================================
# STEP 1: OS Check
# ============================================================
log_step "STEP 1: System Environment Check"

# Get OS information
UNAME_S="$(uname -s)"
if [ "$UNAME_S" = "Darwin" ]; then
    OS_NAME="macOS"
    OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
    log_info "OS: $OS_NAME $OS_VERSION"
elif [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME=$NAME
    OS_VERSION=$VERSION_ID
    log_info "OS: $OS_NAME $OS_VERSION"
else
    OS_NAME="Unknown"
    log_warn "Failed to retrieve OS information"
fi

# WSL Check
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
    log_info "Environment: WSL (Windows Subsystem for Linux)"
    IS_WSL=true
elif [ "$UNAME_S" = "Darwin" ]; then
    log_info "Environment: macOS"
else
    log_info "Environment: Native Linux"
fi

RESULTS+=("System environment: OK")

# ============================================================
# STEP 2: Checking and Installing tmux
# ============================================================
log_step "STEP 2: Checking tmux"

if command -v tmux &> /dev/null; then
    TMUX_VERSION=$(tmux -V | awk '{print $2}')
    log_success "tmux is already installed (v$TMUX_VERSION)"
    RESULTS+=("tmux: OK (v$TMUX_VERSION)")
else
    log_warn "tmux is not installed"
    echo ""

    # Check if Ubuntu/Debian family
    if command -v apt-get &> /dev/null; then
        log_info "Installing tmux..."
        if ! sudo -n apt-get update -qq 2>/dev/null; then
            if ! sudo apt-get update -qq 2>/dev/null; then
                log_error "sudo execution failed. Please run it directly from the terminal"
                RESULTS+=("tmux: installation failed (sudo failed)")
                HAS_ERROR=true
            fi
        fi

        if [ "$HAS_ERROR" != true ]; then
            if ! sudo -n apt-get install -y tmux 2>/dev/null; then
                if ! sudo apt-get install -y tmux 2>/dev/null; then
                    log_error "Failed to install tmux"
                    RESULTS+=("tmux: installation failed")
                    HAS_ERROR=true
                fi
            fi
        fi

        if command -v tmux &> /dev/null; then
            TMUX_VERSION=$(tmux -V | awk '{print $2}')
            log_success "tmux installation complete (v$TMUX_VERSION)"
            RESULTS+=("tmux: installation complete (v$TMUX_VERSION)")
        else
            log_error "Failed to install tmux"
            RESULTS+=("tmux: installation failed")
            HAS_ERROR=true
        fi
    else
        log_error "apt-get not found. Please install tmux manually"
        echo ""
        echo "  How to install:"
        echo "    Ubuntu/Debian: sudo apt-get install tmux"
        echo "    Fedora:        sudo dnf install tmux"
        echo "    macOS:         brew install tmux"
        RESULTS+=("tmux: not installed (manual installation required)")
        HAS_ERROR=true
    fi
fi

# ============================================================
# STEP 3: tmux Mouse Scroll Setting
# ============================================================
log_step "STEP 3: tmux Mouse Scroll Setting"

TMUX_CONF="$HOME/.tmux.conf"
TMUX_MOUSE_SETTING="set -g mouse on"

if [ -f "$TMUX_CONF" ] && grep -qF "$TMUX_MOUSE_SETTING" "$TMUX_CONF" 2>/dev/null; then
    log_info "tmux mouse setting already exists in ~/.tmux.conf"
else
    log_info "Adding '$TMUX_MOUSE_SETTING' to ~/.tmux.conf..."
    echo "" >> "$TMUX_CONF"
    echo "# Enable mouse scroll (added by first_setup.sh)" >> "$TMUX_CONF"
    echo "$TMUX_MOUSE_SETTING" >> "$TMUX_CONF"
    log_success "Added tmux mouse setting"
fi

# Apply immediately if tmux is running
if command -v tmux &> /dev/null && tmux list-sessions &> /dev/null; then
    log_info "tmux is running, applying settings immediately..."
    if tmux source-file "$TMUX_CONF" 2>/dev/null; then
        log_success "Reloaded tmux configuration"
    else
        log_warn "Failed to reload tmux configuration (please run 'tmux source-file ~/.tmux.conf' manually)"
    fi
else
    log_info "tmux is not running, settings will be applied on next startup"
fi

RESULTS+=("tmux mouse setting: OK")

# ============================================================
# STEP 4: Checking Node.js
# ============================================================
log_step "STEP 4: Checking Node.js"

if command -v node &> /dev/null; then
    NODE_VERSION=$(node -v)
    log_success "Node.js is already installed ($NODE_VERSION)"

    # Version check (v18+ recommended)
    NODE_MAJOR=$(echo $NODE_VERSION | cut -d'.' -f1 | tr -d 'v')
    if [ "$NODE_MAJOR" -lt 18 ]; then
        log_warn "Node.js 18+ is recommended (Current: $NODE_VERSION)"
        RESULTS+=("Node.js: OK (v$NODE_MAJOR - Upgrade recommended)")
    else
        RESULTS+=("Node.js: OK ($NODE_VERSION)")
    fi
else
    log_warn "Node.js is not installed"
    echo ""

    # Check if nvm is already installed
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        log_info "nvm is already installed. Setting up Node.js..."
        \. "$NVM_DIR/nvm.sh"
    else
        # Automatic installation of nvm
        log_info "Installing nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    fi

    # Install Node.js if nvm is available
    if command -v nvm &> /dev/null; then
        log_info "Installing Node.js 20..."
        nvm install 20 || true
        nvm use 20 || true

        if command -v node &> /dev/null; then
            NODE_VERSION=$(node -v)
            log_success "Node.js installation complete ($NODE_VERSION)"
            RESULTS+=("Node.js: Installation complete ($NODE_VERSION)")
        else
            log_error "Failed to install Node.js"
            RESULTS+=("Node.js: Installation failed")
            HAS_ERROR=true
        fi
    elif [ "$HAS_ERROR" != true ]; then
        log_error "Failed to install nvm"
        echo ""
        echo "  Please install manually:"
        echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
        echo "    source ~/.bashrc"
        echo "    nvm install 20"
        echo ""
        RESULTS+=("Node.js: Not installed (nvm failed)")
        HAS_ERROR=true
    fi
fi

# npm Check
if command -v npm &> /dev/null; then
    NPM_VERSION=$(npm -v)
    log_success "npm is already installed (v$NPM_VERSION)"
else
    if command -v node &> /dev/null; then
        log_warn "npm not found (it should be installed with Node.js)"
    fi
fi

# ============================================================
# STEP 4.5: Checking Python3 / venv / flock / file-watcher
# ============================================================
log_step "STEP 4.5: Checking Python3 / venv / flock / file-watcher"

# Detect OS
SETUP_OS="$(uname -s)"

# --- python3 ---
if command -v python3 &> /dev/null; then
    PY3_VERSION=$(python3 --version 2>&1)
    log_success "python3 is already installed ($PY3_VERSION)"
    RESULTS+=("python3: OK ($PY3_VERSION)")
else
    log_warn "python3 is not installed"
    if command -v apt-get &> /dev/null; then
        log_info "Installing python3..."
        sudo apt-get update -qq 2>/dev/null
        if sudo apt-get install -y python3 2>/dev/null; then
            PY3_VERSION=$(python3 --version 2>&1)
            log_success "python3 installation complete ($PY3_VERSION)"
            RESULTS+=("python3: Installation complete ($PY3_VERSION)")
        else
            log_error "Failed to install python3"
            RESULTS+=("python3: Installation failed")
            HAS_ERROR=true
        fi
    elif [ "$SETUP_OS" = "Darwin" ]; then
        log_error "python3 is not installed"
        echo "  macOS: Install via 'brew install python3' or download from https://www.python.org/"
        RESULTS+=("python3: Not installed (Manual installation required)")
        HAS_ERROR=true
    else
        log_error "Please install python3 manually"
        RESULTS+=("python3: Not installed (Manual installation required)")
        HAS_ERROR=true
    fi
fi

# --- Python venv + PyYAML (via requirements.txt) ---
VENV_DIR="$SCRIPT_DIR/.venv"
if [ -f "$VENV_DIR/bin/python3" ] && "$VENV_DIR/bin/python3" -c "import yaml" 2>/dev/null; then
    log_success "Python venv + PyYAML is already set up"
    RESULTS+=("venv + PyYAML: OK")
else
    log_info "Setting up Python venv..."
    if command -v python3 &> /dev/null; then
        VENV_CREATED=false
        if python3 -m venv "$VENV_DIR" 2>/dev/null; then
            VENV_CREATED=true
        else
            # Try installing python3-venv via apt-get only if sudo works non-interactively
            if command -v apt-get &> /dev/null; then
                log_info "Attempting to install python3-venv..."
                if sudo -n apt-get update -qq 2>/dev/null && sudo -n apt-get install -y python3-venv 2>/dev/null; then
                    if python3 -m venv "$VENV_DIR" 2>/dev/null; then
                        VENV_CREATED=true
                    fi
                fi
            fi
        fi

        if [ "$VENV_CREATED" = true ]; then
            log_success "venv creation complete: $VENV_DIR"
            if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
                if "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" 2>/dev/null; then
                    log_success "PyYAML installation complete (venv)"
                    RESULTS+=("venv + PyYAML: Setup complete")
                else
                    log_error "pip install failed"
                    RESULTS+=("venv + PyYAML: pip failed")
                    HAS_ERROR=true
                fi
            else
                log_warn "requirements.txt not found"
                RESULTS+=("venv + PyYAML: requirements.txt missing")
                HAS_ERROR=true
            fi
        else
            log_error "python3 -m venv failed"
            echo "  The python3-venv package might be required:"
            echo "    Ubuntu/Debian: sudo apt-get install python3-venv"
            RESULTS+=("venv: Creation failed")
            HAS_ERROR=true
        fi
    else
        log_error "python3 is required (please install it in the step above)"
        RESULTS+=("venv: Skipped due to python3 missing")
        HAS_ERROR=true
    fi
fi

# --- flock ---
if command -v flock &> /dev/null; then
    log_success "flock is already installed"
    RESULTS+=("flock: OK")
else
    log_warn "flock is not installed"
    if [ "$SETUP_OS" = "Darwin" ]; then
        echo "  macOS: brew install flock"
        RESULTS+=("flock: Not installed (brew install flock)")
    elif command -v apt-get &> /dev/null; then
        log_info "util-linux (including flock) is normally pre-installed"
        echo "  sudo apt-get install util-linux"
        RESULTS+=("flock: Not installed (apt-get install util-linux)")
    else
        echo "  Please install manually"
        RESULTS+=("flock: Not installed")
    fi
    HAS_ERROR=true
fi

# --- Bash version check (macOS ships with bash 3.2) ---
if [ "$SETUP_OS" = "Darwin" ]; then
    if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
        log_warn "bash 3.2 detected (macOS default)."
        log_warn "This tool requires bash 4.0+."
        log_warn "Install: brew install bash"
        log_warn "Then reopen terminal and retry."
        HAS_ERROR=true
    else
        log_success "bash ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]} detected"
    fi
fi

# --- coreutils (recommended for macOS) ---
if [ "$SETUP_OS" = "Darwin" ]; then
    if ! command -v gtimeout &>/dev/null; then
        log_warn "GNU coreutils not found. inbox_watcher will use bash fallback for timeout."
        log_warn "Recommended: brew install coreutils"
        RESULTS+=("coreutils: Not installed (brew install coreutils)")
    else
        log_success "GNU coreutils detected (gtimeout available)"
    fi
fi

# --- File watcher (inotifywait / fswatch) ---
if [ "$SETUP_OS" = "Darwin" ]; then
    # macOS: fswatch
    if command -v fswatch &> /dev/null; then
        log_success "fswatch is already installed (macOS file watcher)"
        RESULTS+=("file-watcher: OK (fswatch)")
    else
        log_warn "fswatch is not installed"
        echo "  macOS: brew install fswatch"
        RESULTS+=("file-watcher: Not installed (brew install fswatch)")
        HAS_ERROR=true
    fi
else
    # Linux: inotifywait
    if command -v inotifywait &> /dev/null; then
        log_success "inotify-tools is already installed"
        RESULTS+=("file-watcher: OK (inotifywait)")
    else
        log_warn "inotify-tools is not installed"
        if command -v apt-get &> /dev/null; then
            log_info "Installing inotify-tools..."
            if sudo apt-get install -y inotify-tools 2>/dev/null; then
                log_success "inotify-tools installation complete"
                RESULTS+=("file-watcher: Installation complete (inotifywait)")
            else
                log_error "Failed to install inotify-tools"
                RESULTS+=("file-watcher: Installation failed")
                HAS_ERROR=true
            fi
        else
            log_error "Please install inotify-tools manually"
            RESULTS+=("file-watcher: Not installed")
            HAS_ERROR=true
        fi
    fi
fi

# ============================================================
# STEP 5: Claude Code CLI Check (Native Version)
# * The npm version is deprecated. Use the native version.
#    Node.js is still required for MCP servers (via npx).
# ============================================================
log_step "STEP 5: Checking Claude Code CLI"

# Include ~/.local/bin in PATH to detect existing native installations
export PATH="$HOME/.local/bin:$PATH"

NEED_CLAUDE_INSTALL=false
HAS_NPM_CLAUDE=false

if command -v claude &> /dev/null; then
    # claude command exists -> check if it actually runs
    CLAUDE_VERSION=$(claude --version 2>&1)
    CLAUDE_PATH=$(which claude 2>/dev/null)

    if [ $? -eq 0 ] && [ "$CLAUDE_VERSION" != "unknown" ] && [[ "$CLAUDE_VERSION" != *"not found"* ]]; then
        # Found working claude -> determine if it is npm or native version
        if echo "$CLAUDE_PATH" | grep -qi "npm\|node_modules\|AppData"; then
            # npm version is running
            HAS_NPM_CLAUDE=true
            log_warn "npm version of Claude Code CLI detected (Officially deprecated)"
            log_info "Detected path: $CLAUDE_PATH"
            log_info "Version: $CLAUDE_VERSION"
            echo ""
            echo "  The npm version is officially deprecated."
            echo "  We recommend installing the native version and uninstalling the npm version."
            echo ""
            if [ ! -t 0 ]; then
                REPLY="Y"
            else
                read -p "  Do you want to install the native version? [Y/n]: " REPLY
            fi
            REPLY=${REPLY:-Y}
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                NEED_CLAUDE_INSTALL=true
                # Guidance for uninstalling npm version
                echo ""
                log_info "Please uninstall the npm version first:"
                if echo "$CLAUDE_PATH" | grep -qi "mnt/c\|AppData"; then
                    echo "  In Windows PowerShell:"
                    echo "    npm uninstall -g @anthropic-ai/claude-code"
                else
                    echo "    npm uninstall -g @anthropic-ai/claude-code"
                fi
                echo ""
            else
                log_warn "Skipped migration to native version (continuing with npm version)"
                RESULTS+=("Claude Code CLI: OK (npm version - migration recommended)")
            fi
        else
            # Native version is working fine
            log_success "Claude Code CLI is already installed (native version)"
            log_info "Version: $CLAUDE_VERSION"
            RESULTS+=("Claude Code CLI: OK")
        fi
    else
        # Found via command -v but not working (e.g. npm version without Node.js)
        log_warn "Claude Code CLI was found but does not function properly"
        log_info "Detected path: $CLAUDE_PATH"
        if echo "$CLAUDE_PATH" | grep -qi "npm\|node_modules\|AppData"; then
            HAS_NPM_CLAUDE=true
            log_info "→ npm version (Node.js dependent) was detected"
        else
            log_info "→ Failed to retrieve version"
        fi
        NEED_CLAUDE_INSTALL=true
    fi
else
    # claude command not found
    NEED_CLAUDE_INSTALL=true
fi

if [ "$NEED_CLAUDE_INSTALL" = true ]; then
    log_info "Installing the native version of Claude Code CLI"
    log_info "Installing Claude Code CLI (native version)..."
    curl -fsSL https://claude.ai/install.sh | bash

    # Update PATH (may not be reflected immediately after installation)
    export PATH="$HOME/.local/bin:$PATH"

    # Persist in ~/.bashrc (prevent duplicate additions)
    if ! grep -q 'export PATH="\$HOME/.local/bin:\$PATH"' "$HOME/.bashrc" 2>/dev/null; then
        echo '' >> "$HOME/.bashrc"
        echo '# Claude Code CLI PATH (added by first_setup.sh)' >> "$HOME/.bashrc"
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
        log_info "Added ~/.local/bin to PATH in ~/.bashrc"
    fi

    if command -v claude &> /dev/null; then
        CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown")
        log_success "Claude Code CLI installation complete (native version)"
        log_info "Version: $CLAUDE_VERSION"
        RESULTS+=("Claude Code CLI: Installation complete")

        # Guidance when npm version remains
        if [ "$HAS_NPM_CLAUDE" = true ]; then
            echo ""
            log_info "Since the native version takes precedence in PATH, the npm version will be deactivated"
            log_info "To completely remove the npm version, run the following:"
            if echo "$CLAUDE_PATH" | grep -qi "mnt/c\|AppData"; then
                echo "  In Windows PowerShell:"
                echo "    npm uninstall -g @anthropic-ai/claude-code"
            else
                echo "    npm uninstall -g @anthropic-ai/claude-code"
            fi
        fi
    else
        log_error "Installation failed. Please check your path"
        log_info "Please check if ~/.local/bin is included in your PATH"
        RESULTS+=("Claude Code CLI: Installation failed")
        HAS_ERROR=true
    fi
fi

# ============================================================
# STEP 6: Create Directory Structure
# ============================================================
log_step "STEP 6: Create Directory Structure"

# List of required directories
DIRECTORIES=(
    "queue/tasks"
    "queue/reports"
    "config"
    "status"
    "instructions"
    "logs"
    "demo_output"
    "skills"
    "memory"
)

CREATED_COUNT=0
EXISTED_COUNT=0

for dir in "${DIRECTORIES[@]}"; do
    if [ ! -d "$SCRIPT_DIR/$dir" ]; then
        mkdir -p "$SCRIPT_DIR/$dir"
        log_info "Created: $dir/"
        CREATED_COUNT=$((CREATED_COUNT + 1))
    else
        EXISTED_COUNT=$((EXISTED_COUNT + 1))
    fi
done

if [ $CREATED_COUNT -gt 0 ]; then
    log_success "Created $CREATED_COUNT directories"
fi
if [ $EXISTED_COUNT -gt 0 ]; then
    log_info "$EXISTED_COUNT directories already exist"
fi

RESULTS+=("Directory structure: OK (Created:$CREATED_COUNT, Existing:$EXISTED_COUNT)")

# ============================================================
# STEP 6.5: Install OSS Skills
# ============================================================
log_step "STEP 6.5: Install OSS Skills"

CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$CLAUDE_SKILLS_DIR"

INSTALLED_SKILLS=0
SKIPPED_SKILLS=0
FOUND_SKILLS=0

shopt -s nullglob
for skill_dir in "$SCRIPT_DIR/skills"/*/; do
    [ -d "$skill_dir" ] || continue

    FOUND_SKILLS=$((FOUND_SKILLS + 1))
    skill_name=$(basename "$skill_dir")
    target="$CLAUDE_SKILLS_DIR/$skill_name"

    if [ -d "$target" ]; then
        log_info "Skill $skill_name already exists (Skipped)"
        SKIPPED_SKILLS=$((SKIPPED_SKILLS + 1))
    else
        cp -r "$skill_dir" "$target"
        log_success "Installed skill: $skill_name"
        INSTALLED_SKILLS=$((INSTALLED_SKILLS + 1))
    fi
done
shopt -u nullglob

if [ "$FOUND_SKILLS" -eq 0 ]; then
    log_warn "No installable skills found"
    RESULTS+=("OSS Skills: Skipped (skills/ not detected)")
else
    log_info "Skills such as /shogun-model-switch are now available"
    RESULTS+=("OSS Skills: OK (New:$INSTALLED_SKILLS, Existing:$SKIPPED_SKILLS)")
fi

# ============================================================
# STEP 7: Configuration Files Verification
# ============================================================
log_step "STEP 7: Configuration Files Verification"

# config/settings.yaml
if [ ! -f "$SCRIPT_DIR/config/settings.yaml" ]; then
    log_info "Creating config/settings.yaml..."
    cat > "$SCRIPT_DIR/config/settings.yaml" << EOF
# multi-agent-shogun configuration file

# Language settings
# ja: Japanese (Sengoku-style Japanese only, no translations)
# en: English (Sengoku-style Japanese + English translations)
# Other language codes (es, zh, ko, fr, de, etc.) are also supported
language: ja

# Shell settings
# bash: Prompt for bash (default)
# zsh: Prompt for zsh
shell: bash

# Skill settings
skill:
  # Skill save path (saves with 'shogun-' prefix)
  save_path: "~/.claude/skills/"

  # Local skill save path (project specific)
  local_path: "$SCRIPT_DIR/skills/"

# Logging settings
logging:
  level: info  # debug | info | warn | error
  path: "$SCRIPT_DIR/logs/"

# CLI settings
cli:
  default: claude
  agents:
    telegram:
      type: claude
      model: haiku
EOF
    log_success "Created settings.yaml"
else
    log_info "config/settings.yaml already exists"
fi

# config/projects.yaml
if [ ! -f "$SCRIPT_DIR/config/projects.yaml" ]; then
    log_info "Creating config/projects.yaml..."
    cat > "$SCRIPT_DIR/config/projects.yaml" << 'EOF'
projects:
  - id: sample_project
    name: "Sample Project"
    path: "/path/to/your/project"
    priority: high
    status: active

current_project: sample_project
EOF
    log_success "Created projects.yaml"
else
    log_info "config/projects.yaml already exists"
fi

# memory/MEMORY.md (Shogun Persistent Memory - do not overwrite existing file)
if [ ! -f "$SCRIPT_DIR/memory/MEMORY.md" ]; then
    log_info "Creating memory/MEMORY.md..."
    cp "$SCRIPT_DIR/memory/MEMORY.md.sample" "$SCRIPT_DIR/memory/MEMORY.md"
    log_success "Created memory/MEMORY.md (copied from MEMORY.md.sample)"
    log_info "Please edit memory/MEMORY.md to fill in your information"
else
    log_info "memory/MEMORY.md already exists (Skipped)"
fi

# memory/global_context.md (System-wide Context)
if [ ! -f "$SCRIPT_DIR/memory/global_context.md" ]; then
    log_info "Creating memory/global_context.md..."
    cat > "$SCRIPT_DIR/memory/global_context.md" << 'EOF'
# Global Context
Last Updated: (Not Set)

## System Policy
- (Describe the Lord's preferences/policies here)

## Cross-project Decisions
- (Describe decisions affecting multiple projects here)

## Precautions
- (Describe precautions all agents should know here)
EOF
    log_success "Created global_context.md"
else
    log_info "memory/global_context.md already exists"
fi

RESULTS+=("Configuration files: OK")

# ============================================================
# STEP 8: Initialize Specialist Task/Report Files (v2)
# ============================================================
log_step "STEP 8: Initialize Queue Files"

# Read the v2 task-eligible roles from settings.yaml (the 7 specialists).
# Falls back to the canonical 7 if settings.yaml is absent or malformed.
_SETUP_VENV_PYTHON="$SCRIPT_DIR/.venv/bin/python3"
_SETUP_SPECIALIST_ROLES=$(
    if [[ -x "$_SETUP_VENV_PYTHON" ]]; then
        "$_SETUP_VENV_PYTHON" -c "
import yaml
try:
    with open('$SCRIPT_DIR/config/settings.yaml') as f:
        cfg = yaml.safe_load(f) or {}
    roles = cfg.get('roles', {})
    task_eligible = ['explorer', 'librarian', 'oracle', 'designer', 'fixer', 'observer', 'council']
    found = [r for r in task_eligible if r in roles]
    print(' '.join(found) if found else ' '.join(task_eligible))
except Exception:
    print('explorer librarian oracle designer fixer observer council')
" 2>/dev/null
    else
        echo "explorer librarian oracle designer fixer observer council"
    fi
)
_SETUP_SPECIALIST_ROLES=${_SETUP_SPECIALIST_ROLES:-"explorer librarian oracle designer fixer observer council"}

# Create specialist task files
for role in $_SETUP_SPECIALIST_ROLES; do
    TASK_FILE="$SCRIPT_DIR/queue/tasks/${role}.yaml"
    if [ ! -f "$TASK_FILE" ]; then
        cat > "$TASK_FILE" << EOF
# ${role} Dedicated Task File
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
    fi
done
log_info "Verified/Created specialist task files (${_SETUP_SPECIALIST_ROLES})"

# Create specialist report files
for role in $_SETUP_SPECIALIST_ROLES; do
    REPORT_FILE="$SCRIPT_DIR/queue/reports/${role}_report.yaml"
    if [ ! -f "$REPORT_FILE" ]; then
        cat > "$REPORT_FILE" << EOF
worker_id: ${role}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    fi
done
log_info "Verified/Created specialist report files (${_SETUP_SPECIALIST_ROLES})"

RESULTS+=("Queue files: OK")

# ============================================================
# STEP 9: Grant execution permissions to scripts
# ============================================================
log_step "STEP 9: Set Execution Permissions"

SCRIPTS=(
    "setup.sh"
    "first_setup.sh"
)

TARGETS=()

for script in "${SCRIPTS[@]}"; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        TARGETS+=("$SCRIPT_DIR/$script")
    fi
done

if [ "${#TARGETS[@]}" -ne 0 ]; then
    chmod +x "${TARGETS[@]}"

    for target in "${TARGETS[@]}"; do
        log_info "Granted execution permission to $(basename "$target")"
    done
fi

RESULTS+=("Execution permissions: OK")

# ============================================================
# STEP 10: Set bashrc aliases
# ============================================================
log_step "STEP 10: Set bashrc aliases"

# Target file for adding aliases
BASHRC_FILE="$HOME/.bashrc"

# Define css/csm as functions (auto-cleanup via destroy-unattached)
# - Screen sizes do not interfere even when connecting from multiple terminals
# - Temporary session automatically disappears on SSH disconnect or app closure
# - Main sessions (shogun/multiagent) will never disappear
CSS_FUNC='css() { local s="shogun-$$"; local cols=$(tput cols 2>/dev/null || echo 80); tmux new-session -d -t shogun -s "$s" 2>/dev/null && tmux set-option -t "$s" destroy-unattached on 2>/dev/null; if [ "$cols" -lt 80 ]; then tmux new-window -t "$s" -n mobile 2>/dev/null; tmux attach-session -t "$s:mobile" 2>/dev/null || tmux attach-session -t shogun; else tmux attach-session -t "$s" 2>/dev/null || tmux attach-session -t shogun; fi; }'
CSM_FUNC='csm() { local s="multi-$$"; local cols=$(tput cols 2>/dev/null || echo 80); tmux new-session -d -t multiagent -s "$s" 2>/dev/null && tmux set-option -t "$s" destroy-unattached on 2>/dev/null; if [ "$cols" -lt 80 ]; then tmux new-window -t "$s" -n mobile 2>/dev/null; tmux attach-session -t "$s:mobile" 2>/dev/null || tmux attach-session -t multiagent; else tmux attach-session -t "$s" 2>/dev/null || tmux attach-session -t multiagent; fi; }'
DASH_FUNC="dash() { python3 \"$SCRIPT_DIR/scripts/dashboard-viewer.py\" \"\$@\"; }"

ALIAS_ADDED=false

if [ -f "$BASHRC_FILE" ]; then
    # Remove old alias format (if exists)
    if grep -q "alias css=" "$BASHRC_FILE" 2>/dev/null; then
        sed -i '/alias css=/d' "$BASHRC_FILE"
        log_info "Removed old css alias"
    fi
    if grep -q "alias csm=" "$BASHRC_FILE" 2>/dev/null; then
        sed -i '/alias csm=/d' "$BASHRC_FILE"
        log_info "Removed old csm alias"
    fi

    # css function
    if ! grep -q "^css()" "$BASHRC_FILE" 2>/dev/null; then
        if ! grep -q "multi-agent-shogun aliases" "$BASHRC_FILE" 2>/dev/null; then
            echo "" >> "$BASHRC_FILE"
            echo "# multi-agent-shogun aliases (added by first_setup.sh)" >> "$BASHRC_FILE"
        fi
        echo "$CSS_FUNC" >> "$BASHRC_FILE"
        log_info "Added css function (Shogun window — with auto-cleanup)"
        ALIAS_ADDED=true
    else
        # Function exists -> update to latest version
        sed -i '/^css()/d' "$BASHRC_FILE"
        echo "$CSS_FUNC" >> "$BASHRC_FILE"
        log_info "Updated css function"
        ALIAS_ADDED=true
    fi

    # csm function
    if ! grep -q "^csm()" "$BASHRC_FILE" 2>/dev/null; then
        echo "$CSM_FUNC" >> "$BASHRC_FILE"
        log_info "Added csm function (Karo/Ashigaru window — with auto-cleanup)"
        ALIAS_ADDED=true
    else
        sed -i '/^csm()/d' "$BASHRC_FILE"
        echo "$CSM_FUNC" >> "$BASHRC_FILE"
        log_info "Updated csm function"
        ALIAS_ADDED=true
    fi

    # dash function
    if ! grep -q "^dash()" "$BASHRC_FILE" 2>/dev/null; then
        echo "$DASH_FUNC" >> "$BASHRC_FILE"
        log_info "Added dash function (Dashboard viewer)"
        ALIAS_ADDED=true
    else
        sed -i '/^dash()/d' "$BASHRC_FILE"
        echo "$DASH_FUNC" >> "$BASHRC_FILE"
        log_info "Updated dash function"
        ALIAS_ADDED=true
    fi
else
    log_warn "$BASHRC_FILE not found"
fi

if [ "$ALIAS_ADDED" = true ]; then
    log_success "Added alias configurations (destroy-unattached style)"
    log_warn "To apply the aliases, please perform one of the following:"
    log_info "  1. source ~/.bashrc"
    log_info "  2. Run 'wsl --shutdown' in PowerShell, then reopen the terminal"
    log_info "  * Simply closing the window will not stop WSL, so changes will not be reflected."
fi

RESULTS+=("Alias configuration: OK")

# ============================================================
# STEP 10.5: WSL Memory Optimization Settings
# ============================================================
if [ "$IS_WSL" = true ]; then
    log_step "STEP 10.5: WSL Memory Optimization Settings"

    # Check/Set .wslconfig (Placed in the Windows user directory)
    WIN_USER_DIR=$(cmd.exe /C "echo %USERPROFILE%" 2>/dev/null | tr -d '\r')
    if [ -n "$WIN_USER_DIR" ]; then
        # Convert Windows path to WSL path
        WSLCONFIG_PATH=$(wslpath "$WIN_USER_DIR")/.wslconfig

        if [ -f "$WSLCONFIG_PATH" ]; then
            if grep -q "autoMemoryReclaim" "$WSLCONFIG_PATH" 2>/dev/null; then
                log_info "autoMemoryReclaim is already configured in .wslconfig"
            else
                log_info "Adding autoMemoryReclaim=gradual to .wslconfig..."
                # Check if [experimental] section exists
                if grep -q "\[experimental\]" "$WSLCONFIG_PATH" 2>/dev/null; then
                    # Add immediately after [experimental] section
                    sed -i '/\[experimental\]/a autoMemoryReclaim=gradual' "$WSLCONFIG_PATH"
                else
                    echo "" >> "$WSLCONFIG_PATH"
                    echo "[experimental]" >> "$WSLCONFIG_PATH"
                    echo "autoMemoryReclaim=gradual" >> "$WSLCONFIG_PATH"
                fi
                log_success "Added autoMemoryReclaim=gradual to .wslconfig"
                log_warn "Requires restart after 'wsl --shutdown' to take effect"
            fi
        else
            log_info "Creating new .wslconfig..."
            cat > "$WSLCONFIG_PATH" << 'EOF'
[experimental]
autoMemoryReclaim=gradual
EOF
            log_success "Created .wslconfig (autoMemoryReclaim=gradual)"
            log_warn "Requires restart after 'wsl --shutdown' to take effect"
        fi

        RESULTS+=("WSL Memory Optimization: OK (.wslconfig configured)")
    else
        log_warn "Failed to retrieve Windows user directory"
        log_info "Please manually add the following to %USERPROFILE%\\.wslconfig:"
        echo "  [experimental]"
        echo "  autoMemoryReclaim=gradual"
        RESULTS+=("WSL Memory Optimization: Manual configuration required")
    fi

    # Guidance for immediate cache clearing
    log_info "To clear memory cache immediately, run the following:"
    echo "  sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'"
else
    log_info "Not in WSL environment. Skipping memory optimization settings."
fi

# ============================================================
# STEP 11: Memory MCP Setup
# ============================================================
log_step "STEP 11: Memory MCP Setup"

if command -v claude &> /dev/null; then
    # Check if Memory MCP is already configured
    if claude mcp list 2>/dev/null | grep -q "memory"; then
        log_info "Memory MCP is already configured"
        RESULTS+=("Memory MCP: OK (Configured)")
    else
        log_info "Configuring Memory MCP..."
        if claude mcp add memory \
            -e MEMORY_FILE_PATH="$SCRIPT_DIR/memory/shogun_memory.jsonl" \
            -- npx -y @modelcontextprotocol/server-memory 2>/dev/null; then
            log_success "Memory MCP setup complete"
            RESULTS+=("Memory MCP: Setup complete")
        else
            log_warn "Failed to configure Memory MCP (can be configured manually)"
            RESULTS+=("Memory MCP: Setup failed (can be configured manually)")
        fi
    fi
else
    log_warn "claude command not found. Skipping Memory MCP setup."
    RESULTS+=("Memory MCP: Skipped (claude not installed)")
fi

# ============================================================
# Result Summary
# ============================================================
echo ""
echo "  ╔══════════════════════════════════════════════════════════════╗"
echo "  ║  📋 Setup Result Summary                                  ║"
echo "  ╚══════════════════════════════════════════════════════════════╝"
echo ""

for result in "${RESULTS[@]}"; do
    if [[ $result == *"Not installed"* ]] || [[ $result == *"failed"* ]]; then
        echo -e "  ${RED}✗${NC} $result"
    elif [[ $result == *"Upgrade"* ]] || [[ $result == *"Skipped"* ]]; then
        echo -e "  ${YELLOW}!${NC} $result"
    else
        echo -e "  ${GREEN}✓${NC} $result"
    fi
done

echo ""

if [ "$HAS_ERROR" = true ]; then
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║  ⚠️  Some dependencies are missing                           ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Please check the warnings above and install what is missing."
    echo "  Once all dependencies are met, you can run this script again."
else
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║  ✅ Setup complete! Prepared for battle!                     ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
fi

echo ""
echo "  ┌──────────────────────────────────────────────────────────────┐"
echo "  │  📜 Next Steps                                               │"
echo "  └──────────────────────────────────────────────────────────────┘"
echo ""
echo "  ⚠️  First time only: Please run the following manually"
echo ""
echo "  STEP 0: Apply PATH (reflect installation results in this shell)"
echo "     source ~/.bashrc"
echo ""
echo "  STEP A: OAuth Auth + Bypass Permissions Approval (Completed in 1 command)"
echo "     claude --dangerously-skip-permissions"
echo ""
echo "     1. Browser opens -> Log in with Anthropic account -> Return to CLI"
echo "        * If browser does not open in WSL, copy/paste the URL to your"
echo "          Windows browser manually."
echo "     2. Bypass Permissions approval screen appears"
echo "        -> Select \"Yes, I accept\" (Press down arrow to select 2 and press Enter)"
echo "     3. Exit with /exit"
echo ""
echo "     * Once approved, it is saved in ~/.claude/ and not needed hereafter."
echo ""
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo "  DEPARTING FOR BATTLE (Start the v2 specialist team):"
echo "     bash scripts/shutsujin_departure_v2.sh"
echo ""
echo "  ────────────────────────────────────────────────────────────────"
echo "  TOPOLOGY (v2 specialist team — default):"
echo "     The default topology is v2 (shogun + orchestrator + 7 specialists)."
echo "     Pane layout: shogun:main.0 + multiagent:ops.{0..3} + multiagent:research.{0..3}."
echo ""
echo "     To customize roles, edit config/settings.yaml's `roles:` block."
echo ""
echo "  * Shell settings can also be modified in config/settings.yaml under 'shell:'"
echo ""
echo "  For details, please refer to README.md."
echo ""
echo "  ════════════════════════════════════════════════════════════════"
echo "   Tenka Fubu! (Rule the realm!)"
echo "  ════════════════════════════════════════════════════════════════"
echo ""

# Return exit 1 if dependencies are missing (so install.bat can detect it)
if [ "$HAS_ERROR" = true ]; then
    exit 1
fi

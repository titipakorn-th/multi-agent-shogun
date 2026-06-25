#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# team_monitor.sh — Detect stalled or dead agents via Claude session file mtime
# ═══════════════════════════════════════════════════════════════════════════════
#
# Three failure modes detected (NO agent-side change required):
#   1. Pane dead (tmux pane_dead=1)              → instant alert
#   2. Shell process dead (kill -0 on pane_pid)  → instant alert
#   3. Session file stale > threshold while task in-flight → "stalled" alert
#
# Implementation note: tmux 3.x's `#{pane_activity}` is empty for agent panes
# (it only tracks user keystrokes, not agent output). The reliable liveness
# signal is the Claude session file:
#   ~/.claude/projects/<project-hash>/<session-uuid>.jsonl
# Claude Code writes to this file on every tool call, every response, and
# every thinking step — so mtime advances during the entire work cycle,
# including API-call waits.
#
# The script walks each pane's process tree to find the CLI child, then
# uses `lsof` to identify its session file. Stale mtime = stalled agent.
#
# Usage:
#   bash scripts/team_monitor.sh --once         # Single check, exit 0/1
#   bash scripts/team_monitor.sh --daemon       # Background loop, 30s poll
#   bash scripts/team_monitor.sh --check <role> # Single role check
#   bash scripts/team_monitor.sh --status       # JSON snapshot of all agents
#
# Config (env vars, defaults shown):
#   STALE_THRESHOLD_OPUS=600    # 10 min for opus-tier
#   STALE_THRESHOLD_SONNET=300  # 5 min for sonnet-tier
#   STALE_THRESHOLD_HAIKU=300   # 5 min for haiku-tier
#   POLL_INTERVAL=30            # daemon mode loop interval
#   ALERT_COOLDOWN=600          # min seconds between re-alerts for same agent+msg
#
# Suggested cron entry (or run --daemon from a tmux pane):
#   * * * * * cd /path/to/project && bash scripts/team_monitor.sh --once >> logs/team_monitor.log 2>&1
# ═══════════════════════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Config ─────────────────────────────────────────────────────────────────
STALE_THRESHOLD_OPUS="${STALE_THRESHOLD_OPUS:-600}"
STALE_THRESHOLD_SONNET="${STALE_THRESHOLD_SONNET:-300}"
STALE_THRESHOLD_HAIKU="${STALE_THRESHOLD_HAIKU:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
ALERT_COOLDOWN="${ALERT_COOLDOWN:-600}"
PROJECT_NAME=$(basename "$PROJECT_ROOT")
ALERT_STATE_DIR="${ALERT_STATE_DIR:-/tmp/team_monitor_${PROJECT_NAME}}"
ALERT_LOG="$PROJECT_ROOT/queue/metrics/team_monitor_alerts.log"
# Claude session dir: replace every / with - in project path
# Convention: /Users/prince/Workspaces/foo → -Users-prince-Workspaces-foo
PROJECT_HASH=$(echo "$PROJECT_ROOT" | sed 's|/|-|g')
SESSION_DIR="$HOME/.claude/projects/$PROJECT_HASH"
mkdir -p "$ALERT_STATE_DIR" "$(dirname "$ALERT_LOG")"

# ─── Helpers ────────────────────────────────────────────────────────────────

# Load agent list as "agent_id|pane_target|model" lines from config.
load_agents() {
  python3 - "$PROJECT_ROOT/config/settings.yaml" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1]) as f:
        cfg = yaml.safe_load(f)
except Exception as e:
    sys.exit(f"Error reading config: {e}")
roles = cfg.get("roles", {}) or {}
for role, spec in roles.items():
    if not isinstance(spec, dict):
        continue
    pane = spec.get("pane_target", "")
    model = spec.get("model", "sonnet")
    if pane:
        print(f"{role}|{pane}|{model}")
PY
}

# Staleness threshold (seconds) for a model tier.
threshold_for() {
  case "$1" in
    opus)  echo "$STALE_THRESHOLD_OPUS" ;;
    haiku) echo "$STALE_THRESHOLD_HAIKU" ;;
    *)     echo "$STALE_THRESHOLD_SONNET" ;;
  esac
}

# Recursively find an agent CLI child in a process tree.
# Matches claude / codex / copilot / agy / antigravity processes.
find_cli_pid() {
  local pid="$1"
  [ -z "$pid" ] || [ "$pid" = "0" ] && return 1
  local cmd
  cmd=$(ps -p "$pid" -o args= 2>/dev/null) || return 1
  if echo "$cmd" | grep -qE '(claude|codex|copilot|agy|antigravity)'; then
    echo "$pid"
    return 0
  fi
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    local found
    found=$(find_cli_pid "$child") && { echo "$found"; return 0; }
  done
  return 1
}

# Get the .jsonl session file for a pane.
#
# Strategy:
#   1. Try `lsof` on the CLI child — works for CLIs that keep the file open.
#   2. Fall back to the most recently modified .jsonl in the project session dir.
#      This is a HEURISTIC: when only one agent is active, it picks the right
#      file; when multiple agents are running concurrently, it picks whichever
#      file was updated most recently (good enough to detect project-level
#      stalls, but not strictly per-agent). Per-agent precision requires a
#      Claude Code API that exposes the session UUID — not available today.
get_session_file() {
  local pane_pid="$1"
  local cli_pid
  cli_pid=$(find_cli_pid "$pane_pid")
  if [ -n "$cli_pid" ]; then
    local file
    file=$(lsof -p "$cli_pid" 2>/dev/null | awk '/\.jsonl$/ {print $NF; exit}')
    if [ -n "$file" ] && [ -f "$file" ]; then
      echo "$file"
      return 0
    fi
  fi
  if [ -d "$SESSION_DIR" ]; then
    local recent
    recent=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$recent" ]; then
      echo "$recent"
      return 0
    fi
  fi
  return 1
}

# Stable hash key for an (agent, message) alert.
alert_key() {
  echo -n "$1:$2" | md5sum | cut -c1-16
}

# Cooldown: only re-alert if last alert was >= ALERT_COOLDOWN ago.
should_alert() {
  local key="$1"
  local state_file="$ALERT_STATE_DIR/$key"
  if [ -f "$state_file" ]; then
    local last
    last=$(cat "$state_file" 2>/dev/null || echo 0)
    local now; now=$(date +%s)
    [ "$((now - last))" -ge "$ALERT_COOLDOWN" ]
  else
    return 0
  fi
}

mark_alerted() {
  echo "$(date +%s)" > "$ALERT_STATE_DIR/$1"
}

# Send alert via ntfy.sh + log to file. Respects cooldown.
send_alert() {
  local agent_id="$1"
  local msg="$2"
  local key
  key=$(alert_key "$agent_id" "$msg")

  if ! should_alert "$key"; then
    return 0
  fi
  mark_alerted "$key"

  local full="🚨 [team_monitor] $agent_id: $msg"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $full" >> "$ALERT_LOG"

  if [ -x "$SCRIPT_DIR/ntfy.sh" ]; then
    bash "$SCRIPT_DIR/ntfy.sh" "$full" 2>/dev/null || true
  fi
  echo "$full" >&2
}

# Read task status for an agent (idle | assigned | in_progress | done | failed).
# Use the specific `.task.status` path (not bare `.status`) to avoid matching
# nested "idle"/"complete" mentions inside context strings.
read_task_status() {
  local agent_id="$1"
  local task_file="$PROJECT_ROOT/queue/tasks/${agent_id}.yaml"
  if [ -f "$task_file" ]; then
    local s
    s=$(yq -r '.task.status // "idle"' "$task_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    [ -z "$s" ] && s="idle"
    echo "$s"
  else
    echo "idle"
  fi
}

# Check one agent. Returns 0 if OK, 1 if alert condition.
check_agent() {
  local agent_id="$1"
  local pane="$2"
  local model="$3"
  local now; now=$(date +%s)
  local threshold; threshold=$(threshold_for "$model")

  # Get pane state (dead flag, shell PID)
  local state
  state=$(tmux list-panes -t "$pane" -F '#{pane_dead} #{pane_pid}' 2>/dev/null) || {
    send_alert "$agent_id" "PANE MISSING (tmux target '$pane' not found)"
    return 1
  }
  read -r pane_dead pane_pid <<< "$state"

  # Check 1: pane dead
  if [ "$pane_dead" = "1" ]; then
    send_alert "$agent_id" "PANE DEAD (pane_dead=1, pid $pane_pid)"
    return 1
  fi

  # Check 2: shell process dead
  if [ -n "$pane_pid" ] && [ "$pane_pid" != "0" ] && ! kill -0 "$pane_pid" 2>/dev/null; then
    send_alert "$agent_id" "SHELL PROCESS DEAD (pid $pane_pid gone)"
    return 1
  fi

  # Check 3: is a CLI child actually running in this pane?
  # If yes, the agent is alive regardless of session-file heuristics.
  local cli_pid; cli_pid=$(find_cli_pid "$pane_pid" || true)
  if [ -z "$cli_pid" ]; then
    local task_status; task_status=$(read_task_status "$agent_id")
    if [ "$task_status" = "assigned" ] || [ "$task_status" = "in_progress" ]; then
      send_alert "$agent_id" "AGENT NOT RUNNING (no CLI child, task=$task_status)"
      return 1
    fi
    echo "$agent_id IDLE (no CLI child, task=$task_status)"
    return 0
  fi

  # Check 4: session file staleness (best-effort; fallback may map to wrong agent)
  local session_file; session_file=$(get_session_file "$pane_pid" || true)
  local staleness=-1
  if [ -n "$session_file" ]; then
    local mtime; mtime=$(stat -f %m "$session_file" 2>/dev/null || echo 0)
    staleness=$((now - mtime))
  fi

  local task_status; task_status=$(read_task_status "$agent_id")

  if [ "$staleness" -ge 0 ] && [ "$staleness" -gt "$threshold" ]; then
    if [ "$task_status" = "assigned" ] || [ "$task_status" = "in_progress" ]; then
      send_alert "$agent_id" "STALLED ${staleness}s (threshold=${threshold}s, task=$task_status, session=$(basename "$session_file"))"
      return 1
    fi
  fi

  echo "$agent_id OK (cli_pid=$cli_pid, staleness=${staleness}s, threshold=${threshold}s, task=$task_status)"
  return 0
}

# Run checks for all agents. Returns 0 if all OK, 1 if any alert.
run_all_checks() {
  local rc=0
  while IFS='|' read -r agent pane model; do
    [ -z "$agent" ] && continue
    check_agent "$agent" "$pane" "$model" || rc=1
  done < <(load_agents)
  return $rc
}

# JSON snapshot of all agents (no alerts).
status_json() {
  local now; now=$(date +%s)
  local first=1
  echo "{"
  echo "  \"timestamp\": \"$(date -Iseconds)\","
  echo "  \"project\": \"$PROJECT_NAME\","
  echo "  \"agents\": ["
  while IFS='|' read -r agent pane model; do
    [ -z "$agent" ] && continue
    [ "$first" -eq 0 ] && echo ","
    first=0

    local state
    state=$(tmux list-panes -t "$pane" -F '#{pane_dead} #{pane_pid}' 2>/dev/null || echo "1 0")
    read -r pane_dead pane_pid <<< "$state"

    local proc_alive="false"
    if [ -n "$pane_pid" ] && [ "$pane_pid" != "0" ]; then
      kill -0 "$pane_pid" 2>/dev/null && proc_alive="true"
    fi

    local session_file; session_file=$(get_session_file "$pane_pid" || true)
    local staleness=-1
    if [ -n "$session_file" ]; then
      local mtime; mtime=$(stat -f %m "$session_file" 2>/dev/null || echo 0)
      staleness=$((now - mtime))
    fi

    local threshold; threshold=$(threshold_for "$model")
    local task_status; task_status=$(read_task_status "$agent")

    local status="alive"
    [ "$pane_dead" = "1" ] && status="dead"
    [ "$proc_alive" = "false" ] && status="dead"
    [ -z "$session_file" ] && [ "$task_status" = "idle" ] && status="idle"

    local stale_alert="false"
    if [ "$staleness" -ge 0 ] && [ "$staleness" -gt "$threshold" ] && { [ "$task_status" = "assigned" ] || [ "$task_status" = "in_progress" ]; }; then
      stale_alert="true"
    fi

    local session_name="null"
    [ -n "$session_file" ] && session_name="\"$(basename "$session_file")\""

    echo "    {\"role\": \"$agent\", \"model\": \"$model\", \"pane\": \"$pane\", \"status\": \"$status\", \"staleness_sec\": $staleness, \"threshold_sec\": $threshold, \"task_status\": \"$task_status\", \"session_file\": $session_name, \"stale_alert\": $stale_alert}"
  done < <(load_agents)
  echo "  ]"
  echo "}"
}

# ─── Main dispatch ──────────────────────────────────────────────────────────
mode="${1:-}"
case "$mode" in
  --once)   run_all_checks ;;
  --daemon)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] team_monitor: daemon mode, poll=${POLL_INTERVAL}s" >> "$ALERT_LOG"
    while true; do
      run_all_checks || true
      sleep "$POLL_INTERVAL"
    done
    ;;
  --check)
    agent="${2:?usage: --check <role>}"
    found=0
    rc=0
    while IFS='|' read -r a pane model; do
      if [ "$a" = "$agent" ]; then
        check_agent "$a" "$pane" "$model" || rc=1
        found=1
      fi
    done < <(load_agents)
    [ "$found" -eq 0 ] && { echo "agent '$agent' not found in config" >&2; exit 2; }
    exit $rc
    ;;
  --status) status_json ;;
  --help|-h)
    sed -n '2,30p' "$0"
    ;;
  *)
    echo "Usage: $0 {--once|--daemon|--check <role>|--status|--help}" >&2
    exit 2
    ;;
esac

#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# stop_hook_inbox.sh — Claude Code Stop Hook for inbox delivery
# ═══════════════════════════════════════════════════════════════
# When a Claude Code agent finishes its turn and is about to go idle,
# this hook:
#   1. Analyzes last_assistant_message to detect task completion/error
#   2. Auto-notifies orchestrator via inbox_write (background, non-blocking)
#   3. Checks the agent's inbox for unread messages
#   4. If unread messages exist, BLOCKs the stop and feeds them back
#
# Usage: Registered as a Stop hook in .claude/settings.json
#   The hook receives JSON on stdin; outputs JSON to stdout.
#
# Environment:
#   TMUX_PANE — used to identify which agent is running
#   __STOP_HOOK_SCRIPT_DIR — override for testing (default: auto-detect)
#   __STOP_HOOK_AGENT_ID  — override for testing (default: from tmux)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="${__STOP_HOOK_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# ─── Read stdin (hook input JSON) ───
INPUT=$(cat)

# ─── Identify agent ───
if [ -n "${__STOP_HOOK_AGENT_ID+x}" ]; then
    AGENT_ID="$__STOP_HOOK_AGENT_ID"
elif [ -n "${TMUX_PANE:-}" ]; then
    AGENT_ID=$(tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}' 2>/dev/null || true)
else
    AGENT_ID=""
fi

# If we can't identify the agent, approve (exit 0 with no output = approve)
if [ -z "$AGENT_ID" ]; then
    exit 0
fi

# Shogun is the Lord's conversation pane — skip stop hook entirely
if [ "$AGENT_ID" = "shogun" ]; then
    exit 0
fi

# ─── Define inbox path early (used in multiple places below) ───
INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"

# ─── Infinite loop prevention ───
# When stop_hook_active=true, the agent is already continuing from a
# previous Stop hook block. Allow it to stop this time to prevent loops.
STOP_HOOK_ACTIVE=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" 2>/dev/null || echo "False")
if [ "$STOP_HOOK_ACTIVE" = "True" ]; then
    # Agent is going idle (exit 0) regardless of unread count.
    # ALWAYS create the idle flag so inbox_watcher knows the agent is idle
    # and can send nudges. Previously, removing the flag here when unread > 0
    # caused a deadlock: agent idle but watcher thinks busy → no nudge → stuck.
    FLAG="${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
    touch "$FLAG"
    # When stop_hook_active=True, the first block already delivered the inbox
    # message to the agent. Check if the agent processed it (UNREAD decreased).
    UNREAD_COUNT=$(grep -c 'read: false' "$INBOX" 2>/dev/null || true)
    if [ "${UNREAD_COUNT:-0}" -gt 0 ]; then
        # Agent did not process the inbox yet. EXIT 0 here to avoid:
        #   (a) 55s inotifywait → timeout → "Stop hook error occurred"
        #   (b) infinite block loop (block → active → block → ...)
        # inbox_watcher will re-deliver a fresh nudge via the idle flag.
        exit 0
    fi
    # UNREAD=0: agent processed its inbox. Wait for new incoming messages.
    # Also wait with inotifywait when stop_hook_active=True (for handling continuous loop processing)
    # exit 0 on timeout (55s) -> loop terminates after a finite number of iterations
    WATCH_TARGETS_ACTIVE=("$INBOX")
    if [ "$AGENT_ID" = "shogun" ]; then
        WATCH_TARGETS_ACTIVE+=("$SCRIPT_DIR/dashboard.md")
    fi
    if command -v inotifywait &>/dev/null; then
        inotifywait -e close_write -e moved_to \
            --timeout 55 \
            "${WATCH_TARGETS_ACTIVE[@]}" 2>/dev/null || true
    fi
    UNREAD_COUNT=$(grep -c 'read: false' "$INBOX" 2>/dev/null || true)
    if [ "${UNREAD_COUNT:-0}" -eq 0 ]; then
        exit 0
    fi
    # New messages arrived during inotifywait → fall through to block
fi

# ─── Analyze last_assistant_message (v2.1.47+) ───
# Shogun skips orchestrator notification (shogun doesn't report to orchestrator)
# but still falls through to inbox check below.
LAST_MSG=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_assistant_message', ''))" 2>/dev/null || echo "")

if [ -n "$LAST_MSG" ]; then
    NOTIFY_TYPE=""
    NOTIFY_CONTENT=""

    # Completion detection (English)
    if echo "$LAST_MSG" | grep -qiE 'report.*updated|task completed|mission complete|completed'; then
        NOTIFY_TYPE="report_completed"
        NOTIFY_CONTENT="${AGENT_ID}, task completed. Please check the report."
    # Error detection (require verb+context to avoid false positives)
    elif echo "$LAST_MSG" | grep -qiE 'abort|error.*abort|failed.*stop|error.*stop|failed.*abort|interrupted.*error|not found.*interrupt'; then
        NOTIFY_TYPE="error_report"
        NOTIFY_CONTENT="${AGENT_ID}, stopped with error. Please check."
    fi

    # Send notification to orchestrator (background, non-blocking)
    # Shogun doesn't report to orchestrator — skip notification
    if [ -n "$NOTIFY_TYPE" ] && [ "$AGENT_ID" != "shogun" ]; then
        bash "$SCRIPT_DIR/scripts/inbox_write.sh" orchestrator \
            "$NOTIFY_CONTENT" \
            "$NOTIFY_TYPE" "$AGENT_ID" &
    fi
fi

# ─── Check inbox for unread messages ───
INBOX="$SCRIPT_DIR/queue/inbox/${AGENT_ID}.yaml"

if [ ! -f "$INBOX" ]; then
    exit 0
fi

# Count unread messages using grep (fast, no python dependency)
UNREAD_COUNT=$(grep -c 'read: false' "$INBOX" 2>/dev/null || true)

FLAG="${IDLE_FLAG_DIR:-/tmp}/shogun_idle_${AGENT_ID}"
if [ "${UNREAD_COUNT:-0}" -eq 0 ]; then
    touch "$FLAG"
    # Wait up to 55 seconds for inbox changes using inotifywait
    # Also monitor dashboard.md (only for shogun)
    WATCH_TARGETS=("$INBOX")
    if [ "$AGENT_ID" = "shogun" ]; then
        WATCH_TARGETS+=("$SCRIPT_DIR/dashboard.md")
    fi
    if command -v inotifywait &>/dev/null; then
        inotifywait -e close_write -e moved_to \
            --timeout 55 \
            "${WATCH_TARGETS[@]}" 2>/dev/null || true
    else
        # inotifywait not available: fall through to exit 0
        :
    fi
    # Re-check after waiting
    UNREAD_COUNT=$(grep -c 'read: false' "$INBOX" 2>/dev/null || true)
    if [ "${UNREAD_COUNT:-0}" -eq 0 ]; then
        exit 0
    fi
    # Unread messages exist → fall through to block response below
fi
# NOTE: Do NOT rm -f the flag here. The old logic removed the flag when
# unread > 0 and blocked the stop, expecting the re-fired stop_hook
# (with stop_hook_active=True) to restore it. But if the agent processes
# the unread messages and then the second stop_hook doesn't fire or
# stop_hook_active isn't set, the flag is permanently lost → deadlock.
# Instead, keep the flag alive. The watcher will see the agent as idle
# and send a nudge, which is the correct behavior — the agent IS idle
# between the block response and the next turn.
# The flag will be removed naturally when the agent starts its next turn
# (Claude Code removes it via the busy detection mechanism).

# ─── Extract unread message summaries and build block JSON ───
# Use a single python3 call with env vars to avoid shell quoting issues.
# The old approach embedded $SUMMARY in triple-quotes, which broke when
# inbox content contained quotes or special characters.
__STOP_HOOK_INBOX="$INBOX" __STOP_HOOK_AGENT_ID_OUT="$AGENT_ID" \
__STOP_HOOK_UNREAD_COUNT="$UNREAD_COUNT" \
python3 -c "
import json, os, yaml

inbox = os.environ['__STOP_HOOK_INBOX']
agent_id = os.environ['__STOP_HOOK_AGENT_ID_OUT']
count = int(os.environ['__STOP_HOOK_UNREAD_COUNT'])

summary = ''
try:
    with open(inbox, 'r') as f:
        data = yaml.safe_load(f)
    msgs = data.get('messages', []) if data else []
    unread = [m for m in msgs if not m.get('read', True)]
    parts = []
    for m in unread[:5]:
        frm = m.get('from', '?')
        typ = m.get('type', '?')
        content = str(m.get('content', ''))[:80]
        parts.append(f'[{frm}/{typ}] {content}')
    summary = ' | '.join(parts)
except Exception:
    summary = f'{count} unread messages in inbox'

reason = f'{count} unread messages in inbox. Read and process queue/inbox/{agent_id}.yaml. Content: {summary}'
print(json.dumps({'decision': 'block', 'reason': reason}, ensure_ascii=False))
" 2>/dev/null || echo "{\"decision\":\"block\",\"reason\":\"${UNREAD_COUNT} unread messages in inbox. Read and process queue/inbox/${AGENT_ID}.yaml.\"}"

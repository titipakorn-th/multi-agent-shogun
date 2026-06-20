#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# shogun_stop_telegram_forward.sh — Claude Code Stop Hook
# ═══════════════════════════════════════════════════════════════
# Purpose:
#   When the Shogun finishes a response that LOOKS like a report
#   (contains report markers), forward the last ~40 lines of that
#   response to the Lord's Telegram. This is a safety net for when
#   the Shogun forgets to call telegram_ask.py himself.
#
# Why a hook, not Shogun's discipline:
#   Stop hooks are run by the harness, not by Shogun. The harness
#   does not forget. Shogun sometimes does.
#
# Why last_assistant_message, not tmux capture-pane:
#   CLAUDE.md forbids Shogun from capturing his own pane (self-
#   observation loop). The Stop hook receives last_assistant_message
#   on stdin — same content, no observation loop, no ANSI cruft.
#
# Activation:
#   - Only when AGENT_ID = "shogun" (other agents skipped silently)
#   - Only when last_assistant_message contains a report marker
#   - De-dupes against the previous send via a content hash
#
# Markers:
#   📊  🚨  ✅  ❌  report:  complete  completed  finished  failed  failure
#
# Telegram delivery:
#   python3 scripts/telegram_ask.py --info --question "<text>"
#   --info means: fire-and-forget, no question, no blocking,
#   no current_question.json mutation.
#
# Environment overrides (for testing):
#   __STOP_HOOK_AGENT_ID — force the agent id
#   __STOP_HOOK_SCRIPT_DIR — force the project root
#   __SHOGUN_FORWARD_DRY_RUN=1 — print the call instead of running it
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="${__STOP_HOOK_SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="$SCRIPT_DIR/queue"
LAST_HASH_FILE="$STATE_DIR/.shogun_telegram_forward_last_hash"
LOG_FILE="$SCRIPT_DIR/logs/shogun_telegram_forward.log"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")" 2>/dev/null || true

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null || true; }

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

# Only act when Shogun is the speaker. Any other agent: exit silently (approve).
if [ "$AGENT_ID" != "shogun" ]; then
    exit 0
fi

# ─── Extract last_assistant_message ───
LAST_MSG=$(printf '%s' "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_assistant_message',''))" 2>/dev/null || echo "")

if [ -z "$LAST_MSG" ]; then
    exit 0
fi

# ─── Marker scan ───
# Two passes so both BSD (macOS) and GNU grep work:
#   1) literal emoji markers (case-sensitive)
#   2) ASCII status words (case-insensitive)
if ! printf '%s' "$LAST_MSG" | grep -qE '📊|🚨|✅|❌' \
   && ! printf '%s' "$LAST_MSG" | grep -qiE 'report:|complete(d)?|finished|failed|failure|pr opened|pull request opened'; then
    exit 0
fi

# ─── De-dupe: skip if identical to previous forward ───
CONTENT_HASH=$(printf '%s' "$LAST_MSG" | shasum -a 256 | awk '{print $1}')
if [ -f "$LAST_HASH_FILE" ] && [ "$(cat "$LAST_HASH_FILE" 2>/dev/null)" = "$CONTENT_HASH" ]; then
    log "skip: identical to previous send (hash=${CONTENT_HASH:0:10})"
    exit 0
fi

# ─── Build forward payload: last 40 lines, capped to Telegram's safe size ───
# Telegram's hard limit is 4096 chars; we leave headroom for the prefix.
TAIL_TEXT=$(printf '%s' "$LAST_MSG" | tail -n 40)

# Cap at 3800 chars (Markdown prefix takes ~30, chunking handles the rest).
MAX_CHARS=3800
TAIL_LEN=${#TAIL_TEXT}
if [ "$TAIL_LEN" -gt "$MAX_CHARS" ]; then
    TAIL_TEXT="…(truncated $((TAIL_LEN - MAX_CHARS)) chars)…
$(printf '%s' "$TAIL_TEXT" | tail -c "$MAX_CHARS")"
fi

FORWARD_MSG="🛡 Shogun report (auto-forwarded from CLI)
${TAIL_TEXT}"

# ─── Send (background, non-blocking) ───
if [ -n "${__SHOGUN_FORWARD_DRY_RUN:-}" ]; then
    log "dry-run: would forward $TAIL_LEN chars (hash=${CONTENT_HASH:0:10})"
    printf 'DRY_RUN forward:\n%s\n' "$FORWARD_MSG"
else
    log "forward: ${TAIL_LEN} chars (hash=${CONTENT_HASH:0:10})"
    (
        cd "$SCRIPT_DIR" && \
        python3 scripts/telegram_ask.py --info --question "$FORWARD_MSG" \
            >>"$LOG_FILE" 2>&1
    ) &
    disown 2>/dev/null || true
fi

# Record hash so we don't re-send the same payload on rapid re-Stops.
printf '%s' "$CONTENT_HASH" >"$LAST_HASH_FILE" 2>/dev/null || true

exit 0

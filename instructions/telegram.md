---
# ============================================================
# Telegram Agent Configuration - YAML Front Matter
# ============================================================
# Structured rules. Machine-readable. Edit only when changing rules.

role: telegram
version: "3.0"

forbidden_actions:
  - id: F001
    action: modify_core_codebase
    description: "Modify core project codebase without explicit instructions"
  - id: F002
    action: direct_ashigaru_command
    description: "Command Karo or Ashigaru agents directly"
  - id: F003
    action: polling
    description: "Polling loops"
    reason: "Wastes API credits"
  - id: F004
    action: skip_context_reading
    description: "Start answering btw questions without reading context files"

workflow:
  - step: 1
    action: identify_self
    command: "tmux display-message -t \"$TMUX_PANE\" -p '#{@agent_id}'"
  - step: 2
    action: read_inbox
    target: queue/inbox/telegram.yaml
  - step: 3
    action: process_messages
    note: "Read messages with read: false, execute requested command, and reply via ntfy.sh"
  - step: 4
    action: mark_read
    target: queue/inbox/telegram.yaml

# ============================================================
# Telegram Listener Slash Commands (handled by the listener, not the agent)
# ============================================================
# These commands are answered directly by scripts/telegram_listener.py and do NOT
# wake the Telegram agent. They exist so the Lord can check status from a phone
# without paying for a full agent invocation.
#
#   /progress   -> handled by listener (one-line "what is the system doing?")
#                  Priority: pending question > active task YAML > dashboard.md
#                  Always under 200 chars. If nothing is active, returns
#                  "🏯 All quiet on the army — no active tasks."
#   /status     -> handled by listener (shells out to scripts/agent_status.sh
#                  --lang en; no LLM). Captures tmux pane state, task IDs,
#                  and inbox unread counts for every agent. Markdown is
#                  stripped to plain text; hard-capped at 4000 chars.
#   /dashboard  -> handled by listener (reads queue/dashboard.md; no LLM).
#                  Returns the raw project summary with markdown headings
#                  flattened. Hard-capped at 4000 chars. Returns
#                  "🏯 No dashboard yet — no tasks have been registered."
#                  if the file is missing or empty.
#   /cancel     -> handled by listener (no LLM). Scans queue/shogun_to_karo.yaml
#                  for the most recent active cmd (status != done/cancelled),
#                  writes a `cancel_request` inbox message to Shogun so it can
#                  set the cmd's status to `cancelled` at the next safe
#                  checkpoint, and acks the Lord. 5s in-memory dedup so
#                  rapid taps do not spam Shogun's inbox. If no active cmd,
#                  returns "🏯 No active command to cancel." Bare "cancel"
#                  is also recognized.
#   /help       -> handled by listener (usage guide)
#
#   /btw        -> forwarded to Telegram agent (cheap side question; uses LLM)
#   /run        -> forwarded to Telegram agent (workspace shell command; uses LLM)
#
# Bare-word aliases ("status", "status?", "dashboard") follow the same
# routing as their slash-command counterparts and are also handled directly
# by the listener for consistency with /progress.
#
# Active-Blocker Blinker:
# Whenever queue/current_question.json is in status=pending or
# waiting_for_free_text, the listener automatically edits the original
# question message every ~30 seconds with "⏳ Waiting on Lord..." so the
# Lord can see at a glance that work is blocked. The edit stops as soon as
# the question is answered and the file is cleaned up.
---

#!/usr/bin/env bash
# auto_prompt_trigger.sh — Autonomous auto_prompt dispatcher.
# Solves the session-boundary race where Shogun misses Step 3.5 (manual
# auto_prompt check) on cmd completions. Called by telegram_listener.py
# every loop iteration.
#
# Usage:
#   source scripts/lib/auto_prompt_trigger.sh
#   auto_prompt_trigger_dispatch queue/inbox/shogun.yaml
#
# Behavior:
#   1. Read inbox; find entries with `type: report_completed` AND `read: true`
#      (already processed by Shogun's Step 1-4) that haven't been auto-dispatched.
#   2. For each new one: run auto_prompt_select_next; if found, append cmd to
#      queue/shogun_to_orchestrator.yaml + inbox_write orchestrator + ntfy Lord.
#   3. Track seen msg_ids in queue/.auto_prompt_seen (gitignored) for idempotency.
#   4. If cmd id starts with `auto_`, reset dispatches_this_session counter.
#
# Exit: 0 = success (incl zero dispatches), 1 = error.
# Ponytail: awk + grep + sed only. No Python or jq.

auto_prompt_trigger_dispatch() {
    local inbox_path="${1:-queue/inbox/shogun.yaml}"
    [[ ! -f "$inbox_path" ]] && return 0

    local seen_file="queue/.auto_prompt_seen"
    [[ ! -f "$seen_file" ]] && touch "$seen_file"

    # Gate 1: config flag.
    local enabled
    enabled=$(grep -A 8 '^auto_prompt:' config/settings.yaml 2>/dev/null \
              | grep -E 'enabled:' | head -1 | awk '{print $2}')
    [[ "$enabled" != "true" ]] && return 0

    # Gate 2: session cap (read state, compare to max).
    local max_disp
    max_disp=$(grep -A 8 '^auto_prompt:' config/settings.yaml 2>/dev/null \
               | grep -E 'max_dispatches_per_session:' | head -1 | awk '{print $2}')
    max_disp="${max_disp:-20}"
    local cur_disp
    cur_disp=$(grep -E '^dispatches_this_session:' queue/auto_prompt_state.yaml 2>/dev/null \
               | awk '{print $2}' | head -1)
    cur_disp="${cur_disp:-0}"
    [[ "$cur_disp" -ge "$max_disp" ]] && return 0

    declare -f auto_prompt_select_next >/dev/null || \
        source "$(dirname "${BASH_SOURCE[0]}")/auto_prompt_select.sh"

    # Extract (msg_id, type, read) tuples from inbox.
    local entries
    entries=$(awk '
        /^- content:/ { in_entry = 1; cur_type = ""; cur_id = ""; cur_read = ""; next }
        in_entry && /^  id:/   { sub(/^  id: */, "");   cur_id   = $0; next }
        in_entry && /^  type:/ { sub(/^  type: */, ""); cur_type = $0; next }
        in_entry && /^  read:/ { sub(/^  read: */, ""); cur_read = $0; next }
        in_entry && /^- /     { in_entry = 0; next }
        in_entry && /^$/      { if (cur_id != "" && cur_type != "" && cur_read != "") { print cur_id "\t" cur_type "\t" cur_read; in_entry = 0 } }
        END                     { if (cur_id != "" && cur_type != "" && cur_read != "") print cur_id "\t" cur_type "\t" cur_read }
    ' "$inbox_path")

    local dispatched=0
    while IFS=$'\t' read -r msg_id msg_type msg_read; do
        [[ -z "$msg_id" ]] && continue
        [[ "$msg_type" != "report_completed" ]] && continue
        [[ "$msg_read" != "true" ]] && continue
        grep -qxF "$msg_id" "$seen_file" 2>/dev/null && continue

        # Mark seen BEFORE dispatch (idempotent: don't double-fire on retry).
        echo "$msg_id" >> "$seen_file"

        # Run select.
        local sel; sel=$(auto_prompt_select_next ./plans 2>/dev/null)
        local result; result=$(echo "$sel" | grep -E '^RESULT=' | head -1 | cut -d= -f2)
        [[ "$result" != "found" ]] && continue

        local plan_file task_num task_title task_body
        plan_file=$(echo "$sel" | grep -E '^PLAN=' | head -1 | cut -d= -f2-)
        task_num=$(echo "$sel"  | grep -E '^TASK_NUM=' | head -1 | cut -d= -f2-)
        task_title=$(echo "$sel" | grep -E '^TASK_TITLE=' | head -1 | cut -d= -f2-)
        task_body=$(echo "$sel"  | awk '/^TASK_BODY=/{flag=1; next} flag{print}')

        # Build cmd. ID = auto_<unix_ts> to satisfy step 6 reset rule.
        local now; now=$(date '+%s')
        local auto_id="auto_${now}"
        local project="safepay"

        # Append to queue/shogun_to_orchestrator.yaml.
        cat >> queue/shogun_to_orchestrator.yaml <<YAML
  - id: ${auto_id}
    timestamp: "$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')"
    north_star: "Auto-dispatched from ${plan_file} Task ${task_num}: ${task_title}"
    purpose: "Auto-dispatched plan task. Shogun makes the call; Lord sees results."
    acceptance_criteria:
      - "Plan task ${task_num} marked complete (task body fully executed)"
      - "Oracle 1/4 docs/impl review verdict=approved (if applicable)"
    command: |
$(echo "$task_body" | sed 's/^/      /')
    project: ${project}
    priority: medium
    status: pending
YAML

        # Wake Orchestrator.
        bash scripts/inbox_write.sh orchestrator \
            "Auto-continuing from plan: $(basename "$plan_file") — Task ${task_num}: ${task_title}" \
            task_assigned shogun 2>/dev/null

        # Notify Lord.
        bash scripts/ntfy.sh "🏯 Auto-dispatched: $(basename "$plan_file") — Task ${task_num}: ${task_title}" \
            2>/dev/null

        # Increment dispatches_this_session.
        sed -i.bak "s/^dispatches_this_session: [0-9]*/dispatches_this_session: $((cur_disp + 1))/" \
            queue/auto_prompt_state.yaml 2>/dev/null && \
            rm -f queue/auto_prompt_state.yaml.bak

        dispatched=$((dispatched + 1))
    done <<< "$entries"

    [[ "$dispatched" -eq 0 ]] && return 0
    echo "dispatched=${dispatched}"
    return 0
}

# Direct invocation: `bash scripts/lib/auto_prompt_trigger.sh <inbox>`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_prompt_trigger_dispatch "${1:-queue/inbox/shogun.yaml}"
fi
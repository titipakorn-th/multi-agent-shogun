#!/usr/bin/env bash
# auto_prompt_trigger.sh — Autonomous auto_prompt dispatcher.
# Solves the session-boundary race where Shogun used to skip its manual
# auto_prompt check on cmd completions. Called by telegram_listener.py
# every loop iteration (mtime-gated, see scripts/telegram_listener.py).
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
#   4. Track dispatched auto_<ts> ids in queue/.auto_prompt_dispatched; when
#      any of them appears in the inbox (orchestrator reported back), reset
#      dispatches_this_session to 0 and prune that id from the dispatched list.
#
# Exit: 0 = success (incl zero dispatches), 1 = error.
# Ponytail: awk + grep + sed only. No Python or jq.

auto_prompt_trigger_dispatch() {
    local inbox_path="${1:-queue/inbox/shogun.yaml}"
    local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')

    [[ ! -f "$inbox_path" ]] && { echo "[$ts] inbox not found: $inbox_path"; return 0; }

    local seen_file="queue/.auto_prompt_seen"
    [[ ! -f "$seen_file" ]] && touch "$seen_file" 2>/dev/null

    # Prune seen file to ids that still appear in the inbox. Once an entry
    # is reaped (reap_inbox.sh) or read-marker stripped, the id no longer
    # needs to be remembered — the append-only growth was unbounded
    # (CLAUDE.md U5/U7 inbox hygiene class). Ponytail: diff against current
    # inbox, no separate store. Uses shared parse_inbox_ids helper — the
    # same one the main parser uses below — so the two parsers can't drift
    # again (round-2 had them diverged: main used flush, prune used END-only,
    # and the prune bug caused a live runaway of 12 duplicate dispatches).
    declare -f parse_inbox_ids >/dev/null || \
        source "$(dirname "${BASH_SOURCE[0]}")/parse_inbox.sh"

    if [[ -s "$seen_file" && -f "$inbox_path" ]]; then
        local inbox_ids
        inbox_ids=$(parse_inbox_ids "$inbox_path")
        local pruned_seen
        if [[ -n "$inbox_ids" ]]; then
            pruned_seen=$(grep -Fxf <(echo "$inbox_ids") "$seen_file" 2>/dev/null || true)
        else
            pruned_seen=""
        fi
        if [[ -n "$pruned_seen" ]]; then
            printf '%s\n' "$pruned_seen" > "$seen_file"
        else
            : > "$seen_file"
        fi
    fi

    # Gate 1: config flag.
    local enabled
    enabled=$(grep -A 8 '^auto_prompt:' config/settings.yaml 2>/dev/null \
              | grep -E 'enabled:' | head -1 | awk '{print $2}')
    [[ "$enabled" != "true" ]] && { echo "[$ts] auto_prompt disabled in config"; return 0; }

    # Gate 2: session cap (read state, compare to max).
    local max_disp
    max_disp=$(grep -A 8 '^auto_prompt:' config/settings.yaml 2>/dev/null \
               | grep -E 'max_dispatches_per_session:' | head -1 | awk '{print $2}')
    max_disp="${max_disp:-20}"
    local cur_disp
    cur_disp=$(grep -E '^dispatches_this_session:' queue/auto_prompt_state.yaml 2>/dev/null \
               | awk '{print $2}' | head -1)
    cur_disp="${cur_disp:-0}"

    # Reset path: if any auto_<ts> we previously dispatched has reported back
    # (its id appears in the inbox content), zero the counter and prune that
    # id from the dispatched list. Closes the one-way ratchet that would
    # otherwise permanently block all future dispatches at max.
    if [[ -s queue/.auto_prompt_dispatched ]]; then
        local matched=()
        local remaining=()
        local _auto_id
        while IFS= read -r _auto_id; do
            [[ -z "$_auto_id" ]] && continue
            if grep -qF "$_auto_id" "$inbox_path" 2>/dev/null; then
                matched+=("$_auto_id")
            else
                remaining+=("$_auto_id")
            fi
        done < queue/.auto_prompt_dispatched
        if [[ ${#matched[@]} -gt 0 ]]; then
            echo "[$ts] auto_prompt session reset: ${#matched[@]} auto_ cmd(s) reported back: ${matched[*]}"
            sed -i 's/^dispatches_this_session:.*/dispatches_this_session: 0/' \
                queue/auto_prompt_state.yaml 2>/dev/null
            cur_disp=0
            printf '%s\n' "${remaining[@]}" > queue/.auto_prompt_dispatched
        fi
    fi

    [[ "$cur_disp" -ge "$max_disp" ]] && { echo "[$ts] session cap reached: $cur_disp/$max_disp"; return 0; }

    declare -f auto_prompt_select_next >/dev/null || \
        source "$(dirname "${BASH_SOURCE[0]}")/auto_prompt_select.sh"

    # Extract (msg_id, type, read) tuples from inbox via the shared
    # parse_inbox_entries helper (see scripts/lib/parse_inbox.sh). Keeping
    # both this and the prune block above on the SAME parser prevents the
    # round-1/round-2 "two parsers drift, one is wrong" failure mode.
    local entries
    entries=$(parse_inbox_entries "$inbox_path")

    # Count report_completed read:true in this parse (real number, not literal).
    local seen_completed; seen_completed=$(echo "$entries" | grep -c $'\t''report_completed\ttrue$' || true)

    echo "[$ts] auto_prompt check: enabled=$enabled, session=$cur_disp/$max_disp, processed_reports=$seen_completed"

    local dispatched=0
    while IFS=$'\t' read -r msg_id msg_type msg_read; do
        [[ -z "$msg_id" ]] && continue
        [[ "$msg_type" != "report_completed" ]] && continue
        [[ "$msg_read" != "true" ]] && continue
        grep -qxF "$msg_id" "$seen_file" 2>/dev/null && continue
        echo "[$ts] auto_prompt processing: msg_id=$msg_id"

        # Mark seen BEFORE dispatch (idempotent: don't double-fire on retry).
        echo "$msg_id" >> "$seen_file"

        # Run select.
        local sel; sel=$(auto_prompt_select_next ./plans 2>/dev/null)
        local result; result=$(echo "$sel" | grep -E '^RESULT=' | head -1 | cut -d= -f2)
        echo "[$ts] auto_prompt select: result=$result"
        [[ "$result" != "found" ]] && continue

        local plan_file task_num task_title task_body plan_project
        plan_file=$(echo "$sel" | grep -E '^PLAN=' | head -1 | cut -d= -f2-)
        task_num=$(echo "$sel"  | grep -E '^TASK_NUM=' | head -1 | cut -d= -f2-)
        task_title=$(echo "$sel" | grep -E '^TASK_TITLE=' | head -1 | cut -d= -f2-)
        task_body=$(echo "$sel"  | awk '/^TASK_BODY=/{flag=1; next} flag{print}')
        plan_project=$(echo "$sel" | grep -E '^PROJECT=' | head -1 | cut -d= -f2-)

        # Build cmd. ID = auto_<unix_ts> so the reset path (zero counter when an
# auto_ cmd reports back) has a stable handle to grep for.
        local now; now=$(date '+%s')
        local auto_id="auto_${now}"
        # Project: prefer the plan's frontmatter, else default to "safepay"
        # (the historical hardcode; kept as documented fallback so we don't
        # silently route auto-dispatched cmds to an empty project field).
        local project="${plan_project:-safepay}"

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

        # Track this auto_ id so we can reset the counter when it reports back.
        echo "$auto_id" >> queue/.auto_prompt_dispatched

        dispatched=$((dispatched + 1))
    done <<< "$entries"

    echo "[$ts] auto_prompt completed: dispatched=$dispatched"
    [[ "$dispatched" -eq 0 ]] && return 0
    echo "dispatched=${dispatched}"
    return 0
}

# Direct invocation: `bash scripts/lib/auto_prompt_trigger.sh <inbox>`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_prompt_trigger_dispatch "${1:-queue/inbox/shogun.yaml}"
fi
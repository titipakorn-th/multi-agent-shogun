#!/usr/bin/env bash
# auto_prompt_self_heal.sh — Session-start recovery for action_required messages
# that slipped through the Auto-Resolve Branch.
#
# Usage: source scripts/lib/auto_prompt_self_heal.sh && self_heal_inbox <inbox.yaml>
# Exit: 0 = success (incl zero resolutions), 1 = actual error.
# Ponytail: awk + grep + sed only. No Python or jq.

self_heal_inbox() {
    local inbox_path="${1:-}"
    [[ -z "$inbox_path" ]] && { echo "resolved=0"; return 0; }
    [[ ! -f "$inbox_path" ]] && { echo "error: inbox not found: $inbox_path" >&2; return 1; }

    declare -f auto_prompt_resolve_action >/dev/null || \
        source "$(dirname "${BASH_SOURCE[0]}")/auto_prompt_resolve_action.sh"

    local tmp_dir; tmp_dir=$(mktemp -d /tmp/self_heal.XXXXXX) || return 1
    trap "rm -rf '$tmp_dir'" RETURN

    # awk emits each action_required/read:true entry as "id\tbody". Handles YAML
    # multi-line quoted scalars (4-space-indent continuation lines fold in).
    local entries
    entries=$(awk '
        function flush() { if (cur_id != "" && cur_type == "action_required" && cur_read == "true") print cur_id "\t" content_buf }
        /^- content:/ { flush(); in_entry = 1; sub(/^- content: */, ""); gsub(/^'\''/, ""); content_buf = $0; cur_id = ""; cur_type = ""; cur_read = ""; next }
        in_entry && /^    / && cur_id == "" { sub(/^    /, ""); sub(/'\''$/, ""); content_buf = content_buf " " $0; next }
        in_entry && /^  id:/   { sub(/^  id: */, "");   cur_id   = $0; next }
        in_entry && /^  type:/ { sub(/^  type: */, ""); cur_type = $0; next }
        in_entry && /^  read:/ { sub(/^  read: */, ""); cur_read = $0; next }
        END { flush() }
    ' "$inbox_path")

    local -a parts=()
    while IFS=$'\t' read -r msg_id msg_body; do
        [[ -z "$msg_id" ]] && continue
        local res_file="queue/current_question_${msg_id}.json"
        [[ -f "$res_file" ]] && continue  # idempotent skip

        local body_file="$tmp_dir/${msg_id}.txt"
        printf '%s\n' "$msg_body" > "$body_file"

        local resolution rc=0
        resolution=$(auto_prompt_resolve_action "$body_file" 2>/dev/null) || rc=$?
        [[ $rc -ne 0 ]] && continue  # skip no_recommended / parse_error

        local safe_resolution="${resolution//\"/\\\"}"
        local now; now=$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')
        printf '{\n  "status": "answered",\n  "response": "%s",\n  "resolved_by": "auto_prompt",\n  "source_message_id": "%s",\n  "resolved_at": "%s",\n  "session_id": "shogun-self-heal"\n}\n' \
            "$safe_resolution" "$msg_id" "$now" > "$res_file"

        # Bump dispatches_this_session counter.
        local cur; cur=$(grep -E '^dispatches_this_session:' queue/auto_prompt_state.yaml | awk '{print $2}' | head -1)
        cur=${cur:-0}
        sed -i.bak "s/^dispatches_this_session: [0-9]*/dispatches_this_session: $((cur + 1))/" \
            queue/auto_prompt_state.yaml && rm -f queue/auto_prompt_state.yaml.bak

        # Append audit entry; ensure file ends with a newline first.
        [[ "$(tail -c 1 queue/auto_prompt_state.yaml | wc -l)" -eq 0 ]] && printf '\n' >> queue/auto_prompt_state.yaml
        printf '  - question_id: %s\n    response: "%s"\n    resolved_at: "%s"\n' \
            "$msg_id" "$safe_resolution" "$now" >> queue/auto_prompt_state.yaml

        parts+=("${msg_id}: ${resolution}")
    done <<< "$entries"

    [[ ${#parts[@]} -eq 0 ]] && { echo "resolved=0"; return 0; }
    local IFS=', '; echo "resolved=${#parts[@]} [${parts[*]}]"
}

# Allow direct invocation: bash scripts/lib/auto_prompt_self_heal.sh <inbox>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    self_heal_inbox "$@"
fi
#!/usr/bin/env bash
# escalation_watchdog.sh — Stale action_required watchdog (cmd_068).
# Solves: orchestrator notifies shogun via inbox when action_required but
# never auto-Telegrams Lord. This is a belt-and-suspenders safety net:
# if orchestrator step 18 (write current_question.json + fire ntfy.sh)
# missed a transition, the listener calls this script every loop and
# forwards via ntfy.sh on its own.
#
# Usage:
#   source scripts/lib/escalation_watchdog.sh
#   escalation_watchdog_run queue/inbox/shogun.yaml
#
# Behavior:
#   1. Respect telegram.mode=off (grep settings.yaml → silent exit).
#   2. Find entries with read:false AND type:action_required.
#   3. If age > 60s AND no forwarded_at field: call scripts/ntfy.sh
#      with topic + msg_id, then sed-add forwarded_at:<now> to the entry.
#   4. Idempotent: replay-safe via forwarded_at marker.
#
# Exit: 0 = success (incl zero forwards), 1 = ntfy.sh failure.
# Ponytail: awk + grep + sed only. No Python or jq.

escalation_watchdog_run() {
    local inbox_path="${1:-queue/inbox/shogun.yaml}"
    [[ ! -f "$inbox_path" ]] && return 0

    # Mode gate: respect telegram.mode from settings.yaml.
    local mode
    mode=$(grep -A 4 '^telegram:' config/settings.yaml 2>/dev/null \
           | grep -E '^[[:space:]]+mode:' | head -1 \
           | sed -E 's/^[[:space:]]+mode:[[:space:]]*"?([^"]+)"?/\1/' \
           | tr '[:upper:]' '[:lower:]')
    [[ "$mode" == "off" ]] && return 0

    local now; now=$(date '+%s')
    local threshold=60

    # Parse inbox: (msg_id, type, read, timestamp, forwarded_at, has_fwd).
    local entries
    entries=$(awk '
        /^- content:/ {
            if (cur_id != "" && cur_type != "" && cur_read != "" && cur_ts != "")
                print cur_id "\t" cur_type "\t" cur_read "\t" cur_ts "\t" cur_fwd
            in_entry = 1; cur_type = ""; cur_id = ""; cur_read = ""; cur_ts = ""; cur_fwd = ""
            next
        }
        in_entry && /^  id:/            { sub(/^  id: */, "");            cur_id   = $0; next }
        in_entry && /^  type:/          { sub(/^  type: */, "");          cur_type = $0; next }
        in_entry && /^  read:/          { sub(/^  read: */, "");          cur_read = $0; next }
        in_entry && /^  timestamp:/     { sub(/^  timestamp: */, "");     cur_ts   = $0; gsub(/^'\''|'\''$/, "", cur_ts); next }
        in_entry && /^  forwarded_at:/  { sub(/^  forwarded_at: */, "");  cur_fwd  = $0; next }
        in_entry && /^- /               { in_entry = 0; next }
        in_entry && /^$/                {
            if (cur_id != "" && cur_type != "" && cur_read != "" && cur_ts != "")
                print cur_id "\t" cur_type "\t" cur_read "\t" cur_ts "\t" cur_fwd
            in_entry = 0
        }
        END {
            if (cur_id != "" && cur_type != "" && cur_read != "" && cur_ts != "")
                print cur_id "\t" cur_type "\t" cur_read "\t" cur_ts "\t" cur_fwd
        }
    ' "$inbox_path")

    local forwarded=0
    local rc=0
    while IFS=$'\t' read -r msg_id msg_type msg_read msg_ts msg_fwd; do
        [[ -z "$msg_id" ]] && continue
        [[ "$msg_type" != "action_required" ]] && continue
        [[ "$msg_read" != "false" ]] && continue
        [[ -n "$msg_fwd" ]] && continue   # replay-safe: already forwarded

        # Parse timestamp → epoch. Supports:
        #   2026-06-24T02:55:00+09:00  (colon offset)
        #   2026-06-24T02:55:00+0900   (no colon)
        #   2026-06-23T14:43:32        (no tz → treat as local)
        #   2026-06-23 14:43:32        (space separator)
        # ponytail: macOS date -j -f doesn't grok +HH:MM in %z, so strip colons
        # from the offset first.
        local ts_norm="$msg_ts"
        [[ "$ts_norm" == *+*:* ]] && ts_norm="${ts_norm/:+/:+}"  # noop marker
        ts_norm=$(echo "$msg_ts" | sed -E 's/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
        local entry_epoch
        entry_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts_norm" "+%s" 2>/dev/null) || \
        entry_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_norm" "+%s" 2>/dev/null) || \
        entry_epoch=$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts_norm" "+%s" 2>/dev/null) || \
        continue
        local age=$(( now - entry_epoch ))
        [[ $age -le $threshold ]] && continue

        # Fire ntfy.sh with msg_id reference. ntfy.sh is itself mode-gated.
        if ! bash scripts/ntfy.sh "[cmd_068 watchdog] stale action_required ${msg_id} (age=${age}s) — see queue/inbox/shogun.yaml" 2>/dev/null; then
            rc=1
            continue
        fi

        # Idempotency marker: sed-add forwarded_at after the timestamp line.
        sed -i.bak "/^  id: ${msg_id}\$/,/^  type:/ { /timestamp:/a\\
  forwarded_at: \"$(date -u '+%Y-%m-%dT%H:%M:%S+00:00')\"
}" "$inbox_path" 2>/dev/null && rm -f "${inbox_path}.bak"

        forwarded=$((forwarded + 1))
    done <<< "$entries"

    [[ $forwarded -eq 0 ]] && return 0
    echo "forwarded=${forwarded}"
    return $rc
}

# Direct invocation: `bash scripts/lib/escalation_watchdog.sh <inbox>`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    escalation_watchdog_run "${1:-queue/inbox/shogun.yaml}"
fi

#!/usr/bin/env bash
# parse_inbox.sh — Shared inbox-entry parsers.
#
# Round-1 (plans/2026-06-27-auto-prompt-wiring-gaps.md) fixed a
# blank-line/END-only emit bug in `auto_prompt_trigger.sh`'s main parser.
# Round-2 Task 3 then introduced the SAME bug in a second hand-rolled
# awk copy inside the same file (the seen-file prune block), which
# silently dropped every earlier inbox id from `.auto_prompt_seen` and
# let the trigger re-dispatch the same `report_completed` every loop —
# 12 duplicate auto_ cmds accumulated in queue/shogun_to_orchestrator.yaml
# before it was caught.
#
# The bug class — "hand-rolled inbox parser that drops entries" — kept
# resurfacing because the parser was inlined in multiple places. This
# file is the one tested home for the *common* parser shape (id only,
# and id+type+read). Callers that need extra fields (self_heal captures
# content; escalation_watchdog captures timestamp + forwarded_at) keep
# their own parsers but are documented here as the rule-of-thumb
# implementation pattern.
#
# Decision (round-4 Task 2): the two specialized parsers in
# auto_prompt_self_heal.sh and escalation_watchdog.sh are the deliberate
# end state. A unified parse_inbox_full would have to emit six fields
# (id, type, read, timestamp, forwarded_at, content-with-multiline-fold)
# just so each caller can `cut` what it needs — that's complexity smuggled
# back in. Each specialized parser is ~10 lines, uses the flush() pattern,
# and now has a multi-entry regression test (TC-APR-11 + the new
# multi-entry case in test_escalation_watchdog.bats) that locks the
# flush()-on-new-entry behavior. If a future caller needs all six fields,
# revisit this decision; until then, do not extract a unified helper.
#
# Usage:
#   source scripts/lib/parse_inbox.sh
#   parse_inbox_ids     queue/inbox/shogun.yaml   # one msg_id per line
#   parse_inbox_entries queue/inbox/shogun.yaml   # id\ttype\tread per line
#
# Both functions use the flush()-on-new-entry pattern (not blank-line
# or END-only) because inbox entries are written back-to-back with no
# blank line between them. The previous END-only variants were the
# root cause of both the round-1 and round-2 defects.

parse_inbox_ids() {
    local inbox_path="${1:-}"
    [[ -z "$inbox_path" || ! -f "$inbox_path" ]] && return 0
    awk '
        function flush() { if (cur_id != "") print cur_id }
        /^- content:/ { flush(); in_entry = 1; cur_id = ""; next }
        in_entry && /^  id:/ { sub(/^  id: */, ""); cur_id = $0; next }
        in_entry && /^- /   { in_entry = 0; next }
        END                   { flush() }
    ' "$inbox_path"
}

parse_inbox_entries() {
    local inbox_path="${1:-}"
    [[ -z "$inbox_path" || ! -f "$inbox_path" ]] && return 0
    awk '
        function flush() {
            if (cur_id != "" && cur_type != "" && cur_read != "")
                print cur_id "\t" cur_type "\t" cur_read
        }
        /^- content:/ { flush(); in_entry = 1; cur_type = ""; cur_id = ""; cur_read = ""; next }
        in_entry && /^  id:/   { sub(/^  id: */, "");   cur_id   = $0; next }
        in_entry && /^  type:/ { sub(/^  type: */, ""); cur_type = $0; next }
        in_entry && /^  read:/ { sub(/^  read: */, ""); cur_read = $0; next }
        in_entry && /^- /     { in_entry = 0; next }
        END                    { flush() }
    ' "$inbox_path"
}
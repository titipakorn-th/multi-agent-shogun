#!/usr/bin/env bats
# test_auto_prompt_action.bats — unit tests for scripts/lib/auto_prompt_resolve_action.sh
#
# Coverage (per plan §cmd_036 PART D):
#   TC-APR-01: (Recommended) marker present → exit 0, stdout = option text
#   TC-APR-02: no (Recommended) marker → exit 2, stderr "no_recommended: <N>"
#   TC-APR-03: malformed CHOICES line → exit 3, stderr "parse_error:"
#   TC-APR-04: multi-line option bodies with embedded newlines → handled
#
# Also: source-style invocation (the way Shogun actually calls it).

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HELPER="$PROJECT_ROOT/scripts/lib/auto_prompt_resolve_action.sh"
    TEST_FIXTURES_DIR="$(mktemp -d "$BATS_TMPDIR/auto_prompt_action.XXXXXX")"
    # shellcheck disable=SC1090
    source "$HELPER"
}

teardown() {
    rm -rf "$TEST_FIXTURES_DIR"
}

# Helper: write an action_required fixture to a file in the temp dir.
write_fixture() {
    local filename="$1"
    local body="$2"
    printf '%s\n' "$body" > "$TEST_FIXTURES_DIR/$filename"
}

@test "TC-APR-01: action_required with (Recommended) marker exits 0 and returns option text" {
    write_fixture "tc01.txt" \
        "ACTION_REQUIRED: choose a deployment | CHOICES: (a) staging, (b) production (Recommended), (c) cancel"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc01.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "production" ]
}

@test "TC-APR-02: action_required WITHOUT (Recommended) marker exits 2 with no_recommended" {
    write_fixture "tc02.txt" \
        "ACTION_REQUIRED: choose a deployment | CHOICES: (a) staging, (b) production, (c) cancel"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc02.txt"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "no_recommended: 3 choices parsed" ]]
}

@test "TC-APR-03: malformed CHOICES line exits 3 with parse_error" {
    write_fixture "tc03.txt" \
        "ACTION_REQUIRED: bad input | CHOICES::: garbage [unclosed"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc03.txt"
    [ "$status" -eq 3 ]
    [[ "$output" =~ "parse_error:" ]]
}

@test "TC-APR-04: multi-line option body with embedded newline is folded into resolution" {
    write_fixture "tc04.txt" \
        "ACTION_REQUIRED: pick | CHOICES: (a) option-a-text
continued-line (Recommended), (b) other"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc04.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "option-a-text continued-line" ]
}

@test "TC-APR-05: missing input file exits 3 with parse_error" {
    local nonexistent="$TEST_FIXTURES_DIR/does-not-exist.txt"
    run auto_prompt_resolve_action "$nonexistent"
    [ "$status" -eq 3 ]
    [[ "$output" =~ "parse_error:" ]]
}

@test "TC-APR-06: stdin invocation works (sourced style)" {
    write_fixture "tc06.txt" \
        "ACTION_REQUIRED: choose | CHOICES: (a) low, (b) high (Recommended), (c) off"

    run bash -c "source '$HELPER' && cat '$TEST_FIXTURES_DIR/tc06.txt' | auto_prompt_resolve_action"
    [ "$status" -eq 0 ]
    [ "$output" = "high" ]
}

@test "TC-APR-07: multi-choice with embedded parens in option text" {
    # Edge case: option (a) text contains parentheses "(Recommended)" inside the
    # option body itself. The parser must identify "(Recommended)" as the marker
    # by anchoring on the LAST closing paren of the recommended option, not a
    # paren that appears inside option text. Returns the option text minus the
    # marker.
    write_fixture "tc07.txt" \
        "ACTION_REQUIRED: pick a feature | CHOICES: (a) audit-log preview (Recommended), (b) full diff preview with side-by-side compare"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc07.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "audit-log preview" ]
}

# ----- TC-APR-08..10: self_heal_inbox (cmd_039) -------------------------------

# Helper: stage a minimal project root with queue/ + auto_prompt_state.yaml.
stage_self_heal_root() {
    local root
    root=$(mktemp -d "$BATS_TMPDIR/proj.XXXXXX")
    mkdir -p "$root/queue/inbox"
    # Minimal state file — helper increments dispatches_this_session.
    printf 'dispatches_this_session: 0\nlast_reset_at: "2026-06-23T01:50:00+00:00"\nsession_id: "manual_init"\n' \
        > "$root/queue/auto_prompt_state.yaml"
    echo "$root"
}

# Helper: write a single-entry inbox YAML.
write_self_heal_inbox() {
    local inbox_path="$1"
    local entry_type="$2"      # "action_required" | "report_completed"
    local read_state="$3"      # "true" | "false"
    local body="$4"
    cat > "$inbox_path" <<YAML
messages:
- content: '${body}'
  from: orchestrator
  id: msg_test_$(date +%s%N | tail -c 7)
  read: ${read_state}
  timestamp: '2026-06-23T01:50:00+00:00'
  type: ${entry_type}
YAML
}

@test "TC-APR-08: read:true action_required WITHOUT resolution → helper resolves it" {
    local root; root=$(stage_self_heal_root)
    local inbox="$root/queue/inbox/shogun.yaml"
    write_self_heal_inbox "$inbox" "action_required" "true" \
        "ACTION_REQUIRED: pick | CHOICES: (a) low, (b) high (Recommended), (c) off"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/scripts/lib/auto_prompt_self_heal.sh"
    cd "$root"
    run self_heal_inbox "$inbox"
    cd "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "resolved=1" ]]
    [[ "$output" =~ "(b) high" ]]

    # Resolution file written with required JSON fields.
    local res_file
    res_file=$(ls "$root/queue/" | grep '^current_question_msg_test_' | head -1)
    [ -n "$res_file" ]
    [ -f "$root/queue/$res_file" ]
    run cat "$root/queue/$res_file"
    [[ "$output" =~ '"status": "answered"' ]]
    [[ "$output" =~ '"resolved_by": "auto_prompt"' ]]
    [[ "$output" =~ '"session_id": "shogun-self-heal"' ]]

    # State counter incremented from 0 → 1.
    run cat "$root/queue/auto_prompt_state.yaml"
    [[ "$output" =~ "dispatches_this_session: 1" ]]
}

@test "TC-APR-09: read:true action_required WITH resolution → idempotent skip" {
    local root; root=$(stage_self_heal_root)
    local inbox="$root/queue/inbox/shogun.yaml"
    write_self_heal_inbox "$inbox" "action_required" "true" \
        "ACTION_REQUIRED: pick | CHOICES: (a) low, (b) high (Recommended), (c) off"

    # Pre-create resolution file matching the source_message_id format.
    local res_file="$root/queue/current_question_msg_test_pre.json"
    cat > "$res_file" <<JSON
{"status": "answered", "response": "high", "resolved_by": "auto_prompt", "source_message_id": "msg_test_pre"}
JSON

    # Add a second entry pointing at the pre-created file's id.
    cat >> "$inbox" <<YAML
- content: 'ACTION_REQUIRED: pick | CHOICES: (a) low, (b) high (Recommended), (c) off'
  from: orchestrator
  id: msg_test_pre
  read: true
  timestamp: '2026-06-23T01:50:00+00:00'
  type: action_required
YAML

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/scripts/lib/auto_prompt_self_heal.sh"
    cd "$root"
    run self_heal_inbox "$inbox"
    cd "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "resolved=0" ]]

    # State counter NOT incremented (still 0).
    run cat "$root/queue/auto_prompt_state.yaml"
    [[ "$output" =~ "dispatches_this_session: 0" ]]

    # Pre-existing resolution file untouched.
    run cat "$res_file"
    [[ "$output" =~ '"response": "high"' ]]
}

@test "TC-APR-10: type:report_completed read:true → skipped, not action_required" {
    local root; root=$(stage_self_heal_root)
    local inbox="$root/queue/inbox/shogun.yaml"
    write_self_heal_inbox "$inbox" "report_completed" "true" \
        "cmd_038 SHIPPED at 01:38:10 (commit e5c6739)."

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/scripts/lib/auto_prompt_self_heal.sh"
    cd "$root"
    run self_heal_inbox "$inbox"
    cd "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "resolved=0" ]]

    # No resolution file created.
    local count
    count=$(ls "$root/queue/" 2>/dev/null | grep '^current_question_msg_test_' 2>/dev/null | wc -l | tr -d ' ')
    [ "$count" -eq 0 ]

    # State counter NOT incremented.
    run cat "$root/queue/auto_prompt_state.yaml"
    [[ "$output" =~ "dispatches_this_session: 0" ]]
}

# TC-APR-11: Round-4 regression guard for self_heal's specialized parser.
# The handler captures `content` (multi-line YAML scalar) and emits id\tbody
# only when type=action_required AND read=true. If this parser silently
# reverts to an END-only emit (the round-1/round-2 defect), the buried
# action_required below would not be acted on. This test reproduces the
# exact shape: target entry FIRST, unrelated report_completed LAST.
@test "TC-APR-11: buried action_required (NOT last) is still resolved" {
    local root; root=$(stage_self_heal_root)
    local inbox="$root/queue/inbox/shogun.yaml"
    cat > "$inbox" <<'YAML'
messages:
- content: 'ACTION_REQUIRED: pick | CHOICES: (a) low, (b) high (Recommended), (c) off'
  from: orchestrator
  id: msg_buried_action
  read: true
  timestamp: '2026-06-23T01:50:00+00:00'
  type: action_required
- content: 'cmd_038 SHIPPED at 01:38:10.'
  from: orchestrator
  id: msg_trailing_report
  read: true
  timestamp: '2026-06-23T01:50:01+00:00'
  type: report_completed
YAML
    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/scripts/lib/auto_prompt_self_heal.sh"
    cd "$root"
    run self_heal_inbox "$inbox"
    cd "$PROJECT_ROOT"
    [ "$status" -eq 0 ]
    # Buried action_required MUST be resolved despite the trailing entry.
    [[ "$output" =~ "resolved=1" ]]
    [[ "$output" =~ "msg_buried_action" ]]
    [[ "$output" =~ "(b) high" ]]

    # Resolution file written for the buried entry.
    [ -f "$root/queue/current_question_msg_buried_action.json" ]

    # State counter incremented from 0 → 1.
    run cat "$root/queue/auto_prompt_state.yaml"
    [[ "$output" =~ "dispatches_this_session: 1" ]]
}
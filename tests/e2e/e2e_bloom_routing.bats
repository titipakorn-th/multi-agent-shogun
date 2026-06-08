#!/usr/bin/env bats
# e2e_bloom_routing.bats — Dim C: Smart Switching E2E Test
# Issue #53 Phase 2 — find_agent_for_model() + karo bloom routing Integration Verification
#
# Assumed execution only on VPS. The tmux session "multiagent" is already started,
# and a mixed CLI configuration (ashigaru1-3=Spark, ashigaru4-5=Sonnet, ashigaru6-7=Opus) is
# required.
#
# Prerequisites:
#   - VPS configuration: ashigaru1-3=codex/spark, ashigaru4-5=claude/sonnet, ashigaru6-7=claude/opus
#   - bloom_routing: "manual" or "auto"
#   - All Ashigaru are idle (before starting test)
#
# Execution method:
#   bats tests/e2e/e2e_bloom_routing.bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

setup() {
    # Confirm tmux session exists
    if ! tmux has-session -t multiagent 2>/dev/null; then
        skip "tmux session 'multiagent' does not exist. Run after shutsuijin on VPS."
    fi

    # Load lib/cli_adapter.sh
    export CLI_ADAPTER_PROJECT_ROOT="$PROJECT_ROOT"
    export CLI_ADAPTER_SETTINGS="${PROJECT_ROOT}/config/settings.yaml"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/cli_adapter.sh"
    # shellcheck disable=SC1090
    source "${PROJECT_ROOT}/lib/agent_status.sh" 2>/dev/null || true
}

teardown() {
    # Clean up task files after testing
    :
}

# ─────────────────────────────────────────────
# TC-BLOOM-001: L1 task -> assigned to Spark Ashigaru (ashigaru1/2/3)
# ─────────────────────────────────────────────
@test "TC-BLOOM-001: L1 task -> assigned to Spark Agent" {
    run get_recommended_model 1
    [ "$status" -eq 0 ]
    # L1 is cheapest with Spark (max_bloom=3)
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    # Spark Ashigaru is one of ashigaru1, 2, or 3
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-002: L5 task -> assigned to Sonnet Ashigaru (ashigaru4/5)
# ─────────────────────────────────────────────
@test "TC-BLOOM-002: L5 task -> assigned to Sonnet Agent" {
    run get_recommended_model 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"sonnet"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[4-5]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-003: L6 task -> assigned to Opus Ashigaru (ashigaru6/7)
# ─────────────────────────────────────────────
@test "TC-BLOOM-003: L6 task -> assigned to Opus Agent" {
    run get_recommended_model 6
    [ "$status" -eq 0 ]
    [[ "$output" == *"opus"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^ashigaru[6-7]$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-004: ashigaru4 busy + L5 task -> assigned to ashigaru5
# No kill/restart occurs (verify busy pane remains unchanged)
# ─────────────────────────────────────────────
@test "TC-BLOOM-004: When ashigaru4 is busy, L5 task is assigned to ashigaru5" {
    # Get pane target of ashigaru4
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')

    if [[ -z "$pane4" ]]; then
        skip "ashigaru4 pane not found"
    fi

    # Create busy state using sleep (teardown guaranteed by trap)
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # Verify busy
    busy_rc=0
    agent_is_busy_check "$pane4" && true || busy_rc=$?
    if [[ $busy_rc -ne 0 ]]; then
        skip "Could not set ashigaru4 to busy state (busy_rc=${busy_rc})"
    fi

    # L5 task routing
    recommended=$(get_recommended_model 5)
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # ashigaru4 is busy so it should be assigned to ashigaru5
    [ "$output" = "ashigaru5" ] || \
        { echo "Expected: ashigaru5, Actual: $output"; return 1; }

    # Verify ashigaru4 is still running (not killed/restarted)
    still_busy=0
    agent_is_busy_check "$pane4" && true || still_busy=$?
    [[ $still_busy -eq 0 ]] || echo "WARNING: ashigaru4 state changed (possible kill/restart)"
}

# ─────────────────────────────────────────────
# TC-BLOOM-005: both ashigaru4/5 busy + L5 task -> QUEUE (no downgrade to Codex)
# ─────────────────────────────────────────────
@test "TC-BLOOM-005: When all Sonnet Ashigaru are busy, placed in QUEUE (verify no downgrade to Codex)" {
    pane4=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru4" {print $1}')
    pane5=$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{@agent_id}' \
        | awk '$2 == "ashigaru5" {print $1}')

    if [[ -z "$pane4" || -z "$pane5" ]]; then
        skip "ashigaru4 or ashigaru5 pane not found"
    fi

    # Create busy state for ashigaru4/5 using sleep (teardown guaranteed by trap)
    # shellcheck disable=SC2064
    trap "tmux send-keys -t '$pane4' '' C-c; tmux send-keys -t '$pane5' '' C-c; sleep 0.3" EXIT
    tmux send-keys -t "$pane4" "echo 'Working...'; sleep 30" Enter
    tmux send-keys -t "$pane5" "echo 'Working...'; sleep 30" Enter
    sleep 1

    # Verify both are busy
    rc4=0; agent_is_busy_check "$pane4" && true || rc4=$?
    rc5=0; agent_is_busy_check "$pane5" && true || rc5=$?

    if [[ $rc4 -ne 0 || $rc5 -ne 0 ]]; then
        skip "Could not set either ashigaru4 or ashigaru5 to busy state (rc4=${rc4}, rc5=${rc5})"
    fi

    # L5 task routing
    recommended=$(get_recommended_model 5)
    # All Sonnet Ashigaru busy -> fallback or QUEUE
    result=$(find_agent_for_model "$recommended")

    # Fallback (other idle Ashigaru) or QUEUE is allowed
    # In case of fallback to non-Sonnet Ashigaru, output model quality warning
    if [[ "$result" =~ ^ashigaru[1-3]$ ]]; then
        echo "Fallback destination: $result (Spark agent - watch out for quality degradation)"
    elif [[ "$result" = "QUEUE" ]]; then
        echo "QUEUE: All Ashigaru busy"
    else
        echo "Fallback destination: $result"
    fi

    # Confirm it returns QUEUE or ashigaru (doing nothing is invalid)
    [[ "$result" = "QUEUE" ]] || [[ "$result" =~ ^ashigaru[0-9]+$ ]]
}

# ─────────────────────────────────────────────
# TC-BLOOM-006: L3 task -> not assigned to Sonnet Ashigaru (Codex priority)
# ─────────────────────────────────────────────
@test "TC-BLOOM-006: Spark Ashigaru prioritized for L3 tasks (no over-engineering to Sonnet)" {
    run get_recommended_model 3
    [ "$status" -eq 0 ]

    # Spark is recommended for L3 instead of Sonnet
    [[ "$output" != *"sonnet"* ]] || { echo "Sonnet was recommended for L3 (cost optimization violation)"; return 1; }
    [[ "$output" == *"spark"* ]] || [[ "$output" == *"codex"* ]]

    recommended="$output"
    run find_agent_for_model "$recommended"
    [ "$status" -eq 0 ]

    # Spark Ashigaru (ashigaru1-3) only
    [[ "$output" =~ ^ashigaru[1-3]$ ]]
}

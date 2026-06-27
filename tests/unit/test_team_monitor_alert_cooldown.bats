#!/usr/bin/env bats
# test_team_monitor_alert_cooldown.bats — regression guard for the STALLED
# alert cooldown. The bug: alert_key was md5(agent_id+msg); the STALLED msg
# includes the live `staleness` counter that increments every poll, so the
# key changed every poll, so the 600s cooldown never applied, so a single
# stall produced ~20 alerts.
#
# The fix: send_alert takes an optional stable category_key argument; the
# STALLED call site passes `STALLED:<session_basename>:<task_status>`, which
# is stable across polls.
#
# These tests guard against the regression by exercising the cooldown gate
# directly with messages that differ only in volatile content. They also
# verify the OTHER alert types (which use the legacy md5(agent_id+msg) path
# because their messages are stable) still work as before.
#
# Acceptance per plan §Task 2:
#   - "two alerts within the cooldown window with messages that differ ONLY
#      in the elapsed seconds" → exactly ONE fires.
#   - Stable-message alerts still emit one per key (no regression).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPTS_DIR="$REPO_ROOT/scripts"
    TEST_TMP="$(mktemp -d /tmp/tm_cd.XXXXXX)"
    export HOME="$TEST_TMP"
    mkdir -p "$TEST_TMP/queue/metrics"
    mkdir -p "$TEST_TMP/scripts"
    # Copy the real inbox_write.sh + ntfy.sh mocks so team_monitor's send_alert
    # can call them without side-effects.
    cat > "$TEST_TMP/scripts/inbox_write.sh" <<SH
#!/usr/bin/env bash
echo "\$@" >> "${TEST_TMP}/inbox_calls.log"
SH
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # Extract the alert helper functions (alert_key/should_alert/mark_alerted/
    # send_alert) from team_monitor.sh so we can test them in isolation without
    # triggering the main dispatch (which requires tmux + config).
    # ponytail: copy the helper block via a sed range that captures the
    # alert-related functions and stops before the "Main dispatch" header.
    sed -n '/^alert_key()/,/^# ─── Main dispatch/p' \
        "$SCRIPTS_DIR/team_monitor.sh" \
        | sed '/^# ─── Main dispatch/,$d' \
        > "$TEST_TMP/alert_helpers.sh"

    # Override paths to hermetic temp locations before sourcing.
    {
        echo "SCRIPT_DIR=\"$TEST_TMP/scripts\""
        echo "PROJECT_ROOT=\"$TEST_TMP\""
        echo "PROJECT_NAME=\"tm_cd_test\""
        echo "ALERT_STATE_DIR=\"$TEST_TMP/alert_state\""
        echo "ALERT_LOG=\"$TEST_TMP/queue/metrics/team_monitor_alerts.log\""
        cat "$TEST_TMP/alert_helpers.sh"
    } > "$TEST_TMP/team_monitor_helpers.sh"

    # shellcheck disable=SC1090
    source "$TEST_TMP/team_monitor_helpers.sh"

    # Short cooldown so the test runs fast; only matters for replay tests.
    export ALERT_COOLDOWN=60
    # Re-source state dir with the override honored — the helpers read
    # ALERT_STATE_DIR lazily via global, but it was already substituted
    # by the wrapper. Reset to a clean empty dir for each test.
    rm -rf "$ALERT_STATE_DIR"
    mkdir -p "$ALERT_STATE_DIR"
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: count alert log lines.
count_alerts() {
    [ -f "$ALERT_LOG" ] && wc -l < "$ALERT_LOG" | tr -d ' ' || echo 0
}

@test "STALLED: same incident across multiple polls emits exactly ONE alert (the bug guard)" {
    # Same session, same task_status — only staleness counter changes.
    # Before the fix this would produce ~20 alerts (one per poll). After
    # the fix the stable category_key collapses them.
    local session_file="abc123-def456.jsonl"
    local task_status="in_progress"
    local stable_key="STALLED:${session_file}:${task_status}"

    send_alert "oracle" "STALLED 611s (threshold=600s, task=$task_status, session=$session_file)" "$stable_key"
    send_alert "oracle" "STALLED 622s (threshold=600s, task=$task_status, session=$session_file)" "$stable_key"
    send_alert "oracle" "STALLED 630s (threshold=600s, task=$task_status, session=$session_file)" "$stable_key"
    send_alert "oracle" "STALLED 1548s (threshold=600s, task=$task_status, session=$session_file)" "$stable_key"

    # Exactly one alert log line despite four send_alert calls.
    [ "$(count_alerts)" -eq 1 ]
    # Exactly one inbox write (this is the noisy channel — the inbox was
    # getting 12 near-duplicate oracle: STALLED alerts pre-fix).
    [ "$(grep -c . "$TEST_TMP/inbox_calls.log" 2>/dev/null || echo 0)" -eq 1 ]
    # The single alert's text contains seconds info ("current seconds"
    # per plan acceptance — the human-readable message still carries the
    # live staleness counter).
    grep -q "STALLED 611s" "$ALERT_LOG"
    grep -q "STALLED 611s" "$TEST_TMP/inbox_calls.log"
}

@test "STALLED: re-alert after cooldown window gets fresh text" {
    # First poll: alert fires with "611s" text.
    # Backdate the state file past ALERT_COOLDOWN.
    # Second poll: alert fires again with the NEW poll's text ("1548s").
    local stable_key="STALLED:s.jsonl:in_progress"
    local state_file="$ALERT_STATE_DIR/$(alert_key 'oracle' "$stable_key")"
    mkdir -p "$ALERT_STATE_DIR"

    send_alert "oracle" "STALLED 611s (session=s.jsonl)" "$stable_key"
    # Simulate elapsed cooldown by overwriting state with an old timestamp.
    echo "$(($(date +%s) - 700))" > "$state_file"
    send_alert "oracle" "STALLED 1548s (session=s.jsonl)" "$stable_key"

    [ "$(count_alerts)" -eq 2 ]
    # First alert text + second alert text both present.
    grep -q "STALLED 611s" "$ALERT_LOG"
    grep -q "STALLED 1548s" "$ALERT_LOG"
}

@test "STALLED: different session → distinct key → re-alerts (no over-collapse)" {
    # Two stalls in two different sessions are distinct incidents and must
    # both surface. Keying on session file prevents cross-incident suppression.
    send_alert "oracle" "STALLED 700s (threshold=600s, task=in_progress, session=session-A.jsonl)" "STALLED:session-A.jsonl:in_progress"
    send_alert "oracle" "STALLED 700s (threshold=600s, task=in_progress, session=session-B.jsonl)" "STALLED:session-B.jsonl:in_progress"

    [ "$(count_alerts)" -eq 2 ]
}

@test "STALLED: task status transition re-alerts (key includes task_status)" {
    # Same session, but task moved from assigned → in_progress. Distinct
    # incident states; both should surface.
    send_alert "oracle" "STALLED 700s (session=s.jsonl, task=assigned)"     "STALLED:s.jsonl:assigned"
    send_alert "oracle" "STALLED 700s (session=s.jsonl, task=in_progress)"  "STALLED:s.jsonl:in_progress"

    [ "$(count_alerts)" -eq 2 ]
}

@test "STALLED: alert cooldown still applies (re-alert after window)" {
    # Manually backdate the state file to simulate elapsed cooldown.
    local stable_key="STALLED:session-X.jsonl:in_progress"
    local state_file="$ALERT_STATE_DIR/$(alert_key 'oracle' "$stable_key")"
    echo "$(($(date +%s) - 700))" > "$state_file"   # 700s ago, beyond ALERT_COOLDOWN=60

    send_alert "oracle" "STALLED 1500s (session=session-X.jsonl)" "$stable_key"
    [ "$(count_alerts)" -eq 1 ]
}

@test "non-STALLED alerts: stable message still produces one alert (no regression on legacy path)" {
    # The PANE-MISSING / PANE-DEAD / SHELL-PROCESS-DEAD / AGENT-NOT-RUNNING
    # call sites don't pass category_key; they rely on the legacy
    # md5(agent_id+msg) path because their messages are already stable
    # (pane target + pid change less often than staleness). This test
    # guards the legacy path is untouched.
    send_alert "shogun" "PANE MISSING (tmux target 'multiagent:ops.0' not found)"
    send_alert "shogun" "PANE MISSING (tmux target 'multiagent:ops.0' not found)"

    [ "$(count_alerts)" -eq 1 ]
}

@test "alert_key: same inputs → same key (deterministic)" {
    local k1; k1=$(alert_key "oracle" "STALLED:s.jsonl:in_progress")
    local k2; k2=$(alert_key "oracle" "STALLED:s.jsonl:in_progress")
    [ "$k1" = "$k2" ]
}

@test "alert_key: different agent → different key" {
    local k1; k1=$(alert_key "oracle"   "STALLED:s.jsonl:in_progress")
    local k2; k2=$(alert_key "explorer" "STALLED:s.jsonl:in_progress")
    [ "$k1" != "$k2" ]
}
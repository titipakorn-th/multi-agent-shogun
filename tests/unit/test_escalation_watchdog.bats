#!/usr/bin/env bats
# test_escalation_watchdog.bats — verify scripts/lib/escalation_watchdog.sh (cmd_068).
# Belt-and-suspenders: when orchestrator step 18 misses writing
# current_question.json + firing ntfy.sh on action_required, the listener
# calls this watchdog every loop and forwards stale unread entries.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMP="$(mktemp -d /tmp/esc_wd.XXXXXX)"
    export HOME="$TEST_TMP"

    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue" "$TEST_TMP/scripts/lib" "$TEST_TMP/config"

    # settings.yaml — telegram.mode on by default.
    cat > "$TEST_TMP/config/settings.yaml" <<'YAML'
telegram:
  mode: on
YAML

    # Copy the real watchdog into the sandbox.
    cp "$REPO_ROOT/scripts/lib/escalation_watchdog.sh" "$TEST_TMP/scripts/lib/"
    chmod +x "$TEST_TMP/scripts/lib/escalation_watchdog.sh"

    # Fake ntfy.sh that just logs.
    cat > "$TEST_TMP/scripts/ntfy.sh" <<SH
#!/usr/bin/env bash
echo "\$1" >> "${TEST_TMP}/marker_ntfy.log"
SH
    chmod +x "$TEST_TMP/scripts/ntfy.sh"

    cd "$TEST_TMP"
}

teardown() {
    rm -rf "$TEST_TMP"
}

stale_ts() {
    # 2 minutes ago, ISO-8601 with +00:00 (date on macOS understands this).
    date -u -v-2M '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null || \
    date -u -d '2 minutes ago' '+%Y-%m-%dT%H:%M:%S+00:00'
}

fresh_ts() {
    date -u -v-10S '+%Y-%m-%dT%H:%M:%S+00:00' 2>/dev/null || \
    date -u -d '10 seconds ago' '+%Y-%m-%dT%H:%M:%S+00:00'
}

seed_inbox() {
    cat > queue/inbox/shogun.yaml <<YAML
messages:
- content: 'cmd_test — question for Lord'
  from: orchestrator
  id: msg_stale_001
  read: false
  timestamp: '${1}'
  type: action_required$([ -n "$2" ] && echo "
  forwarded_at: \"$2\"")
YAML
}

@test "writes ntfy on stale action_required" {
    seed_inbox "$(stale_ts)"
    run bash scripts/lib/escalation_watchdog.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/marker_ntfy.log" ]
    grep -q "msg_stale_001" "$TEST_TMP/marker_ntfy.log"
    grep -q "forwarded_at" queue/inbox/shogun.yaml
}

@test "silent on fresh action_required (<60s)" {
    seed_inbox "$(fresh_ts)"
    run bash scripts/lib/escalation_watchdog.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_ntfy.log" ]
    ! grep -q "forwarded_at" queue/inbox/shogun.yaml
}

@test "silent on telegram.mode=off" {
    sed -i '' 's/mode: on/mode: off/' config/settings.yaml
    seed_inbox "$(stale_ts)"
    run bash scripts/lib/escalation_watchdog.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_ntfy.log" ]
    # Verify watchdog did NOT add forwarded_at (mode=off short-circuits before parse).
    ! grep -q "forwarded_at" queue/inbox/shogun.yaml
}

@test "idempotent on replay (forwarded_at present → no second ntfy)" {
    seed_inbox "$(stale_ts)" "2026-06-24T02:00:00+00:00"
    run bash scripts/lib/escalation_watchdog.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_ntfy.log" ]
}

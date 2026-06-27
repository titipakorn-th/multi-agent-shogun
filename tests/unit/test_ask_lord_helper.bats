#!/usr/bin/env bats
# test_ask_lord_helper.bats — unit tests for scripts/ask_lord.sh, the
# thin convenience wrapper around lord_ask.sh.
#
# Plan: 2026-06-27-telegram-bidirectional-ask-assessment.md (Task 3).
# Verifies:
#   - exit-code contract (0/1/3/4) is preserved from lord_ask.sh
#   - usage error on missing args
#   - timeout emits the default (ASK_LORD_DEFAULT)
#   - tag forwarding works (does not appear in output, just in CLI)
# Uses a fake lord_ask.sh to keep tests hermetic (no Telegram, no flock).

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMP="$(mktemp -d /tmp/ask_lord.XXXXXX)"
    export HOME="$TEST_TMP"

    # Stage the real ask_lord.sh.
    cp "$REPO_ROOT/scripts/ask_lord.sh" "$TEST_TMP/ask_lord.sh"
    chmod +x "$TEST_TMP/ask_lord.sh"

    # Build a fake lord_ask.sh that honors a sentinel env knob for the
    # desired behavior. The wrapper calls lord_ask.sh with --timeout and
    # the rest of the args verbatim; the fake just reads $FAKE_LORD_BEHAVIOR.
    # stdout is the answer (what the wrapper captures); any debug goes to a
    # sentinel file (since the wrapper redirects stderr to /dev/null).
    cat > "$TEST_TMP/lord_ask.sh" <<'SH'
#!/usr/bin/env bash
# fake lord_ask.sh — behavior controlled by $FAKE_LORD_BEHAVIOR.
# Supported values: answer, timeout, busy, stderr
DEBUG_LOG="${FAKE_LORD_DEBUG_LOG:-/tmp/ask_lord_dbg.log}"
case "${FAKE_LORD_BEHAVIOR:-answer}" in
    answer)
        echo "ARGS: $*" >> "$DEBUG_LOG"
        if [[ " $* " =~ " --tag " ]]; then
            echo "TAG_FORWARDED" >> "$DEBUG_LOG"
        fi
        echo "${FAKE_LORD_ANSWER:-Yes}"
        exit 0
        ;;
    timeout)
        echo "no answer; proceeding with default assumption" >&2
        exit 3
        ;;
    busy)
        echo "lord_ask: another Lord question is already pending" >&2
        exit 4
        ;;
    stderr)
        echo "send to Telegram failed" >&2
        exit 5
        ;;
esac
SH
    chmod +x "$TEST_TMP/lord_ask.sh"

    # Point the wrapper at our fake.
    sed -i '' "s|LORD_ASK=.*|LORD_ASK=\"$TEST_TMP/lord_ask.sh\"|" "$TEST_TMP/ask_lord.sh"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "answered: stdout is the selected option, exit 0" {
    FAKE_LORD_BEHAVIOR=answer FAKE_LORD_ANSWER="Yes (Recommended)" \
        run "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 0 ]
    [ "$output" = "Yes (Recommended)" ]
}

@test "timeout: stdout is empty (default), exit 3" {
    FAKE_LORD_BEHAVIOR=timeout \
        run env ASK_LORD_DEFAULT="" "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "timeout with default: stdout is the default, exit 3" {
    FAKE_LORD_BEHAVIOR=timeout \
        run env ASK_LORD_DEFAULT="(A) restart per cmd_092n" \
        "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 3 ]
    [ "$output" = "(A) restart per cmd_092n" ]
}

@test "busy: exit 4 propagated, distinct from timeout" {
    FAKE_LORD_BEHAVIOR=busy \
        run "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 4 ]
}

@test "real failure (e.g. Telegram send fail): exit 5 propagated" {
    FAKE_LORD_BEHAVIOR=stderr \
        run "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 5 ]
}

@test "tag forwarded to lord_ask.sh (visible to caller's CLI)" {
    # The wrapper passes --tag through to lord_ask.sh. The fake records the
    # observed args to a sentinel file (ask_lord.sh swallows stderr, so we
    # verify forwarding via a side-channel rather than stdout/stderr capture).
    local dbg_log="$TEST_TMP/tag_dbg.log"
    : > "$dbg_log"
    FAKE_LORD_BEHAVIOR=answer FAKE_LORD_ANSWER="Yes" FAKE_LORD_DEBUG_LOG="$dbg_log" \
        "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No" --tag "orchestrator · cmd_104" \
        >/dev/null 2>&1
    # The wrapper preserved the --tag arg on its way to the fake.
    grep -q -- "--tag" "$dbg_log"
    grep -q "orchestrator · cmd_104" "$dbg_log"
    grep -q "TAG_FORWARDED" "$dbg_log"
}

@test "usage error: missing args → exit 1" {
    run "$TEST_TMP/ask_lord.sh"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Usage:"* ]]
}

@test "wrapper handles missing lord_ask.sh gracefully" {
    # Point at a non-existent path.
    sed -i '' "s|LORD_ASK=.*|LORD_ASK=\"$TEST_TMP/does_not_exist.sh\"|" "$TEST_TMP/ask_lord.sh"
    run "$TEST_TMP/ask_lord.sh" "Restart?" "Yes" "No"
    [ "$status" -eq 1 ]
}
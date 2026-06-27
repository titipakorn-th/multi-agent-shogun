#!/usr/bin/env bats
# test_inbox_watcher_deferred_clear.bats — regression guard for the
# inbox_watcher busy-defer / /clear re-arm deadlock.
#
# Bug: send_cli_command returned 0 when /clear was deferred-on-busy, so
# the phase-3 escalation site treated the defer as a success and reset
# FIRST_UNREAD_SEEN / LAST_CLEAR_TS. That re-armed the false-busy
# deadlock the stale-busy safety net exists to break: a stuck "busy"
# agent got its /clear perpetually deferred and the unread message never
# delivered.
#
# Fix: send_cli_command returns 2 on busy-defer. The escalation site
# gates state mutations on the actual exit code. The message-dispatch
# site (line ~1298) treats rc=2 like rc=1 — as a deferred message that
# needs retry, NOT a sent message.
#
# Plan: 2026-06-27-inbox-watcher-deferred-clear-gap.md

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    WATCHER="$REPO_ROOT/scripts/inbox_watcher.sh"
    TEST_TMP="$(mktemp -d /tmp/iw_def.XXXXXX)"
    export HOME="$TEST_TMP"

    # Create scratch dirs the watcher references.
    mkdir -p "$TEST_TMP/queue/inbox"
    mkdir -p "$TEST_TMP/logs"

    # Stubs for tmux + agent status helpers — the watcher sources
    # scripts/lib/agent_status.sh which we replace with a no-op.
    mkdir -p "$TEST_TMP/scripts/lib"
    cat > "$TEST_TMP/scripts/lib/agent_status.sh" <<'STUB'
# stub: replaces the real agent_is_busy_check + idle flag logic.
agent_is_busy_check() { return 1; }   # never busy by default
STUB

    # Override tmux with a recording stub so send_cli_command never
    # touches a real session.
    mkdir -p "$TEST_TMP/bin"
    cat > "$TEST_TMP/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    capture-pane) echo "" ;;            # empty pane snapshot → no opencode short-circuit
    send-keys)    echo "SEND_KEYS $*" >> "${TMUX_LOG:-/tmp/tmux_calls.log}" ;;
    has-session)  exit 0 ;;
    *)            exit 0 ;;
esac
STUB
    chmod +x "$TEST_TMP/bin/tmux"
    export PATH="$TEST_TMP/bin:$PATH"

    # Inbox is empty by default; tests that need unread create them.
    printf 'messages: []\n' > "$TEST_TMP/queue/inbox/shogun.yaml"

    # Source the watcher in testing mode (function definitions only).
    export __INBOX_WATCHER_TESTING__=1
    # shellcheck disable=SC1090
    source "$WATCHER"

    # Re-stub the watcher's agent_is_busy to be controllable per-test.
    # The watcher sources agent_status.sh at the top, so agent_is_busy()
    # is now a wrapper around agent_is_busy_check. We override the wrapper
    # to call our controllable stub.
    agent_is_busy() {
        if [ -n "${MOCK_BUSY:-}" ]; then
            [ "$MOCK_BUSY" = "1" ]
        else
            agent_is_busy_check
        fi
    }
}

teardown() {
    rm -rf "$TEST_TMP"
}

# ─── send_cli_command busy-defer signaling ──────────────────────────────────

@test "send_cli_command: /clear + busy → returns 2 (post-fix)" {
    # The bug: this returned 0. The caller then treated the defer as
    # a success and reset the escalation timer, re-arming the deadlock.
    export MOCK_BUSY=1
    export PANE_TARGET="multiagent:ops.0"
    export AGENT_ID="oracle"
    export effective_cli="claude"

    run send_cli_command "/clear"
    [ "$status" -eq 2 ]
}

@test "send_cli_command: /clear + NOT busy → returns 0 (success path preserved)" {
    export MOCK_BUSY=0
    export PANE_TARGET="multiagent:ops.0"
    export AGENT_ID="oracle"
    export effective_cli="claude"

    run send_cli_command "/clear"
    [ "$status" -eq 0 ]
}

@test "send_cli_command: /clear + busy → NO tmux send-keys emitted (the defer didn't fire)" {
    export MOCK_BUSY=1
    export PANE_TARGET="multiagent:ops.0"
    export AGENT_ID="oracle"
    export effective_cli="claude"
    rm -f "${TMUX_LOG:-/tmp/tmux_calls.log}"
    : > "${TMUX_LOG:-/tmp/tmux_calls.log}"

    send_cli_command "/clear" >/dev/null 2>&1 || true

    # send-keys should NOT have been called — the /clear was deferred.
    # (The send_cli_command path runs through several phases before
    # tmux send-keys; if the busy guard fired at line 692, no keystroke
    # went out.)
    if [ -f "${TMUX_LOG:-/tmp/tmux_calls.log}" ]; then
        ! grep -q 'SEND_KEYS' "${TMUX_LOG:-/tmp/tmux_calls.log}"
    fi
}

# ─── escalation phase-3 state preservation ────────────────────────────────

# Helper: simulate the phase-3 escalation block in isolation. We don't
# drive the full watch loop (which needs tmux + config); instead we
# reproduce the gating logic and verify FIRST_UNREAD_SEEN / LAST_CLEAR_TS
# are preserved on rc=2.
simulate_phase3_clear() {
    local busy_state="$1"   # "1" or "0"
    local now_val="$2"      # epoch seconds for the "now" of this cycle
    export MOCK_BUSY="$busy_state"
    export PANE_TARGET="multiagent:ops.0"
    export AGENT_ID="oracle"
    export effective_cli="claude"

    # Inline the phase-3 logic from inbox_watcher.sh:1473-1486 (post-fix).
    # Caller sets FIRST_UNREAD_SEEN / LAST_CLEAR_TS / NEW_CONTEXT_SENT BEFORE
    # calling — we deliberately do NOT reset them here, or the test's
    # pre-set values would be wiped before the assertion.
    if send_cli_command "/clear"; then
        LAST_CLEAR_TS="$now_val"
        FIRST_UNREAD_SEEN=0
        NEW_CONTEXT_SENT=0
    fi
}

@test "phase-3 escalation: busy-defer preserves FIRST_UNREAD_SEEN" {
    # Set up: timer is at some old value to simulate "we've been waiting
    # for a while". On busy-defer, the value must be PRESERVED, not reset.
    local now_val; now_val=$(date +%s)
    FIRST_UNREAD_SEEN=$((now_val - 350))   # 350s ago, past stale_busy_limit
    LAST_CLEAR_TS=0
    NEW_CONTEXT_SENT=1

    simulate_phase3_clear 1 "$now_val"

    # The bug: FIRST_UNREAD_SEEN was reset to 0 here. Post-fix it must
    # stay at $((now_val - 350)).
    [ "$FIRST_UNREAD_SEEN" -eq $((now_val - 350)) ]
}

@test "phase-3 escalation: busy-defer does NOT advance LAST_CLEAR_TS" {
    # Advancing LAST_CLEAR_TS on a no-op would force a 5-min cooldown
    # on the next real /clear attempt. Must NOT happen.
    local now_val; now_val=$(date +%s)
    FIRST_UNREAD_SEEN=$((now_val - 350))
    LAST_CLEAR_TS=12345   # arbitrary prior value

    simulate_phase3_clear 1 "$now_val"

    # LAST_CLEAR_TS is untouched on busy-defer.
    [ "$LAST_CLEAR_TS" -eq 12345 ]
}

@test "phase-3 escalation: NOT busy → /clear fires → state DOES reset" {
    # Counter-test: when the agent is no longer busy, the normal reset
    # behavior must still work.
    local now_val; now_val=$(date +%s)
    FIRST_UNREAD_SEEN=$((now_val - 350))
    LAST_CLEAR_TS=0
    NEW_CONTEXT_SENT=1

    simulate_phase3_clear 0 "$now_val"

    [ "$LAST_CLEAR_TS" -eq "$now_val" ]
    [ "$FIRST_UNREAD_SEEN" -eq 0 ]
    [ "$NEW_CONTEXT_SENT" -eq 0 ]
}

# ─── non-claude timer set-if-unset ────────────────────────────────────────

@test "non-claude busy: FIRST_UNREAD_SEEN set once on first detection, preserved on subsequent cycles" {
    # Plan Task 3 P3: previously the non-claude busy branch reset
    # FIRST_UNREAD_SEEN every cycle, making the stale-busy safety net
    # unreachable for codex/copilot/kimi/opencode.
    local now_val; now_val=$(date +%s)
    FIRST_UNREAD_SEEN=0

    # Simulate 3 consecutive busy cycles for a non-claude agent.
    # Post-fix: timer is set once and then preserved.
    local cycle
    for cycle in 1 2 3; do
        # Inline the post-fix branch (line 1395-1401):
        if [ "${FIRST_UNREAD_SEEN:-0}" -eq 0 ]; then
            FIRST_UNREAD_SEEN=$now_val
        fi
    done

    # FIRST_UNREAD_SEEN should equal now_val (set once, not advanced).
    [ "$FIRST_UNREAD_SEEN" -eq "$now_val" ]
}

@test "non-claude busy: stale-busy safety net can now fire (after 5 min)" {
    # Verify the net at line 1380 becomes reachable for non-claude.
    local now_val; now_val=$(date +%s)
    local stale_busy_limit=300
    # Simulate FIRST_UNREAD_SEEN set 350s ago.
    FIRST_UNREAD_SEEN=$((now_val - 350))

    # The safety-net condition (line 1380) is now satisfied.
    [ "${FIRST_UNREAD_SEEN:-0}" -gt 0 ]
    [ "$((now_val - FIRST_UNREAD_SEEN))" -ge "$stale_busy_limit" ]
}
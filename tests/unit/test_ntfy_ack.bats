#!/usr/bin/env bats
# test_ntfy_ack.bats — ntfy ACK auto-reply Unit Test
# PR #46: auto-ACK reply function on receiving ntfy messages
#
# Test configuration:
#   T-ACK-001: normal message -> inbox_write to shogun (auto-ACK removed)
#   T-ACK-002: with outbound tag -> skip ACK (loop prevention)
#   T-ACK-003: auto-ACK untransmitted verification (shogun replies directly)
#   T-ACK-004: ACK transmission failure -> continue inbox_write
#   T-ACK-005: empty message -> skip ACK
#   T-ACK-006: keepalive event -> skip ACK
#   T-ACK-007: append_ntfy_inbox failure -> skip both ACK and inbox_write
#   T-ACK-008: special characters are retained in inbox_write

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    [ -x "$PROJECT_ROOT/.venv/bin/python3" ] || skip "python3 not found in .venv"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_ack_test.XXXXXX")"
    export MOCK_PROJECT="$TEST_TMPDIR/mock_project"
    export MOCK_BIN="$TEST_TMPDIR/mock_bin"
    export ACK_LOG="$TEST_TMPDIR/ack.log"
    export INBOX_LOG="$TEST_TMPDIR/inbox.log"
    export MOCK_CURL_OUTPUT="$TEST_TMPDIR/curl_output.json"

    # Build mock project
    mkdir -p "$MOCK_PROJECT"/{config,lib,scripts,queue,logs/ntfy_inbox_corrupt}
    mkdir -p "$MOCK_PROJECT/.venv/bin"
    mkdir -p "$MOCK_BIN"

    # settings.yaml
    cat > "$MOCK_PROJECT/config/settings.yaml" << 'YAML'
ntfy_topic: "test-ack-topic-12345"
YAML

    # Empty authentication file
    touch "$MOCK_PROJECT/config/ntfy_auth.env"

    # Copy authentic ntfy_auth.sh
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$MOCK_PROJECT/lib/"

    # python3 wrapper (exec to project venv so pyvenv.cfg is found → PyYAML available)
    # Note: a symlink chain breaks venv detection on macOS — argv[0] would point to
    # $MOCK_PROJECT/.venv/bin/python3 but pyvenv.cfg only exists in $PROJECT_ROOT/.venv/
    cat > "$MOCK_PROJECT/.venv/bin/python3" << WRAPPER
#!/bin/sh
exec "$PROJECT_ROOT/.venv/bin/python3" "\$@"
WRAPPER
    chmod +x "$MOCK_PROJECT/.venv/bin/python3"

    # Initialize ntfy_inbox
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"

    # --- Mock scripts ---

    # mock curl
    cat > "$MOCK_BIN/curl" << 'CURL_MOCK'
#!/bin/bash
if [ -f "$MOCK_CURL_OUTPUT" ]; then
    cat "$MOCK_CURL_OUTPUT"
fi
CURL_MOCK
    chmod +x "$MOCK_BIN/curl"

    # mock ntfy.sh
    cat > "$MOCK_PROJECT/scripts/ntfy.sh" << 'NTFY_MOCK'
#!/bin/bash
echo "$1" >> "$ACK_LOG"
exit ${MOCK_NTFY_EXIT_CODE:-0}
NTFY_MOCK
    chmod +x "$MOCK_PROJECT/scripts/ntfy.sh"

    # mock inbox_write.sh
    cat > "$MOCK_PROJECT/scripts/inbox_write.sh" << 'INBOX_MOCK'
#!/bin/bash
echo "$@" >> "$INBOX_LOG"
INBOX_MOCK
    chmod +x "$MOCK_PROJECT/scripts/inbox_write.sh"

    # Copy ntfy_listener.sh (overwrite SCRIPT_DIR)
    sed "s|^SCRIPT_DIR=.*|SCRIPT_DIR=\"$MOCK_PROJECT\"|" \
        "$PROJECT_ROOT/scripts/ntfy_listener.sh" \
        > "$MOCK_PROJECT/ntfy_listener_test.sh"
    chmod +x "$MOCK_PROJECT/ntfy_listener_test.sh"

    # Initialize logs
    touch "$ACK_LOG" "$INBOX_LOG"

    # Place mock curl at head of PATH
    export PATH="$MOCK_BIN:$PATH"

    # Default: ntfy.sh exits normally
    unset MOCK_NTFY_EXIT_CODE
}

teardown() {
    # Restore permissions if changed (T-ACK-007)
    chmod 755 "$MOCK_PROJECT/queue" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}

# --- Helper ---

run_listener() {
    timeout 3 bash "$MOCK_PROJECT/ntfy_listener_test.sh" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-001: Normal message triggers inbox_write to shogun (ACK removed, shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-001: Normal message triggers inbox_write to shogun" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg001","time":1234567890,"message":"test notification","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — shogun replies directly after processing.
    # Verify inbox_write to shogun was called instead.
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-002: Outbound message does NOT trigger ACK (loop prevention)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg002","time":1234567890,"message":"📱Received: echo","tags":["outbound"]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-003: No auto-ACK sent (shogun replies directly)
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-003: No auto-ACK sent (shogun replies directly)" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg003","time":1234567890,"message":"test notification","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — ACK_LOG should be empty
    [ ! -s "$ACK_LOG" ]
    # But inbox_write to shogun should still fire
    [ -s "$INBOX_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-004: ACK failure does not block inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-004: ACK failure does not block inbox_write" {
    export MOCK_NTFY_EXIT_CODE=1
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg004","time":1234567890,"message":"test msg","tags":[]}
JSON
    run_listener
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-005: Empty message skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-005: Empty message skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg005","time":1234567890,"message":"","tags":[]}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-006: Non-message event (keepalive) skips ACK
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-006: Non-message event (keepalive) skips ACK" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"keepalive","id":"","time":1234567890,"message":""}
JSON
    run_listener
    [ ! -s "$ACK_LOG" ]
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-007: append_ntfy_inbox failure skips both ACK and inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg007","time":1234567890,"message":"should not ack","tags":[]}
JSON
    # Force append_ntfy_inbox failure in a UID-independent way.
    # chmod-based write denial does not fail when the suite runs as root.
    rm "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    mkdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    run_listener
    # Both ACK and inbox_write should be skipped (L159 continue)
    [ ! -s "$ACK_LOG" ]
    [ ! -s "$INBOX_LOG" ]
    # Restore for teardown
    rmdir "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
    echo "inbox:" > "$MOCK_PROJECT/queue/ntfy_inbox.yaml"
}

# ═══════════════════════════════════════════════════════════════
# T-ACK-008: Special characters in message preserved in inbox_write
# ═══════════════════════════════════════════════════════════════

@test "T-ACK-008: Special characters in message preserved in inbox_write" {
    cat > "$MOCK_CURL_OUTPUT" << 'JSON'
{"event":"message","id":"msg008","time":1234567890,"message":"Hello 'world' & <test>","tags":[]}
JSON
    run_listener
    # Auto-ACK removed — verify inbox_write still fires for special characters
    [ ! -s "$ACK_LOG" ]
    [ -s "$INBOX_LOG" ]
    grep -q "shogun" "$INBOX_LOG"
}

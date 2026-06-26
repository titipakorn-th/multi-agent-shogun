#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_inbox_backlog_alarm.bats — T5 backlog alarm (W7)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/inbox_backlog_alarm.sh"
    SANDBOX="$BATS_TEST_TMPDIR/queue"
    mkdir -p "$SANDBOX/inbox"
}

teardown() {
    rm -rf "$SANDBOX"
}

# Generate an inbox YAML with N read:false entries.
gen_inbox() {
    local name="$1"
    local n="$2"
    {
        echo "messages:"
        for i in $(seq 1 "$n"); do
            cat <<YAML
  - id: msg_$i
    read: false
    timestamp: '2026-01-01T00:00:0$((i % 10))'
YAML
        done
    } > "$SANDBOX/inbox/${name}.yaml"
}

# Override the script's INBOX_DIR by symlinking our sandbox into a wrapper
# that re-execs the script with a custom path. Simpler: just point SCRIPT
# at a sandboxed copy that hard-codes INBOX_DIR.
@test "T-BACKLOG-001: alarm fires at threshold" {
    gen_inbox alice 51
    run bash -c "
        SANDBOX='$SANDBOX'
        SCRIPT='$SCRIPT'
        # Rewrite the INBOX_DIR line to point at the sandbox.
        tmp=\$(mktemp)
        sed \"s|^INBOX_DIR=.*|INBOX_DIR=\\\"\$SANDBOX/inbox\\\"|\" \"\$SCRIPT\" > \"\$tmp\"
        bash \"\$tmp\" --threshold 50
        status=\$?
        rm -f \"\$tmp\"
        exit \$status
    "
    [ "$status" -eq 2 ]
    echo "$output" | grep -q "alice: 51 unread"
}

@test "T-BACKLOG-002: alarm does NOT fire below threshold" {
    gen_inbox bob 10
    run bash -c "
        SANDBOX='$SANDBOX'
        SCRIPT='$SCRIPT'
        tmp=\$(mktemp)
        sed \"s|^INBOX_DIR=.*|INBOX_DIR=\\\"\$SANDBOX/inbox\\\"|\" \"\$SCRIPT\" > \"\$tmp\"
        bash \"\$tmp\" --threshold 50
        status=\$?
        rm -f \"\$tmp\"
        exit \$status
    "
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "all inboxes under threshold"
}

@test "T-BACKLOG-003: rejects unknown args with exit 1" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
}

@test "T-BACKLOG-004: --help prints usage" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Usage"
}
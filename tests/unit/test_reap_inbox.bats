#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_reap_inbox.bats — T1 inbox rotation + archival (W1)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/reap_inbox.sh"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/queue/inbox" "$SANDBOX/queue/archive/inbox" "$SANDBOX/queue/tasks" "$SANDBOX/instructions/generated"
    # Stub python if needed (script prefers system python3 with PyYAML).
}

teardown() {
    rm -rf "$SANDBOX"
}

# Helper: generate an inbox with N messages, R of which are read.
gen_inbox() {
    local name="$1"
    local n="$2"
    local r="$3"
    {
        echo "messages:"
        for i in $(seq 1 "$n"); do
            local is_read="false"
            if [ "$i" -le "$r" ]; then is_read="true"; fi
            cat <<YAML
  - id: msg_${name}_$i
    read: $is_read
    timestamp: '2026-01-01T00:00:00'
    content: 'message $i for $name'
YAML
        done
    } > "$SANDBOX/queue/inbox/${name}.yaml"
}

# Helper: run reap_inbox against the sandbox by sed-replacing paths.
run_against_sandbox() {
    local args=("$@")
    local tmp=$(mktemp)
    # Rewrite the INBOX_DIR and ARCHIVE_DIR lines to point at the sandbox.
    sed -e "s|^INBOX_DIR=.*|INBOX_DIR=\"$SANDBOX/queue/inbox\"|" \
        -e "s|^ARCHIVE_DIR=.*|ARCHIVE_DIR=\"$SANDBOX/queue/archive/inbox\"|" \
        "$SCRIPT" > "$tmp"
    chmod +x "$tmp"
    bash "$tmp" "${args[@]}"
    local rc=$?
    rm -f "$tmp"
    return $rc
}

@test "T-INBOX-001: nothing to do when entries below thresholds" {
    gen_inbox alice 50 5
    run run_against_sandbox --agent alice --max-entries 200 --max-read 150
    [ "$status" -eq 0 ]
    [ ! -f "$SANDBOX/queue/archive/inbox/alice-$(date +%Y-%m-%d).yaml" ]
}

@test "T-INBOX-002: archives excess read entries, keeps last K + all unread" {
    gen_inbox bob 30 25  # 30 entries, 25 read, 5 unread
    run run_against_sandbox --agent bob --max-entries 5 --max-read 5 --keep-read 5
    [ "$status" -eq 2 ]
    # 25 read - 5 kept = 20 archived.
    echo "$output" | grep -qE "archived 20 read entries"
    # Live inbox retains: 5 unread + 5 kept-read = 10 entries.
    local remaining
    remaining=$(grep -cE "^[[:space:]]*- id:" "$SANDBOX/queue/inbox/bob.yaml" 2>/dev/null | head -1)
    [ "${remaining:-0}" -eq 10 ]
    # Archive file exists with 20 entries.
    [ -f "$SANDBOX/queue/archive/inbox/bob-$(date +%Y-%m-%d).yaml" ]
    local archived
    archived=$(grep -cE "^[[:space:]]*- id:" "$SANDBOX/queue/archive/inbox/bob-$(date +%Y-%m-%d).yaml" | head -1)
    [ "${archived:-0}" -eq 20 ]
}

@test "T-INBOX-003: unread messages are NEVER archived" {
    gen_inbox carol 100 0  # 100 unread, 0 read
    run run_against_sandbox --agent carol --max-entries 5 --max-read 5
    # No read entries exist, so nothing to archive even though total > threshold.
    [ "$status" -eq 0 ]
    # All 100 unread remain in live inbox.
    local remaining
    remaining=$(grep -cE "^[[:space:]]*- id:" "$SANDBOX/queue/inbox/carol.yaml" | head -1)
    [ "${remaining:-0}" -eq 100 ]
    # No archive file created for an all-unread mailbox.
    [ ! -f "$SANDBOX/queue/archive/inbox/carol-$(date +%Y-%m-%d).yaml" ]
}

@test "T-INBOX-004: idempotent on second run" {
    gen_inbox dave 30 25
    run run_against_sandbox --agent dave --max-entries 5 --max-read 5 --keep-read 5
    [ "$status" -eq 2 ]
    run run_against_sandbox --agent dave --max-entries 5 --max-read 5 --keep-read 5
    # Second run should find nothing left to archive (read count is now 5).
    [ "$status" -eq 0 ]
}

@test "T-INBOX-005: --dry-run does not modify files" {
    gen_inbox eve 30 25
    local before_after
    before_after=$(md5sum "$SANDBOX/queue/inbox/eve.yaml" | awk '{print $1}')
    run run_against_sandbox --agent eve --max-entries 5 --max-read 5 --keep-read 5 --dry-run
    [ "$status" -eq 2 ]
    local after_md5
    after_md5=$(md5sum "$SANDBOX/queue/inbox/eve.yaml" | awk '{print $1}')
    [ "$before_after" = "$after_md5" ]
}

@test "T-INBOX-006: rejects unknown args with exit 1" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
}

@test "T-INBOX-007: --help prints usage" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Usage"
}
#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_lord_channel.bats — W4c lord_channel.py state machine
# ═══════════════════════════════════════════════════════════════
# Verifies the consolidated Lord-question state machine:
#   - ask writes pending state, blocks, returns answer on consume
#   - consume is idempotent (late callback returns already_resolved)
#   - timeout transitions pending → timeout cleanly
#   - busy returns 4 when another pending question exists
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    CHANNEL="$PROJECT_ROOT/scripts/lib/lord_channel.py"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/queue"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "W4C-T-CHANNEL-001: consume resolves a pending question" {
    # Write a pending state directly (skip ask/timeout dance).
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_test_1","question":"q","options":["a","b"],"status":"pending","created_at":0,"answered_at":null}
JSON
    run python3 "$CHANNEL" consume --queue-dir "$SANDBOX/queue" --request-id "rq_test_1" --answer "a"
    [ "$status" -eq 0 ]
    # State file now has the answer.
    grep -q '"answer": "a"' "$SANDBOX/queue/current_question.json"
    grep -q '"status": "answered"' "$SANDBOX/queue/current_question.json"
}

@test "W4C-T-CHANNEL-002: consume on unknown request_id returns no_match" {
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_other","question":"q","options":[],"status":"pending","created_at":0,"answered_at":null}
JSON
    run python3 "$CHANNEL" consume --queue-dir "$SANDBOX/queue" --request-id "rq_unknown" --answer "x"
    [ "$status" -eq 1 ]
}

@test "W4C-T-CHANNEL-003: consume on already-answered is idempotent" {
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_test_2","question":"q","options":["a"],"status":"answered","answer":"a","created_at":0,"answered_at":0}
JSON
    run python3 "$CHANNEL" consume --queue-dir "$SANDBOX/queue" --request-id "rq_test_2" --answer "b"
    # Idempotent: returns 2 (already_resolved), does NOT overwrite.
    [ "$status" -eq 2 ]
    # State file must still show answer="a" (b was rejected because already resolved).
    python3 -c "import json,sys; d=json.load(open('$SANDBOX/queue/current_question.json')); assert d['answer']=='a', d"
}

@test "W4C-T-CHANNEL-004: ask with another pending returns busy (exit 4)" {
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_existing","question":"old","options":[],"status":"pending","created_at":0,"answered_at":null}
JSON
    # ask without telegram config (will time out after 1s); busy short-circuits.
    run python3 "$CHANNEL" ask --queue-dir "$SANDBOX/queue" --question "new" --timeout 1
    [ "$status" -eq 4 ]
}

@test "W4C-T-CHANNEL-005: ask times out cleanly when no consumer" {
    # No telegram token → no callback arrives → timeout path.
    run python3 "$CHANNEL" ask --queue-dir "$SANDBOX/queue" --question "q" --options "a" --timeout 1
    [ "$status" -eq 3 ]
    # State file should now reflect timeout.
    grep -q '"status": "timeout"' "$SANDBOX/queue/current_question.json"
}

@test "W4C-T-CHANNEL-006: lock file is created and flock'd" {
    # Run ask with timeout 1; lock file should exist after.
    run python3 "$CHANNEL" ask --queue-dir "$SANDBOX/queue" --question "q" --timeout 1
    [ -f "$SANDBOX/queue/current_question.lock" ]
}

@test "W4C-T-CHANNEL-007: state file uses atomic rename (no torn writes)" {
    # The channel writes via .tmp + os.replace. Verify by reading the
    # file after a write completes — it must always be valid JSON, never
    # partial. We test this by checking the JSON parses after a normal
    # consume cycle.
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_atomic","question":"q","options":[],"status":"pending","created_at":0,"answered_at":null}
JSON
    python3 "$CHANNEL" consume --queue-dir "$SANDBOX/queue" --request-id "rq_atomic" --answer "x" >/dev/null
    python3 -c "import json; d = json.load(open('$SANDBOX/queue/current_question.json')); assert d['answer'] == 'x'"
}
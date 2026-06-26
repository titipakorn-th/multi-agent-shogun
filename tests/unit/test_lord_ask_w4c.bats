#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_lord_ask_w4c.bats — W4c-test: lord_ask.sh via lord_channel
# ═══════════════════════════════════════════════════════════════
# After W4c-real refactored lord_ask.sh to delegate to lord_channel.py,
# these tests prove the integration:
#   - usage error path (no question)
#   - timeout path (asks, times out, emits lord_question_timeout event)
#   - busy path (already-pending question)
#   - terminal fallback (telegram.mode=off → stdin read)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LORD_ASK="$PROJECT_ROOT/scripts/lord_ask.sh"
    CHANNEL="$PROJECT_ROOT/scripts/lib/lord_channel.py"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/queue/inbox" "$SANDBOX/scripts" "$SANDBOX/scripts/lib" "$SANDBOX/config"
    # Mirror the channel module + lib into the sandbox.
    cp "$CHANNEL" "$SANDBOX/scripts/lib/"
    cp -r "$PROJECT_ROOT/scripts/lib/." "$SANDBOX/scripts/lib/" 2>/dev/null || true
    # Settings file: telegram.mode=on by default; some tests override.
    cat > "$SANDBOX/config/settings.yaml" <<'YAML'
language: en
topology: v2
telegram:
  mode: on
YAML
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "W4C-T-ASK-001: lord_ask rejects empty question" {
    run bash "$LORD_ASK"
    [ "$status" -eq 64 ]
    echo "$output" | grep -q "Usage"
}

@test "W4C-T-ASK-002: lord_ask timeout emits lord_question_timeout to shogun inbox" {
    # Use sandbox queue + channel path so we don't pollute real queue.
    run env LORD_ASK_QUEUE_DIR="$SANDBOX/queue" \
        LORD_ASK_CHANNEL="$SANDBOX/scripts/lib/lord_channel.py" \
        timeout 15 bash "$LORD_ASK" "test question" --timeout 1
    # rc=3 means timeout (lord_ask's documented exit code).
    [ "$status" -eq 3 ]
    # Shogun inbox must contain the timeout event.
    [ -f "$SANDBOX/queue/inbox/shogun.yaml" ]
    grep -q "lord_question_timeout" "$SANDBOX/queue/inbox/shogun.yaml"
    grep -q "test question" "$SANDBOX/queue/inbox/shogun.yaml"
}

@test "W4C-T-ASK-003: terminal mode (telegram.mode=off) reads from stdin" {
    cat > "$SANDBOX/config/settings.yaml" <<'YAML'
language: en
topology: v2
telegram:
  mode: off
YAML
    run env LORD_ASK_SETTINGS="$SANDBOX/config/settings.yaml" \
        bash "$LORD_ASK" "pick one" "a" "b" --timeout 60 <<< "1"
    [ "$status" -eq 0 ]
    # The script prompts AND reads. Verify both prompt + answer present.
    echo "$output" | grep -q "Your answer"
    echo "$output" | grep -qE ": 1$|: 1[^0-9]"
}

@test "W4C-T-ASK-004: terminal mode without options reads free text" {
    cat > "$SANDBOX/config/settings.yaml" <<'YAML'
language: en
topology: v2
telegram:
  mode: off
YAML
    run env LORD_ASK_SETTINGS="$SANDBOX/config/settings.yaml" \
        bash "$LORD_ASK" "type something" --timeout 60 <<< "hello world"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Your answer"
    echo "$output" | grep -qE ": hello world$"
}

@test "W4C-T-ASK-005: busy path returns exit 4 when a question is already pending" {
    # Plant a pending question directly so lord_channel.py ask hits busy.
    cat > "$SANDBOX/queue/current_question.json" <<'JSON'
{"request_id":"rq_blocking","question":"old","options":[],"status":"pending","created_at":0,"answered_at":null}
JSON
    run env LORD_ASK_QUEUE_DIR="$SANDBOX/queue" \
        LORD_ASK_CHANNEL="$SANDBOX/scripts/lib/lord_channel.py" \
        bash "$LORD_ASK" "new question" --timeout 2
    [ "$status" -eq 4 ]
}
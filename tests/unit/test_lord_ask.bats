#!/usr/bin/env bats
# test_lord_ask.bats — lord_ask.sh unit tests
# These tests stub telegram_ask.py and current_question.json to verify
# the bash wrapper's request_id generation, exit codes, and timeout path.

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/lordask.XXXXXX")"
    export MOCK_ASK="$TEST_TMPDIR/telegram_ask.py"
    export MOCK_QUEUE="$TEST_TMPDIR/queue"
    mkdir -p "$MOCK_QUEUE"

    # Mock telegram_ask.py: writes a question file, then watches for status.
    cat > "$MOCK_ASK" << 'PYEOF'
#!/usr/bin/env python3
import sys, os, json, time, argparse
ap = argparse.ArgumentParser()
ap.add_argument("--question", required=True)
ap.add_argument("--options", nargs="*", default=[])
ap.add_argument("--question-file", required=True)
ap.add_argument("--chat-id", required=True)
ap.add_argument("--token", required=True)
ap.add_argument("--timeout", type=int, default=10)
ap.add_argument("--no-wait", action="store_true")
args = ap.parse_args()
qf = args.question_file
data = {
    "request_id": os.environ.get("REQUEST_ID", "mock-rid"),
    "question": args.question,
    "options": args.options,
    "status": "pending",
    "chat_id": args.chat_id,
}
with open(qf, "w") as f:
    json.dump(data, f)
if args.no_wait:
    print("mock-sent")
    sys.exit(0)
# In --wait mode, poll for status=answered
start = time.time()
while time.time() - start < args.timeout:
    try:
        with open(qf) as f:
            d = json.load(f)
        if d.get("status") == "answered":
            print(d.get("response", ""))
            sys.exit(0)
    except Exception:
        pass
    time.sleep(0.2)
print("ERROR: timeout", file=sys.stderr)
sys.exit(1)
PYEOF
    chmod +x "$MOCK_ASK"

    export PATH="$TEST_TMPDIR:$PATH"
    # Override the path resolution inside lord_ask.sh
    export LORD_ASK_PYTHON="$MOCK_ASK"
    export LORD_ASK_QUEUE_DIR="$MOCK_QUEUE"
    export TELEGRAM_BOT_TOKEN="stub-token"
    export TELEGRAM_CHAT_ID="12345"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "lord_ask.sh: writes request_id and reads answer" {
    # Pre-stage an "answered" status
    (
        sleep 0.5
        cat > "$MOCK_QUEUE/current_question.json" <<'JSON'
{"status":"answered","response":"yes, do A"}
JSON
    ) &
    FLIPPER=$!
    run bash "$PROJECT_ROOT/scripts/lord_ask.sh" "pick one" "A" "B" --timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"yes, do A"* ]]
    wait $FLIPPER 2>/dev/null || true
}

@test "lord_ask.sh: exits 3 on timeout" {
    run bash "$PROJECT_ROOT/scripts/lord_ask.sh" "pick one" "A" "B" --timeout 1
    [ "$status" -eq 3 ]
    [[ "$output" == *"no answer"* ]]
}

@test "lord_ask.sh: exits 2 when Telegram not configured" {
    unset TELEGRAM_BOT_TOKEN
    run bash "$PROJECT_ROOT/scripts/lord_ask.sh" "pick one"
    [ "$status" -eq 2 ]
    [[ "$output" == *"Telegram not configured"* ]]
}

@test "lord_ask.sh: enqueue_pending appends YAML entries" {
    export LORD_ASK_PENDING_FILE="$TEST_TMPDIR/pending.yaml"
    # Sanity: the no-configured-Telegram path exits early at line ~53,
    # which is after PENDING_FILE setup and the enqueue_pending function
    # definition. We exercise enqueue_pending directly via a sourced snippet
    # written to a temp file (process substitution is fragile across bash
    # subshells).
    export SNIPPET="$TEST_TMPDIR/enqueue_snippet.sh"
    sed -n '/^enqueue_pending()/,/^}/p' "$PROJECT_ROOT/scripts/lord_ask.sh" > "$SNIPPET"
    cat >> "$SNIPPET" <<'EOF'
enqueue_pending 'rid-1' 'first q' '["A"]'
enqueue_pending 'rid-2' 'second q' '["B"]'
EOF
    QUEUE_DIR="$TEST_TMPDIR/queue" PENDING_FILE="$LORD_ASK_PENDING_FILE" \
        bash "$SNIPPET"
    grep -q "rid-1" "$LORD_ASK_PENDING_FILE"
    grep -q "rid-2" "$LORD_ASK_PENDING_FILE"
    grep -q 'first q' "$LORD_ASK_PENDING_FILE"
    grep -q 'second q' "$LORD_ASK_PENDING_FILE"
}

@test "lord_ask.sh: pending_first returns the head entry" {
    export LORD_ASK_PENDING_FILE="$TEST_TMPDIR/pending.yaml"
    # Source all three queue helpers in one snippet.
    export SNIPPET="$TEST_TMPDIR/queue_helpers.sh"
    sed -n '/^enqueue_pending()/,/^}/p; /^pending_first()/,/^}/p; /^pending_pop()/,/^}/p' \
        "$PROJECT_ROOT/scripts/lord_ask.sh" > "$SNIPPET"
    cat >> "$SNIPPET" <<'EOF'
enqueue_pending 'rid-1' 'first q' '["A"]'
enqueue_pending 'rid-2' 'second q' '["B"]'
pending_first
EOF
    local output
    output="$(QUEUE_DIR="$TEST_TMPDIR/queue" PENDING_FILE="$LORD_ASK_PENDING_FILE" bash "$SNIPPET")"
    [[ "$output" == *'rid-1'* ]]
    [[ "$output" != *'rid-2'* ]]
}

@test "lord_ask.sh: pending_pop drops the head entry" {
    export LORD_ASK_PENDING_FILE="$TEST_TMPDIR/pending.yaml"
    # Seed the file with two entries via the helpers.
    export SNIPPET="$TEST_TMPDIR/queue_helpers.sh"
    sed -n '/^enqueue_pending()/,/^}/p; /^pending_first()/,/^}/p; /^pending_pop()/,/^}/p' \
        "$PROJECT_ROOT/scripts/lord_ask.sh" > "$SNIPPET"
    cat >> "$SNIPPET" <<'EOF'
enqueue_pending 'rid-1' 'first q' '["A"]'
enqueue_pending 'rid-2' 'second q' '["B"]'
pending_pop
EOF
    QUEUE_DIR="$TEST_TMPDIR/queue" PENDING_FILE="$LORD_ASK_PENDING_FILE" \
        bash "$SNIPPET"
    # After pop, rid-1 is gone but rid-2 remains.
    ! grep -q "rid-1" "$LORD_ASK_PENDING_FILE"
    grep -q "rid-2" "$LORD_ASK_PENDING_FILE"
    grep -q 'second q' "$LORD_ASK_PENDING_FILE"
}

@test "lord_ask.sh: pending_pop handles sequential enqueues via tail -n +5" {
    # C1 regression: the bash-side invariant — pending_pop's tail -n +5
    # must still produce a clean FIFO after multiple sequential enqueues.
    # (The race fix is in the Python drain; this verifies the post-fix
    # invariant holds when no race occurs.)
    export LORD_ASK_PENDING_FILE="$TEST_TMPDIR/pending.yaml"
    export SNIPPET="$TEST_TMPDIR/queue_helpers.sh"
    sed -n '/^enqueue_pending()/,/^}/p; /^pending_first()/,/^}/p; /^pending_pop()/,/^}/p' \
        "$PROJECT_ROOT/scripts/lord_ask.sh" > "$SNIPPET"
    cat >> "$SNIPPET" <<'EOF'
enqueue_pending 'rid-1' 'q1' '[]'
enqueue_pending 'rid-2' 'q2' '[]'
enqueue_pending 'rid-3' 'q3' '[]'
pending_pop
EOF
    QUEUE_DIR="$TEST_TMPDIR/queue" PENDING_FILE="$LORD_ASK_PENDING_FILE" \
        bash "$SNIPPET"
    ! grep -q "rid-1" "$LORD_ASK_PENDING_FILE"
    grep -q "rid-2" "$LORD_ASK_PENDING_FILE"
    grep -q "rid-3" "$LORD_ASK_PENDING_FILE"
    # File should be exactly 8 lines (2 mappings x 4 lines)
    [ "$(wc -l < "$LORD_ASK_PENDING_FILE")" -eq 8 ]
}

@test "lord_ask.sh: enqueue_pending escapes newlines so each mapping is 4 lines" {
    # C2 regression: a question with a literal newline must NOT produce
    # a multi-line YAML mapping, otherwise pending_pop's `tail -n +5`
    # corrupts the queue by deleting the first entry's tail AND the
    # second entry's head.
    export LORD_ASK_PENDING_FILE="$TEST_TMPDIR/pending.yaml"
    export SNIPPET="$TEST_TMPDIR/enqueue_snippet.sh"
    sed -n '/^enqueue_pending()/,/^}/p' "$PROJECT_ROOT/scripts/lord_ask.sh" > "$SNIPPET"
    # Pass a question with a literal newline (bash $'...' ANSI-C quoting).
    printf "enqueue_pending 'rid-1' $'q1\\nline2' '[]'\n" >> "$SNIPPET"
    QUEUE_DIR="$TEST_TMPDIR/queue" PENDING_FILE="$LORD_ASK_PENDING_FILE" \
        bash "$SNIPPET"
    # Mapping must be exactly 4 lines even with embedded newlines
    [ "$(wc -l < "$LORD_ASK_PENDING_FILE")" -eq 4 ]
    # The newline should be escaped (literal backslash + n in the file)
    grep -q 'q1\\nline2' "$LORD_ASK_PENDING_FILE"
}

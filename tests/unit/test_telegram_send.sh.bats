#!/usr/bin/env bats
# test_telegram_send.sh.bats — telegram_send.sh unit tests

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/tgsend.XXXXXX")"
    export MOCK_CURL="$TEST_TMPDIR/curl"
    export MOCK_CURL_LOG="$TEST_TMPDIR/curl.log"
    cat > "$MOCK_CURL" << 'EOF'
#!/bin/sh
echo "$@" >> "$MOCK_CURL_LOG"
cat <<JSON
{"ok":true,"result":{"message_id":1,"date":0,"chat":{"id":1,"type":"private"},"text":"x"}}
JSON
EOF
    chmod +x "$MOCK_CURL"
    export PATH="$TEST_TMPDIR:$PATH"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

@test "telegram_send.sh: sends message when env configured" {
    cat > "$TEST_TMPDIR/telegram.env" <<EOF
TELEGRAM_BOT_TOKEN=stub-token
TELEGRAM_CHAT_ID=12345
EOF
    run bash "$PROJECT_ROOT/scripts/telegram_send.sh" "hello Lord" \
        --env-file "$TEST_TMPDIR/telegram.env" \
        --curl-binary "$MOCK_CURL"
    [ "$status" -eq 0 ]
    grep -q "sendMessage" "$MOCK_CURL_LOG"
    grep -q "hello Lord" "$MOCK_CURL_LOG"
}

@test "telegram_send.sh: exits 0 no-op when token unset" {
    cat > "$TEST_TMPDIR/telegram.env" <<EOF
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
EOF
    run bash "$PROJECT_ROOT/scripts/telegram_send.sh" "hello Lord" \
        --env-file "$TEST_TMPDIR/telegram.env" \
        --curl-binary "$MOCK_CURL"
    [ "$status" -eq 0 ]
    [ ! -s "$MOCK_CURL_LOG" ]
}

@test "telegram_send.sh: truncates messages over 4096 chars" {
    cat > "$TEST_TMPDIR/telegram.env" <<EOF
TELEGRAM_BOT_TOKEN=stub-token
TELEGRAM_CHAT_ID=12345
EOF
    BIG=$(printf 'a%.0s' {1..5000})
    run bash "$PROJECT_ROOT/scripts/telegram_send.sh" "$BIG" \
        --env-file "$TEST_TMPDIR/telegram.env" \
        --curl-binary "$MOCK_CURL"
    [ "$status" -eq 0 ]
    grep -q "truncated" "$MOCK_CURL_LOG"
}
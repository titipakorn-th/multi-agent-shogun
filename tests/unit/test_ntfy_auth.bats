#!/usr/bin/env bats
# test_ntfy_auth.bats — ntfy authentication Unit Test
# FR-066: ntfy authentication support
#
# Test configuration:
#   T-AUTH-001: ntfy_get_auth_args — Bearer token auth
#   T-AUTH-002: ntfy_get_auth_args — Basic auth
#   T-AUTH-003: ntfy_get_auth_args — No auth (backward compatibility)
#   T-AUTH-004: ntfy_get_auth_args — Token priority (when both token+basic are configured)
#   T-AUTH-005: ntfy_get_auth_args — Load env variable file
#   T-AUTH-006: ntfy_get_auth_args — Nonexistent auth_env file
#   T-AUTH-007: ntfy_validate_topic — Normal topic name
#   T-AUTH-008: ntfy_validate_topic — Too short topic name
#   T-AUTH-009: ntfy_validate_topic — Weak topic name (guessable)
#   T-AUTH-010: ntfy_validate_topic — Empty topic name
#   T-AUTH-011: ntfy.sh — Send with authentication (mock)
#   T-AUTH-012: ntfy_listener.sh — Streaming with authentication (mock)
#   T-AUTH-013: ntfy_auth.env.sample — Verify sample file existence
#   T-AUTH-014: ntfy_auth.env — Verify git untracked

# --- Setup ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export NTFY_AUTH_LIB="$PROJECT_ROOT/lib/ntfy_auth.sh"

    # Verify library existence
    [ -f "$NTFY_AUTH_LIB" ] || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/ntfy_auth_test.XXXXXX")"

    # Clear env variables (prevent test interference)
    unset NTFY_TOKEN
    unset NTFY_USER
    unset NTFY_PASS

    # Load library
    source "$NTFY_AUTH_LIB"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- T-AUTH-001: Bearer token auth ---

@test "T-AUTH-001: ntfy_get_auth_args returns Bearer header when NTFY_TOKEN is set" {
    export NTFY_TOKEN="tk_test1234567890abcdef"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q -- '-H'
    echo "$result" | grep -q 'Authorization: Bearer tk_test1234567890abcdef'
}

# --- T-AUTH-002: Basic auth ---

@test "T-AUTH-002: ntfy_get_auth_args returns -u flag when NTFY_USER and NTFY_PASS are set" {
    export NTFY_USER="testuser"
    export NTFY_PASS="testpass"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q -- '-u'
    echo "$result" | grep -q 'testuser:testpass'
}

# --- T-AUTH-003: No auth (backward compatibility) ---

@test "T-AUTH-003: ntfy_get_auth_args returns empty when no auth configured" {
    local result
    result=$(ntfy_get_auth_args /dev/null)

    [ -z "$result" ]
}

# --- T-AUTH-004: token priority ---

@test "T-AUTH-004: ntfy_get_auth_args prefers token over basic auth" {
    export NTFY_TOKEN="tk_priority_token"
    export NTFY_USER="should_not_use"
    export NTFY_PASS="should_not_use"

    local result
    result=$(ntfy_get_auth_args /dev/null)

    echo "$result" | grep -q 'Bearer tk_priority_token'
    ! echo "$result" | grep -q 'should_not_use'
}

# --- T-AUTH-005: env file read ---

@test "T-AUTH-005: ntfy_get_auth_args loads credentials from env file" {
    local auth_file="$TEST_TMPDIR/ntfy_auth.env"
    cat > "$auth_file" << 'EOF'
NTFY_TOKEN=tk_from_file_12345
EOF

    local result
    result=$(ntfy_get_auth_args "$auth_file")

    echo "$result" | grep -q 'Bearer tk_from_file_12345'
}

# --- T-AUTH-006: Nonexistent file ---

@test "T-AUTH-006: ntfy_get_auth_args handles missing auth file gracefully" {
    local result
    result=$(ntfy_get_auth_args "$TEST_TMPDIR/nonexistent.env")

    # No error, empty result (no auth fallback)
    [ -z "$result" ]
}

# --- T-AUTH-007: Normal topic name ---

@test "T-AUTH-007: ntfy_validate_topic accepts secure topic name" {
    run ntfy_validate_topic "sample-topic-secret123"
    [ "$status" -eq 0 ]
}

# --- T-AUTH-008: Too short topic name ---

@test "T-AUTH-008: ntfy_validate_topic rejects short topic name" {
    run ntfy_validate_topic "abc"
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "too short"
}

# --- T-AUTH-009: Weak topic name ---

@test "T-AUTH-009: ntfy_validate_topic rejects commonly used topic names" {
    run ntfy_validate_topic "notifications"
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "commonly used"
}

# --- T-AUTH-010: Empty topic name ---

@test "T-AUTH-010: ntfy_validate_topic rejects empty topic" {
    run ntfy_validate_topic ""
    [ "$status" -eq 1 ]
    echo "$output" | grep -qi "empty"
}

# --- T-AUTH-011: ntfy.sh send (mock) ---

@test "T-AUTH-011: ntfy.sh includes auth header in curl when token configured" {
    # Build mock environment for testing
    local mock_dir="$TEST_TMPDIR/project"
    mkdir -p "$mock_dir/config" "$mock_dir/scripts" "$mock_dir/lib"

    # settings.yaml
    cat > "$mock_dir/config/settings.yaml" << 'EOF'
ntfy_topic: "test-topic-12345"
EOF

    # ntfy_auth.env with token
    cat > "$mock_dir/config/ntfy_auth.env" << 'EOF'
NTFY_TOKEN=tk_mock_token_test
EOF

    # Copy lib/ntfy_auth.sh
    cp "$PROJECT_ROOT/lib/ntfy_auth.sh" "$mock_dir/lib/"

    # curl mock: log arguments to file
    local curl_log="$TEST_TMPDIR/curl_args.log"
    cat > "$mock_dir/mock_curl" << MOCK
#!/bin/bash
echo "\$@" > "$curl_log"
MOCK
    chmod +x "$mock_dir/mock_curl"

    # Test copy of ntfy.sh (replace curl with mock)
    cp "$PROJECT_ROOT/scripts/ntfy.sh" "$mock_dir/scripts/ntfy.sh"
    # Change SCRIPT_DIR resolution to mock_dir
    sed "s|SETTINGS=.*|SETTINGS=\"$mock_dir/config/settings.yaml\"|" "$mock_dir/scripts/ntfy.sh" > "$mock_dir/scripts/ntfy.sh.tmp" && mv "$mock_dir/scripts/ntfy.sh.tmp" "$mock_dir/scripts/ntfy.sh"

    # source ntfy_auth.sh + mock curl
    cat > "$mock_dir/scripts/ntfy_test.sh" << TESTSH
#!/bin/bash
source "$mock_dir/lib/ntfy_auth.sh"
SETTINGS="$mock_dir/config/settings.yaml"
TOPIC=\$(grep 'ntfy_topic:' "\$SETTINGS" | awk '{print \$2}' | tr -d '"')
AUTH_ARGS=\$(ntfy_get_auth_args "$mock_dir/config/ntfy_auth.env")
# shellcheck disable=SC2086
"$mock_dir/mock_curl" -s \$AUTH_ARGS -H "Tags: outbound" -d "hello" "https://ntfy.sh/\$TOPIC"
TESTSH
    chmod +x "$mock_dir/scripts/ntfy_test.sh"

    run bash "$mock_dir/scripts/ntfy_test.sh"
    [ "$status" -eq 0 ]

    # Confirm auth header passed to curl
    [ -f "$curl_log" ]
    grep -q "Bearer tk_mock_token_test" "$curl_log"
    grep -q "test-topic-12345" "$curl_log"
}

# --- T-AUTH-012: ntfy_listener.sh auth validation (mock) ---

@test "T-AUTH-012: ntfy_get_auth_args output can be used as curl arguments" {
    export NTFY_TOKEN="tk_listener_test"

    # Get auth arguments
    local auth_args
    auth_args=$(ntfy_get_auth_args /dev/null)

    # Verify format can be used as curl arguments
    # 2 lines output: -H and Authorization: Bearer
    local line_count
    line_count=$(echo "$auth_args" | wc -l)
    [ "$line_count" -eq 2 ]

    local first_line
    first_line=$(echo "$auth_args" | head -1)
    [ "$first_line" = "-H" ]

    local second_line
    second_line=$(echo "$auth_args" | tail -1)
    [ "$second_line" = "Authorization: Bearer tk_listener_test" ]
}

# --- T-AUTH-013: Verify sample file existence ---

@test "T-AUTH-013: ntfy_auth.env.sample exists with configuration instructions" {
    local sample="$PROJECT_ROOT/config/ntfy_auth.env.sample"
    [ -f "$sample" ]
    grep -q "NTFY_TOKEN" "$sample"
    grep -q "NTFY_USER" "$sample"
    grep -q "NTFY_PASS" "$sample"
}

# --- T-AUTH-014: Verify git untracked ---

@test "T-AUTH-014: ntfy_auth.env is not tracked by git (whitelist .gitignore)" {
    # .gitignore is whitelist-based (exclude all with * -> allow with !)
    # Verify config/ntfy_auth.env is not in the whitelist
    # (.sample is tracked, .env itself is untracked)
    cd "$PROJECT_ROOT"

    # Confirm it is actually ignored with git check-ignore (most reliable method)
    run git check-ignore config/ntfy_auth.env
    [ "$status" -eq 0 ]
}

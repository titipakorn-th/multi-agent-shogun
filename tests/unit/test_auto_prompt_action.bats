#!/usr/bin/env bats
# test_auto_prompt_action.bats — unit tests for scripts/lib/auto_prompt_resolve_action.sh
#
# Coverage (per plan §cmd_036 PART D):
#   TC-APR-01: (Recommended) marker present → exit 0, stdout = option text
#   TC-APR-02: no (Recommended) marker → exit 2, stderr "no_recommended: <N>"
#   TC-APR-03: malformed CHOICES line → exit 3, stderr "parse_error:"
#   TC-APR-04: multi-line option bodies with embedded newlines → handled
#
# Also: source-style invocation (the way Shogun actually calls it).

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HELPER="$PROJECT_ROOT/scripts/lib/auto_prompt_resolve_action.sh"
    TEST_FIXTURES_DIR="$(mktemp -d "$BATS_TMPDIR/auto_prompt_action.XXXXXX")"
    # shellcheck disable=SC1090
    source "$HELPER"
}

teardown() {
    rm -rf "$TEST_FIXTURES_DIR"
}

# Helper: write an action_required fixture to a file in the temp dir.
write_fixture() {
    local filename="$1"
    local body="$2"
    printf '%s\n' "$body" > "$TEST_FIXTURES_DIR/$filename"
}

@test "TC-APR-01: action_required with (Recommended) marker exits 0 and returns option text" {
    write_fixture "tc01.txt" \
        "ACTION_REQUIRED: choose a deployment | CHOICES: (a) staging, (b) production (Recommended), (c) cancel"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc01.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "production" ]
}

@test "TC-APR-02: action_required WITHOUT (Recommended) marker exits 2 with no_recommended" {
    write_fixture "tc02.txt" \
        "ACTION_REQUIRED: choose a deployment | CHOICES: (a) staging, (b) production, (c) cancel"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc02.txt"
    [ "$status" -eq 2 ]
    [[ "$output" =~ "no_recommended: 3 choices parsed" ]]
}

@test "TC-APR-03: malformed CHOICES line exits 3 with parse_error" {
    write_fixture "tc03.txt" \
        "ACTION_REQUIRED: bad input | CHOICES::: garbage [unclosed"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc03.txt"
    [ "$status" -eq 3 ]
    [[ "$output" =~ "parse_error:" ]]
}

@test "TC-APR-04: multi-line option body with embedded newline is folded into resolution" {
    write_fixture "tc04.txt" \
        "ACTION_REQUIRED: pick | CHOICES: (a) option-a-text
continued-line (Recommended), (b) other"

    run auto_prompt_resolve_action "$TEST_FIXTURES_DIR/tc04.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "option-a-text continued-line" ]
}

@test "TC-APR-05: missing input file exits 3 with parse_error" {
    local nonexistent="$TEST_FIXTURES_DIR/does-not-exist.txt"
    run auto_prompt_resolve_action "$nonexistent"
    [ "$status" -eq 3 ]
    [[ "$output" =~ "parse_error:" ]]
}

@test "TC-APR-06: stdin invocation works (sourced style)" {
    write_fixture "tc06.txt" \
        "ACTION_REQUIRED: choose | CHOICES: (a) low, (b) high (Recommended), (c) off"

    run bash -c "source '$HELPER' && cat '$TEST_FIXTURES_DIR/tc06.txt' | auto_prompt_resolve_action"
    [ "$status" -eq 0 ]
    [ "$output" = "high" ]
}
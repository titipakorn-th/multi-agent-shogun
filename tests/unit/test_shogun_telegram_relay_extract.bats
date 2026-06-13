#!/usr/bin/env bats
# test_shogun_telegram_relay_extract.bats — pure extract function tests

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

setup() {
    # bats runs setup() in the same shell as @test bodies, unlike setup_file().
    # Source the lib so the functions are visible in each test.
    source "$PROJECT_ROOT/scripts/lib/shogun_telegram_relay_extract.sh"
}

@test "extract_lord_block: returns text below marker" {
    PANE=$'some prior output\n### 📰 To Lord\nthis is the message\nmore text'
    run extract_lord_block "$PANE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"this is the message"* ]]
}

@test "extract_lord_block: returns empty string when marker absent" {
    run extract_lord_block $'just some text\nno marker here'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "extract_lord_block: uses the LAST marker, not the first" {
    PANE=$'### 📰 To Lord\nfirst message\n### 📰 To Lord\nsecond message'
    run extract_lord_block "$PANE"
    [[ "$output" == *"second message"* ]]
    [[ "$output" != *"first message"* ]]
}

@test "extract_lord_block: stops at next ### heading" {
    PANE=$'### 📰 To Lord\nthe real message\n### 🛠 Other Section\nshould not include'
    run extract_lord_block "$PANE"
    [[ "$output" == *"the real message"* ]]
    [[ "$output" != *"Other Section"* ]]
}

@test "truncate_for_telegram: 1500 char cap with suffix" {
    BIG=$(printf 'a%.0s' {1..2000})
    run truncate_for_telegram "$BIG"
    [[ ${#output} -le 1510 ]]
    [[ "$output" == *"…[truncated]"* ]]
}

@test "hash_block: stable for same input" {
    a=$(hash_block "hello")
    b=$(hash_block "hello")
    [ "$a" = "$b" ]
    c=$(hash_block "world")
    [ "$a" != "$c" ]
}


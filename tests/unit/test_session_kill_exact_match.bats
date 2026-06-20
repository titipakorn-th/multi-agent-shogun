#!/usr/bin/env bats
# test_session_kill_exact_match.bats — exact-match for tmux kill-session
#
# Tests for cross-project session-kill regression.
#
# Root cause: tmux's session-target parser walks exact -> unique-prefix ->
# substring. Without `=`, `tmux kill-session -t shogun` matches
# `shogun_safepay` via unique prefix when no exact `shogun` exists.
# That murdered the other project's session.
#
# Fix: every `tmux {kill,has}-session -t "$name"` call in
# depart.sh / cleanup.sh / shutsujin_departure.sh must use `-t "=$name"`
# (the documented tmux exact-match flag).
#
# See: depart.sh:178, cleanup.sh:22-23, scripts/shutsujin_departure.sh:339-340

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

# =============================================================================
# Live tmux exact-match semantics
# Use a separate tmux socket (-L bats_killmatch) to isolate from the
# developer's real sessions. Without isolation, an exact-match probe like
# `=shogun` would find the developer's real `shogun` session and the test
# would pass for the wrong reason.
# =============================================================================

setup() {
    TMUX_TAG="bats$$_$BATS_TEST_NUMBER"
    SOCK="bats_killmatch_${TMUX_TAG}"
    TMUX="tmux -L $SOCK"
    # Start a fresh server
    $TMUX -f /dev/null new-session -d -s "starter_${TMUX_TAG}" -n main || true
}

teardown() {
    # Kill the isolated server entirely
    tmux -L "bats_killmatch_${TMUX_TAG}" kill-server 2>/dev/null || true
}

@test "has-session -t =shogun does NOT match shogun_safepay (unique prefix is not exact)" {
    $TMUX new-session -d -s "shogun_safepay" -n main
    run $TMUX has-session -t '=shogun'
    [ "$status" -ne 0 ]
    [[ "$output" == *"can't find session"* ]]
}

@test "has-session -t =shogun matches exact shogun when present" {
    $TMUX new-session -d -s "shogun" -n main
    $TMUX new-session -d -s "shogun_safepay" -n main
    run $TMUX has-session -t '=shogun'
    [ "$status" -eq 0 ]
}

@test "has-session -t =multiagent does NOT match multiagent_safepay" {
    $TMUX new-session -d -s "multiagent_safepay" -n ops
    run $TMUX has-session -t '=multiagent'
    [ "$status" -ne 0 ]
    [[ "$output" == *"can't find session"* ]]
}

@test "kill-session -t =shogun leaves shogun_safepay alone" {
    $TMUX new-session -d -s "shogun_safepay" -n main
    run $TMUX kill-session -t '=shogun'
    [ "$status" -ne 0 ]
    # Verify the suffixed session still exists
    $TMUX has-session -t '=shogun_safepay'
}

# =============================================================================
# Static checks: every kill/has-session call must use the = prefix
# =============================================================================

# Static-check helper: given a file path, find every `tmux {kill,has}-session -t ARG`
# line (excluding comments), and assert that ARG begins with `=` (exact-match).
# Returns 0 if all checks pass, 1 if any buggy line is found. Prints the offending
# line(s) to stderr.
assert_session_targets_use_exact_match() {
    local file="$1"
    local pattern='tmux[[:space:]]+(kill|has)-session[[:space:]]+-t[[:space:]]+'
    local bad=0
    while IFS= read -r line; do
        # Skip comment lines (the codebase uses # to introduce them)
        [[ "$line" == *"#"* ]] && continue
        # Extract the -t argument. awk skips the leading "linenum:" prefix
        # from grep -n, takes the field after "-t", and strips any
        # surrounding double quotes. The result is what tmux actually sees.
        local arg
        arg=$(echo "$line" | awk '{
            for (i = 1; i <= NF; i++) if ($i == "-t") { print $(i+1); exit }
        }' | tr -d '"')
        # The arg must start with `=`. tmux's exact-match syntax is `=name`.
        case "$arg" in
            =*) ;;  # good: =name form
            *) echo "Buggy line (target after -t lacks = prefix): $line" >&2; bad=1 ;;
        esac
    done < <(grep -nE "$pattern" "$file")
    return "$bad"
}

@test "depart.sh: every tmux kill-session -t uses exact-match (=) prefix" {
    assert_session_targets_use_exact_match "$REPO_ROOT/depart.sh"
}

@test "cleanup.sh: every tmux {kill,has}-session -t uses exact-match (=) prefix" {
    assert_session_targets_use_exact_match "$REPO_ROOT/cleanup.sh"
}

@test "shutsujin_departure.sh: every tmux kill-session -t uses exact-match (=) prefix" {
    assert_session_targets_use_exact_match "$REPO_ROOT/shutsujin_departure.sh"
}
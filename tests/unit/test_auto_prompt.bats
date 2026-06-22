#!/usr/bin/env bats
# test_auto_prompt.bats — unit tests for scripts/lib/auto_prompt_select.sh
#
# Coverage (per plan §Verification table):
#   1. Single plan, first task unchecked → returns that plan + task 1
#   2. All tasks checked → returns no_pending
#   3. Multiple plans, mixed states → returns oldest plan with first unchecked task
#   4. Plan with auto_continue: false → skipped, returns next eligible plan
#   5. No plans directory → returns no_plans
#   6. Frontmatter malformed → skipped gracefully (returns no_pending or next plan)

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    HELPER="$PROJECT_ROOT/scripts/lib/auto_prompt_select.sh"
    TEST_PLANS_DIR="$(mktemp -d "$BATS_TMPDIR/auto_prompt_test.XXXXXX")"
    # Source the helper for inline test use.
    # shellcheck disable=SC1090
    source "$HELPER"
}

teardown() {
    rm -rf "$TEST_PLANS_DIR"
}

# Helper: write a plan file with given frontmatter and status lines.
write_plan() {
    local filename="$1"
    local auto_continue="$2"   # "true", "false", or "malformed"
    local status_lines="$3"    # multi-line string of ## Status content
    local task_details="$4"    # multi-line string of ## Task Details content

    local frontmatter_block
    if [[ "$auto_continue" == "malformed" ]]; then
        frontmatter_block="this is not valid yaml: [unclosed"
    else
        frontmatter_block="title: Test Plan
auto_continue: $auto_continue"
    fi

    {
        echo "---"
        echo "$frontmatter_block"
        echo "---"
        echo ""
        echo "## Status"
        echo ""
        echo "$status_lines"
        echo ""
        echo "## Task Details"
        echo ""
        echo "$task_details"
    } > "$TEST_PLANS_DIR/$filename"
}

@test "TC-AP-01: single plan with first task unchecked returns plan + task 1" {
    write_plan "2026-06-01-alpha.md" "true" \
        "- [x] Task 1: done already
- [ ] Task 2: next up" \
        "### Task 1: done already
Already done.

### Task 2: next up
Do this next."

    run auto_prompt_select_next "$TEST_PLANS_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "RESULT=found" ]]
    [[ "$output" =~ "PLAN=$TEST_PLANS_DIR/2026-06-01-alpha.md" ]]
    [[ "$output" =~ "TASK_NUM=2" ]]
    [[ "$output" =~ "TASK_TITLE=next up" ]]
    [[ "$output" =~ "Do this next." ]]
}

@test "TC-AP-02: all tasks checked returns no_pending" {
    write_plan "2026-06-01-done.md" "true" \
        "- [x] Task 1: done
- [x] Task 2: done too" \
        "### Task 1: done
Done.

### Task 2: done too
Also done."

    run auto_prompt_select_next "$TEST_PLANS_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "RESULT=no_pending" ]]
    [[ ! "$output" =~ "RESULT=found" ]]
}

@test "TC-AP-03: multiple plans, returns oldest with first unchecked task" {
    write_plan "2026-06-01-first.md" "true" \
        "- [x] Task 1: alpha done" \
        "### Task 1: alpha done
Done."

    write_plan "2026-06-15-second.md" "true" \
        "- [ ] Task 1: beta pending" \
        "### Task 1: beta pending
This one is up."

    write_plan "2026-06-30-third.md" "true" \
        "- [ ] Task 1: gamma pending" \
        "### Task 1: gamma pending
This one is too."

    run auto_prompt_select_next "$TEST_PLANS_DIR"
    [ "$status" -eq 0 ]
    # 2026-06-01 is all-done → skip. 2026-06-15 has first unchecked → return.
    [[ "$output" =~ "RESULT=found" ]]
    [[ "$output" =~ "PLAN=$TEST_PLANS_DIR/2026-06-15-second.md" ]]
    [[ "$output" =~ "TASK_TITLE=beta pending" ]]
}

@test "TC-AP-04: plan with auto_continue: false is skipped, returns next plan" {
    write_plan "2026-06-01-locked.md" "false" \
        "- [ ] Task 1: needs lord approval" \
        "### Task 1: needs lord approval
Body."

    write_plan "2026-06-15-open.md" "true" \
        "- [ ] Task 1: free to dispatch" \
        "### Task 1: free to dispatch
Go."

    run auto_prompt_select_next "$TEST_PLANS_DIR"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "RESULT=found" ]]
    [[ "$output" =~ "PLAN=$TEST_PLANS_DIR/2026-06-15-open.md" ]]
    [[ "$output" =~ "TASK_TITLE=free to dispatch" ]]
}

@test "TC-AP-05: no plans directory returns no_plans" {
    local empty_dir
    empty_dir="$(mktemp -d "$BATS_TMPDIR/empty_test.XXXXXX")"
    rmdir "$empty_dir"  # ensure it doesn't exist

    run auto_prompt_select_next "$empty_dir"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "RESULT=no_plans" ]]
}

@test "TC-AP-06: malformed frontmatter is skipped gracefully" {
    write_plan "2026-06-01-broken.md" "malformed" \
        "- [ ] Task 1: pending" \
        "### Task 1: pending
Body."

    write_plan "2026-06-15-good.md" "true" \
        "- [ ] Task 1: fine" \
        "### Task 1: fine
Fine body."

    run auto_prompt_select_next "$TEST_PLANS_DIR"
    [ "$status" -eq 0 ]
    # Broken plan still has auto_continue default (no false flag) and Status
    # unchecked — depends on whether `grep -q auto_continue:false` matches.
    # Either RESULT=found (broken plan picked) or RESULT=found pointing to
    # good plan (broken skipped). The only INVALID outcome is RESULT=no_plans
    # or a crash.
    [[ "$output" =~ "RESULT=found" ]]
    [[ ! "$output" =~ "RESULT=no_plans" ]]
    [[ ! "$output" =~ "RESULT=no_pending" ]]
}
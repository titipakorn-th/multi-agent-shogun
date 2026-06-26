#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_inbox_watcher_decisions.bats — T7 routing decisions (W5)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    LIB="$PROJECT_ROOT/lib/inbox_watcher_decisions.sh"
    # shellcheck disable=SC1090
    source "$LIB"
}

# ─── decide_wakeup_action ───

@test "T-DECIDE-001: 0 unread → no_unread" {
    run decide_wakeup_action 0 0 0
    [ "$status" -eq 0 ]
    [ "$output" = "no_unread" ]
}

@test "T-DECIDE-002: unread + busy → skip_busy (highest priority)" {
    run decide_wakeup_action 5 1 0
    [ "$output" = "skip_busy" ]
}

@test "T-DECIDE-003: unread + not busy + throttled → throttled" {
    run decide_wakeup_action 5 0 1
    [ "$output" = "throttled" ]
}

@test "T-DECIDE-004: unread + not busy + not throttled → nudge" {
    run decide_wakeup_action 5 0 0
    [ "$output" = "nudge" ]
}

@test "T-DECIDE-005: busy beats throttled beats nudge" {
    # all three conditions true — busy wins.
    run decide_wakeup_action 5 1 1
    [ "$output" = "skip_busy" ]
}

@test "T-DECIDE-006: handles missing args gracefully" {
    run decide_wakeup_action
    [ "$status" -eq 0 ]
    # empty input → all defaults → "no_unread" because unread_count is 0.
    [ "$output" = "no_unread" ]
}

# ─── classify_inbox_change ───

@test "T-CLASSIFY-001: after > before → new_message" {
    run classify_inbox_change 0 1
    [ "$output" = "new_message" ]
    run classify_inbox_change 3 5
    [ "$output" = "new_message" ]
}

@test "T-CLASSIFY-002: after == 0 → all_read" {
    run classify_inbox_change 5 0
    [ "$output" = "all_read" ]
}

@test "T-CLASSIFY-003: after == before → no_change" {
    run classify_inbox_change 5 5
    [ "$output" = "no_change" ]
}

@test "T-CLASSIFY-004: after < before → no_change (decrease not modeled)" {
    run classify_inbox_change 5 3
    [ "$output" = "no_change" ]
}

# ─── compute_nudge_backoff ───

@test "T-BACKOFF-001: 0 attempts → 0s" {
    run compute_nudge_backoff 0
    [ "$output" = "0" ]
}

@test "T-BACKOFF-002: 1 attempt → 5s" {
    run compute_nudge_backoff 1
    [ "$output" = "5" ]
}

@test "T-BACKOFF-003: 2 attempts → 15s" {
    run compute_nudge_backoff 2
    [ "$output" = "15" ]
}

@test "T-BACKOFF-004: 3+ attempts → 30s cap" {
    run compute_nudge_backoff 3
    [ "$output" = "30" ]
    run compute_nudge_backoff 100
    [ "$output" = "30" ]
}

@test "T-BACKOFF-005: monotonically non-decreasing" {
    local prev=0 cur
    for i in 0 1 2 3 10 99; do
        cur=$(compute_nudge_backoff "$i")
        [ "$cur" -ge "$prev" ] || { echo "backoff not monotonic at $i: $prev → $cur"; return 1; }
        prev="$cur"
    done
}
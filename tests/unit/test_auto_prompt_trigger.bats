#!/usr/bin/env bats
# test_auto_prompt_trigger.bats — verify scripts/lib/auto_prompt_trigger.sh
# (cmd_046 follow-up). Solves the session-boundary race where Shogun goes
# idle without running its Step 3.5 manual auto_prompt check.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    TEST_TMP="$(mktemp -d /tmp/apt_trig.XXXXXX)"
    export HOME="$TEST_TMP"

    # Create minimal config + state + plans + inbox scaffolding.
    mkdir -p "$TEST_TMP/queue/inbox" "$TEST_TMP/queue" "$TEST_TMP/plans"
    mkdir -p "$TEST_TMP/scripts" "$TEST_TMP/scripts/lib"
    mkdir -p "$TEST_TMP/config"

    # settings.yaml — auto_prompt on.
    cat > "$TEST_TMP/config/settings.yaml" <<'YAML'
auto_prompt:
  enabled: true
  max_dispatches_per_session: 20
YAML

    # state file.
    echo 'dispatches_this_session: 0' > "$TEST_TMP/queue/auto_prompt_state.yaml"

    # Copy the real helpers into the sandbox so we don't pollute the repo.
    cp "$REPO_ROOT/scripts/lib/auto_prompt_select.sh" "$TEST_TMP/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/auto_prompt_trigger.sh" "$TEST_TMP/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/parse_inbox.sh" "$TEST_TMP/scripts/lib/"
    chmod +x "$TEST_TMP/scripts/lib/"*.sh

    # Fake inbox_write.sh that just touches a marker.
    cat > "$TEST_TMP/scripts/inbox_write.sh" <<SH
#!/usr/bin/env bash
echo "\$@" >> "${TEST_TMP}/marker_inbox_write.log"
SH
    chmod +x "$TEST_TMP/scripts/inbox_write.sh"

    # Fake ntfy.sh.
    cat > "$TEST_TMP/scripts/ntfy.sh" <<SH
#!/usr/bin/env bash
echo "\$1" >> "${TEST_TMP}/marker_ntfy.log"
SH
    chmod +x "$TEST_TMP/scripts/ntfy.sh"

    # Default plan + inbox (one report_completed read:true).
    cat > "$TEST_TMP/plans/2026-06-23-test.md" <<'YAML'
---
title: Test plan
auto_continue: true
---

# Plan

## Status

- [ ] Task 1: cmd_001 — test task

## Task Details

### Task 1: cmd_001 — test task

Test body.
YAML

    cat > "$TEST_TMP/queue/inbox/shogun.yaml" <<'YAML'
messages:
- content: 'cmd_099 done.'
  from: orchestrator
  id: msg_test_001
  read: true
  timestamp: '2026-06-23T00:00:00'
  type: report_completed
YAML

    cd "$TEST_TMP"
}

teardown() {
    rm -rf "$TEST_TMP"
}

@test "disabled: auto_prompt off → no dispatch" {
    sed -i '' 's/enabled: true/enabled: false/' config/settings.yaml
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
    [ ! -f "$TEST_TMP/marker_ntfy.log" ]
}

@test "no report_completed: zero dispatches" {
    cat > queue/inbox/shogun.yaml <<'YAML'
messages:
- content: 'random msg'
  from: orchestrator
  id: msg_other
  read: true
  timestamp: '2026-06-23T00:00:00'
  type: action_required
YAML
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
}

@test "report_completed read:true + plan has task → dispatch" {
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ -f "$TEST_TMP/marker_inbox_write.log" ]
    [ -f "$TEST_TMP/marker_ntfy.log" ]
    grep -q "^  - id: auto_" queue/shogun_to_orchestrator.yaml
    grep -q "dispatches_this_session: 1" queue/auto_prompt_state.yaml
    grep -q "msg_test_001" queue/.auto_prompt_seen
}

@test "idempotency: same msg_id not dispatched twice" {
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    # Clear inbox log so we can detect a second fire.
    rm -f marker_inbox_write.log marker_ntfy.log
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
}

@test "session cap: dispatches_this_session at max → no dispatch" {
    sed -i '' 's/max_dispatches_per_session: 20/max_dispatches_per_session: 0/' config/settings.yaml
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
}

@test "no_plans: zero dispatches, no error" {
    rm -f plans/2026-06-23-test.md
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
}

@test "report_completed read:false: not dispatched yet" {
    cat > queue/inbox/shogun.yaml <<'YAML'
messages:
- content: 'cmd_099 done.'
  from: orchestrator
  id: msg_unread
  read: false
  timestamp: '2026-06-23T00:00:00'
  type: report_completed
YAML
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
}

@test "multi-entry: report_completed FIRST + unrelated entry LAST → still dispatches" {
    # Regression: blank-line/END-only emit dropped every entry but the last.
    # Real inboxes have report_completed buried mid-list, so test that exact
    # shape: report_completed FIRST, an unrelated alert LAST.
    cat > queue/inbox/shogun.yaml <<'YAML'
messages:
- content: 'cmd_099 done.'
  from: orchestrator
  id: msg_buried
  read: true
  timestamp: '2026-06-23T00:00:00'
  type: report_completed
- content: 'random msg'
  from: orchestrator
  id: msg_trailing
  read: true
  timestamp: '2026-06-23T00:00:01'
  type: alert
YAML
    run bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml
    [ "$status" -eq 0 ]
    [ -f "$TEST_TMP/marker_inbox_write.log" ]
    [ -f "$TEST_TMP/marker_ntfy.log" ]
    grep -q "^  - id: auto_" queue/shogun_to_orchestrator.yaml
    grep -q "dispatches_this_session: 1" queue/auto_prompt_state.yaml
    grep -q "msg_buried" queue/.auto_prompt_seen
}

@test "session reset: auto_ cmd report_completed zeros counter, dispatches again" {
    # Cap the session first (different sed target than the cap test).
    sed -i '' 's/max_dispatches_per_session: 20/max_dispatches_per_session: 0/' config/settings.yaml
    # Pre-seed: counter already at 1 (post-cap zero, simulate prior dispatch).
    sed -i '' 's/^dispatches_this_session: 0/dispatches_this_session: 1/' queue/auto_prompt_state.yaml
    # Pre-seed: we previously dispatched auto_<old_ts>, it now reports back.
    local old_auto_id="auto_1700000000"
    echo "$old_auto_id" > queue/.auto_prompt_dispatched
    # Inbox: report_completed message whose content references our old_auto_id.
    cat > queue/inbox/shogun.yaml <<YAML
messages:
- content: 'cmd_099 done. $old_auto_id completed.'
  from: orchestrator
  id: msg_reported_back
  read: true
  timestamp: '2026-06-23T00:00:00'
  type: report_completed
YAML
    # Restore cap so the post-reset dispatch can fire (max=2 above would still
    # block; set to 5 to keep the test honest about the reset path).
    sed -i '' 's/max_dispatches_per_session: 0/max_dispatches_per_session: 5/' config/settings.yaml
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    # Counter reset to 0 + 1 (the dispatch we just made).
    grep -q "dispatches_this_session: 1" queue/auto_prompt_state.yaml
    # The reported-back id was pruned from the dispatched list.
    ! grep -qF "$old_auto_id" queue/.auto_prompt_dispatched
    # The new dispatch actually fired.
    [ -f "$TEST_TMP/marker_inbox_write.log" ]
    grep -q "^  - id: auto_" queue/shogun_to_orchestrator.yaml
}

@test "project: plan frontmatter flows through to dispatched cmd" {
    # Plan declares project: lotuss → cmd carries it.
    cat > plans/2026-06-23-test.md <<'YAML'
---
title: Test plan with project
auto_continue: true
project: lotuss
---
# Plan
## Status
- [ ] Task 1: cmd_proj — test
### Task 1: cmd_proj — test
Test body.
YAML
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    grep -q "project: lotuss" queue/shogun_to_orchestrator.yaml
    ! grep -q "project: safepay" queue/shogun_to_orchestrator.yaml
}

@test "project: omitted → falls back to documented default (safepay)" {
    # Plan omits project: → fallback is the historical hardcode.
    cat > plans/2026-06-23-test.md <<'YAML'
---
title: Test plan no project
auto_continue: true
---
# Plan
## Status
- [ ] Task 1: cmd_default — test
### Task 1: cmd_default — test
Test body.
YAML
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    grep -q "project: safepay" queue/shogun_to_orchestrator.yaml
}

@test "seen file pruned to inbox-reachable ids (no unbounded growth)" {
    # Seed seen file with 5 stale ids (not in inbox) + the real one.
    cat > queue/.auto_prompt_seen <<EOF
msg_already_gone_1
msg_already_gone_2
msg_already_gone_3
msg_already_gone_4
msg_already_gone_5
msg_test_001
EOF
    # The setup() inbox contains msg_test_001 — so only that id should survive.
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    # Stale ids pruned.
    ! grep -q "msg_already_gone" queue/.auto_prompt_seen
    # The reachable id remains.
    grep -q "msg_test_001" queue/.auto_prompt_seen
    # No empty lines leaked in.
    [ "$(grep -c . queue/.auto_prompt_seen)" -eq 1 ]
}

@test "buried seen-id: NOT last in inbox → no re-dispatch, seen id preserved" {
    # Round-3 regression: the seen-prune parser used to emit only the LAST
    # inbox id (END-only awk), which dropped every earlier seen id from
    # .auto_prompt_seen every loop → the trigger treated them as unseen →
    # re-dispatched. Test reproduces that exact shape: msg_test_001 is
    # ALREADY in seen AND is in the inbox, but the inbox has a trailing
    # entry after it. The bug was triggered by entries after the seen id,
    # not by the id itself — so the seen id must NOT be pruned just
    # because something follows it.
    echo "msg_test_001" > queue/.auto_prompt_seen
    cat > queue/inbox/shogun.yaml <<'YAML'
messages:
- content: 'cmd_099 done.'
  from: orchestrator
  id: msg_test_001
  read: true
  timestamp: '2026-06-23T00:00:00'
  type: report_completed
- content: 'random msg'
  from: orchestrator
  id: msg_trailing
  read: true
  timestamp: '2026-06-23T00:00:01'
  type: alert
YAML
    # Clear inbox markers so we can detect any re-dispatch.
    rm -f marker_inbox_write.log marker_ntfy.log
    bash scripts/lib/auto_prompt_trigger.sh queue/inbox/shogun.yaml >/dev/null
    # msg_test_001 is in seen AND in inbox → MUST NOT re-dispatch.
    [ ! -f "$TEST_TMP/marker_inbox_write.log" ]
    # The seen id MUST still be in .auto_prompt_seen (not pruned because
    # the parser saw it as reachable).
    grep -q "msg_test_001" queue/.auto_prompt_seen
}
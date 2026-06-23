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
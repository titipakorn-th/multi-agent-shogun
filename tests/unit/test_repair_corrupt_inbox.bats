#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_repair_corrupt_inbox.bats — T3 corruption salvage (W2)
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/repair_corrupt_inbox.sh"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/queue/inbox" "$SANDBOX/queue/archive/inbox-recovered" "$SANDBOX/logs"
}

teardown() {
    rm -rf "$SANDBOX"
}

@test "T-CORRUPT-001: rejects unknown args with exit 1" {
    run bash "$SCRIPT" --bogus
    [ "$status" -eq 1 ]
}

@test "T-CORRUPT-002: --help prints usage" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Usage"
}

@test "T-CORRUPT-003: healthy inbox is not touched" {
    cat > "$SANDBOX/queue/inbox/healthy.yaml" <<'YAML'
messages:
- id: msg_1
  content: 'hello'
  read: true
  timestamp: '2026-01-01T00:00:00'
YAML
    run bash "$SCRIPT" --triage --dry-run
    [ "$status" -eq 0 ]
    # No .corrupt backup created.
    [ ! -f "$SANDBOX/queue/inbox/healthy.yaml.corrupt" ]
}

@test "T-CORRUPT-004: --triage recovers intact entries from .corrupt" {
    cat > "$SANDBOX/queue/inbox/explorer.yaml.corrupt" <<'YAML'
messages:
- content: 'first intact message'
  from: orchestrator
  id: msg_intact_1
  read: true
  timestamp: '2026-01-01T00:00:00'
  type: task_assigned
- content: 'second intact message'
  from: orchestrator
  id: msg_intact_2
  read: false
  timestamp: '2026-01-02T00:00:00'
  type: task_assigned
- content: 'truncated message that
YAML
    run env PROJECT_ROOT_OVERRIDE="$SANDBOX" bash "$SCRIPT" --triage
    # Recovered file should exist with 2 entries.
    [ -f "$SANDBOX/queue/archive/inbox-recovered/explorer.recovered.yaml" ]
    local count
    count=$(grep -cE "^[[:space:]]*- (id|content):" "$SANDBOX/queue/archive/inbox-recovered/explorer.recovered.yaml" 2>/dev/null | head -1)
    [ "${count:-0}" -eq 2 ]
}

@test "T-CORRUPT-005: malformed live inbox gets quarantined" {
    # Write a YAML that does NOT parse cleanly.
    cat > "$SANDBOX/queue/inbox/broken.yaml" <<'YAML'
messages:
- content: 'truncated
YAML
    run env PROJECT_ROOT_OVERRIDE="$SANDBOX" bash "$SCRIPT"
    # The broken live file is moved to .corrupt (or removed if .corrupt exists).
    [ ! -f "$SANDBOX/queue/inbox/broken.yaml" ]
}

@test "T-CORRUPT-006: --apply merges recovered into live inbox" {
    # Live inbox already has msg_already with read:true.
    cat > "$SANDBOX/queue/inbox/explorer.yaml" <<'YAML'
messages:
- id: msg_already
  content: 'already in live'
  read: true
  timestamp: '2026-01-01T00:00:00'
YAML
    # .corrupt has msg_already (skip) + msg_new (add).
    cat > "$SANDBOX/queue/inbox/explorer.yaml.corrupt" <<'YAML'
messages:
- content: 'should not be duplicated'
  id: msg_already
  read: true
  timestamp: '2026-01-01T00:00:00'
- content: 'fresh recovered'
  from: orchestrator
  id: msg_new
  read: false
  timestamp: '2026-01-02T00:00:00'
  type: task_assigned
YAML
    run env PROJECT_ROOT_OVERRIDE="$SANDBOX" bash "$SCRIPT" --apply
    # Live inbox should now contain both entries. yaml.safe_dump sorts keys,
    # so one entry starts with `- id:` and the other with `- content:`.
    local count
    count=$(grep -cE "^[[:space:]]*- (id|content):" "$SANDBOX/queue/inbox/explorer.yaml" 2>/dev/null | head -1)
    [ "${count:-0}" -eq 2 ]
}
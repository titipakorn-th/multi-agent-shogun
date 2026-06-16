#!/usr/bin/env bats
# test_inbox_write.bats — inbox_write.sh Unit Test
# Regression test specification T-001 ~ T-013 implementation
#
# Test configuration:
#   T-001~T-002: Argument validation
#   T-003~T-004: Normal write (new/append)
#   T-005: Message ID uniqueness
#   T-006~T-007: Default values (type/from)
#   T-008~T-009: Overflow Protection (50 message limit)
#   T-010: Retry on flock conflict
#   T-011: Escape handling of special characters
#   T-012: inbox initialization (directory auto-creation)
#   T-013~T-014: lock directory release

# --- Setup ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export INBOX_WRITE_SCRIPT="$PROJECT_ROOT/scripts/inbox_write.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"

    # Verify script existence (prerequisite)
    [ -f "$INBOX_WRITE_SCRIPT" ] || return 1

    # Verify venv python3 + PyYAML existence
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    # Create independent tmp directory per test
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/inbox_write_test.XXXXXX")"
    export TEST_INBOX_DIR="$TEST_TMPDIR/queue/inbox"
    mkdir -p "$TEST_INBOX_DIR"

    # Create wrapper script to point SCRIPT_DIR referenced by inbox_write.sh to tmp
    # Since inbox_write.sh resolves SCRIPT_DIR via SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)",
    # create test directory using symbolic link
    export TEST_SCRIPT_DIR="$TEST_TMPDIR/scripts"
    mkdir -p "$TEST_SCRIPT_DIR"

    # Copy original script (overwrite SCRIPT_DIR for testing)
    sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TEST_TMPDIR\"|" \
        "$PROJECT_ROOT/scripts/inbox_write.sh" > "$TEST_SCRIPT_DIR/inbox_write.sh"
    chmod +x "$TEST_SCRIPT_DIR/inbox_write.sh"

    # Symlink .venv from project root (inbox_write.sh references $SCRIPT_DIR/.venv/bin/python3)
    ln -sf "$PROJECT_ROOT/.venv" "$TEST_TMPDIR/.venv"

    export TEST_INBOX_WRITE="$TEST_SCRIPT_DIR/inbox_write.sh"
}

teardown() {
    # Delete test tmp directory
    [ -n "$TEST_TMPDIR" ] && [ -d "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# =============================================================================
# T-001: Argument validation — exit 1 when target is unspecified
# =============================================================================

@test "T-001: no arguments → exit 1 with Usage message" {
    run bash "$TEST_INBOX_WRITE"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

# =============================================================================
# T-002: Argument validation — exit 1 when content is unspecified
# =============================================================================

@test "T-002: only target, no content → exit 1" {
    run bash "$TEST_INBOX_WRITE" "test_agent"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

# =============================================================================
# T-002b: Argument validation — exit 1 when type/from are unspecified
# =============================================================================

@test "T-002b: missing type and from → exit 1" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "content only"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

# =============================================================================
# T-002c: Self-transmission guard — exit 1 when from==target
# =============================================================================

@test "T-002c: self-send (from==target) → exit 1 with REJECTED" {
    run bash "$TEST_INBOX_WRITE" "orchestrator" "self message" "cmd_new" "orchestrator"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "REJECTED" ]]
}

# =============================================================================
# T-003: Normal write — New inbox file creation
# =============================================================================

@test "T-003: normal write to new inbox file → messages array with correct fields" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "test message" "cmd_new" "shogun"
    [ "$status" -eq 0 ]

    # Confirm YAML file is created
    [ -f "$TEST_INBOX_DIR/test_agent.yaml" ]

    # Verify YAML with python3
    "$VENV_PYTHON" <<EOF
import yaml, sys

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

# messages array exists and has 1 entry
assert 'messages' in data, 'messages key not found'
assert len(data['messages']) == 1, f'Expected 1 message, got {len(data["messages"])}'

msg = data['messages'][0]

# Confirm existence of required fields
required_fields = ['id', 'from', 'timestamp', 'type', 'content', 'read']
for field in required_fields:
    assert field in msg, f'Field {field} not found in message'

# Verify field values
assert msg['from'] == 'shogun', f'Expected from=shogun, got {msg["from"]}'
assert msg['type'] == 'cmd_new', f'Expected type=cmd_new, got {msg["type"]}'
assert msg['content'] == 'test message', f'Expected content=test message, got {msg["content"]}'
assert msg['read'] == False, f'Expected read=False, got {msg["read"]}'
assert msg['id'].startswith('msg_'), f'Message ID should start with msg_, got {msg["id"]}'

print('T-003: PASS')
EOF
}

# =============================================================================
# T-004: Normal write — Append to existing inbox
# =============================================================================

@test "T-004: append to existing inbox → preserves existing messages, adds new one" {
    # First write
    bash "$TEST_INBOX_WRITE" "test_agent" "message1" "type1" "sender1"

    # Second write
    run bash "$TEST_INBOX_WRITE" "test_agent" "message2" "type2" "sender2"
    [ "$status" -eq 0 ]

    # Verify with python3
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 2, f'Expected 2 messages, got {len(data["messages"])}'

# Verify order (first write is at top)
assert data['messages'][0]['content'] == 'message1', 'First message mismatch'
assert data['messages'][1]['content'] == 'message2', 'Second message mismatch'

print('T-004: PASS')
EOF
}

# =============================================================================
# T-005: Message ID uniqueness
# =============================================================================

@test "T-005: message ID uniqueness → 2 rapid writes produce different IDs" {
    # Two consecutive writes
    bash "$TEST_INBOX_WRITE" "test_agent" "messageA" "test_type" "sender_a"
    bash "$TEST_INBOX_WRITE" "test_agent" "messageB" "test_type" "sender_b"

    # Verify with python3
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 2, 'Expected 2 messages'

id1 = data['messages'][0]['id']
id2 = data['messages'][1]['id']

assert id1 != id2, f'Message IDs should be different: {id1} == {id2}'

print('T-005: PASS')
EOF
}

# =============================================================================
# T-006: Default values — wake_up when type is unspecified
# =============================================================================

@test "T-006: missing type/from → exit 1 with Usage message" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "default test"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Usage" ]]
}

# =============================================================================
# T-007: Custom type/from specified
# =============================================================================

@test "T-007: custom type/from → 4th and 5th args set type and from correctly" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "custom message" "custom_type" "custom_sender"
    [ "$status" -eq 0 ]

    # Verify with python3
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]

assert msg['type'] == 'custom_type', f'Expected type=custom_type, got {msg["type"]}'
assert msg['from'] == 'custom_sender', f'Expected from=custom_sender, got {msg["from"]}'

print('T-007: PASS')
EOF
}

# =============================================================================
# T-008: Overflow Protection — Delete old read messages when exceeding 50 entries
# =============================================================================

@test "T-008: overflow protection at 50 messages → oldest read messages removed" {
    # Pre-create 60 read messages
    "$VENV_PYTHON" <<EOF
import yaml

messages = []
for i in range(60):
    messages.append({
        'id': f'msg_old_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'read message {i}',
        'read': True
    })

data = {'messages': messages}

with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # Write 1 new message
    run bash "$TEST_INBOX_WRITE" "test_agent" "new message" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # Verification: total 50 or fewer, new message exists
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) <= 50, f'Expected <= 50 messages, got {len(data["messages"])}'

# Confirm new message is included
new_msg_found = any(msg['content'] == 'new message' for msg in data['messages'])
assert new_msg_found, 'New message not found after overflow protection'

print('T-008: PASS')
EOF
}

# =============================================================================
# T-009: Overflow Protection — Unread messages are not deleted
# =============================================================================

@test "T-009: overflow preserves unread → unread messages are NOT removed even when over 50" {
    # Pre-create 20 unread + 40 read messages
    "$VENV_PYTHON" <<EOF
import yaml

messages = []

# 20 unread
for i in range(20):
    messages.append({
        'id': f'msg_unread_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T00:{i:02d}:00',
        'type': 'test_type',
        'content': f'unread message {i}',
        'read': False
    })

# 40 read
for i in range(40):
    messages.append({
        'id': f'msg_read_{i:03d}',
        'from': 'test_sender',
        'timestamp': f'2026-01-01T01:{i:02d}:00',
        'type': 'test_type',
        'content': f'read message {i}',
        'read': True
    })

data = {'messages': messages}

with open('$TEST_INBOX_DIR/test_agent.yaml', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
EOF

    # Write 1 new message (unread becomes 20 -> 21)
    run bash "$TEST_INBOX_WRITE" "test_agent" "new unread" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # Verification: all 21 unread messages are preserved
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

unread_count = sum(1 for msg in data['messages'] if not msg.get('read', False))

assert unread_count == 21, f'Expected 21 unread messages, got {unread_count}'

# Confirm all original unread messages remain
for i in range(20):
    found = any(msg['content'] == f'unread message {i}' for msg in data['messages'])
    assert found, f'Unread message {i} was removed'

print('T-009: PASS')
EOF
}

# =============================================================================
# T-010: flock retry on conflict (parallel write test)
# =============================================================================

@test "T-010: concurrent writes (flock test) → 8 parallel writes all succeed, no data loss" {
    # Create script for parallel writing
    cat > "$TEST_TMPDIR/parallel_write.sh" <<'SCRIPT_EOF'
#!/bin/bash
INBOX_WRITE="$1"
AGENT="$2"
ID="$3"
bash "$INBOX_WRITE" "$AGENT" "parallel message $ID" "concurrent" "writer_$ID" 2>/dev/null
SCRIPT_EOF
    chmod +x "$TEST_TMPDIR/parallel_write.sh"

    # Launch 8 parallel writing processes
    for i in {1..8}; do
        "$TEST_TMPDIR/parallel_write.sh" "$TEST_INBOX_WRITE" "test_agent" "$i" &
    done

    # Wait for all processes to complete
    wait

    # Verification: all 8 entries are written
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 8, f'Expected 8 messages, got {len(data["messages"])}'

# Confirm all IDs are unique
ids = [msg['id'] for msg in data['messages']]
assert len(ids) == len(set(ids)), 'Duplicate message IDs found'

print('T-010: PASS')
EOF
}

# =============================================================================
# T-011: Escape handling of special characters
# =============================================================================

@test "T-011: special characters in content → YAML special chars handled safely" {
    # Message containing YAML special characters
    SPECIAL_CONTENT="quotes: \"test\" and 'test'
includes newlines
colon: key: value
braces: {key: value}
array: [1, 2, 3]"

    run bash "$TEST_INBOX_WRITE" "test_agent" "$SPECIAL_CONTENT" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # Verification: special characters are correctly saved and restored
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]

expected_content = '''quotes: "test" and 'test'
includes newlines
colon: key: value
braces: {key: value}
array: [1, 2, 3]'''

assert msg['content'] == expected_content, f'Content mismatch: {msg["content"]}'

print('T-011: PASS')
EOF
}

# =============================================================================
# T-012: inbox initialization — directory auto-creation
# =============================================================================

@test "T-012: auto-create inbox directory → missing queue/inbox/ directory is created" {
    # Delete queue/inbox/ directory
    rm -rf "$TEST_INBOX_DIR"

    # Confirm directory does not exist
    [ ! -d "$TEST_INBOX_DIR" ]

    # Write message
    run bash "$TEST_INBOX_WRITE" "test_agent" "auto-creation test" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # Confirm directory and file are created
    [ -d "$TEST_INBOX_DIR" ]
    [ -f "$TEST_INBOX_DIR/test_agent.yaml" ]

    # Verify content
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert len(data['messages']) == 1, 'Expected 1 message after auto-create'

print('T-012: PASS')
EOF
}

@test "T-013: lock directory is released after successful write" {
    run bash "$TEST_INBOX_WRITE" "test_agent" "lock release" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    [ ! -d "$TEST_INBOX_DIR/test_agent.yaml.lock.d" ]
}

@test "T-014: lock directory is released after python failure" {
    rm -rf "$TEST_TMPDIR/.venv"
    mkdir -p "$TEST_TMPDIR/.venv/bin"
    cat > "$TEST_TMPDIR/.venv/bin/python3" <<'PYFAIL'
#!/usr/bin/env bash
exit 1
PYFAIL
    chmod +x "$TEST_TMPDIR/.venv/bin/python3"

    run bash "$TEST_INBOX_WRITE" "test_agent" "lock failure" "test_type" "other_sender"
    [ "$status" -ne 0 ]

    [ ! -d "$TEST_INBOX_DIR/test_agent.yaml.lock.d" ]
}

# =============================================================================
# T-015: Complex shell quoting and escaping
# =============================================================================

@test "T-015: complex shell quoting and escaping handled safely" {
    # Message containing all sorts of tricky quoting combinations
    COMPLEX_CONTENT="Hello \"world\"! Let's do 'single quotes' and triple '''quotes'''.
Colons: they are everywhere. Backslashes \\ too.
\$variables should not expand. \`backticks\` should not execute."

    run bash "$TEST_INBOX_WRITE" "test_agent" "$COMPLEX_CONTENT" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # Verification: everything is correctly saved and restored
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

msg = data['messages'][0]

expected_content = r"""Hello "world"! Let's do 'single quotes' and triple '''quotes'''.
Colons: they are everywhere. Backslashes \\ too.
\$variables should not expand. \`backticks\` should not execute."""

assert msg['content'] == expected_content, f"Content mismatch:\nActual: {repr(msg['content'])}\nExpected: {repr(expected_content)}"
print('T-015: PASS')
EOF
}

# =============================================================================
# T-016: Self-healing / auto-repair of corrupted YAML
# =============================================================================

@test "T-016: auto-repair corrupted YAML inbox file" {
    # 1. Create a corrupted YAML file
    echo "messages: {invalid_yaml_here: [:" > "$TEST_INBOX_DIR/test_agent.yaml"

    # 2. Write a new message to the corrupted inbox
    run bash "$TEST_INBOX_WRITE" "test_agent" "message after repair" "test_type" "other_sender"
    [ "$status" -eq 0 ]

    # 3. Confirm backup file is created
    [ -f "$TEST_INBOX_DIR/test_agent.yaml.corrupt" ]
    grep -q "invalid_yaml_here" "$TEST_INBOX_DIR/test_agent.yaml.corrupt"

    # 4. Confirm new inbox file is valid and contains the new message
    "$VENV_PYTHON" <<EOF
import yaml

with open('$TEST_INBOX_DIR/test_agent.yaml') as f:
    data = yaml.safe_load(f)

assert 'messages' in data
assert len(data['messages']) == 1
msg = data['messages'][0]
assert msg['content'] == 'message after repair'
print('T-016: PASS')
EOF
}


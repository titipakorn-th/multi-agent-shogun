#!/usr/bin/env bash
# inbox_write.sh — Write message to mailbox (with exclusive lock)
# Usage: bash scripts/inbox_write.sh <target_agent> <content> <type> <from>
# Example: bash scripts/inbox_write.sh orchestrator "Fixer 5, mission complete" report_received fixer

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="$3"
FROM="$4"

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ] || [ -z "$TYPE" ] || [ -z "$FROM" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> <type> <from>" >&2
    exit 1
fi

# Self-send guard: reject messages where sender == target
if [ "$FROM" = "$TARGET" ]; then
    echo "[inbox_write] REJECTED: self-send detected (from=$FROM, target=$TARGET)" >&2
    exit 1
fi

# Role validation (v2 topology): when config/settings.yaml declares
# topology=v2 with a roles block, the target must be one of those roles.
# v1 (legacy) accepts any role name. Hard cutover per spec — no aliases.
SETTINGS_FILE="$SCRIPT_DIR/config/settings.yaml"
if [ -f "$SETTINGS_FILE" ] && [ -x "$SCRIPT_DIR/.venv/bin/python3" ]; then
    # Temporarily disable set -e so the inner python exit code is captured
    set +e
    _validation="$("$SCRIPT_DIR/.venv/bin/python3" -c "
import sys, yaml
try:
    with open('$SETTINGS_FILE', 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    # If settings.yaml is unreadable, do not block writes — log a warning.
    print('WARN: cannot read settings.yaml:', e, file=sys.stderr)
    print('OK')
    sys.exit(0)

topology = data.get('topology', 'v1')
if topology != 'v2':
    # Legacy v1: accept any role
    print('OK')
    sys.exit(0)

roles = (data.get('roles') or {})
if not roles:
    # topology=v2 with no roles block — skip validation (no list to check against)
    print('OK')
    sys.exit(0)

if '$TARGET' not in roles:
    print(f'Error: unknown role \\'$TARGET\\'. Defined roles: {sorted(roles.keys())}', file=sys.stderr)
    sys.exit(2)

print('OK')
" 2>&1)"
    _validation_rc=$?
    set -e
    if [ "$_validation_rc" -ne 0 ] || [ "$_validation" != "OK" ]; then
        echo "$_validation" >&2
        exit 1
    fi
fi

# Initialize inbox if not exists
# dangling symlink recovery: if queue/inbox is a broken symlink, re-generate the link destination
_inbox_parent="$(dirname "$INBOX")"
if [ -L "$_inbox_parent" ] && [ ! -d "$_inbox_parent" ]; then
    mkdir -p "$(readlink "$_inbox_parent")"
fi
if [ ! -f "$INBOX" ]; then
    mkdir -p "$_inbox_parent"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp + 4 random bytes).
# Use `od` instead of `xxd` because `od` is available on both GNU/Linux and macOS runners by default.
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Cross-process lock: mkdir coordinates with OpenCode tools; flock is added when available.
LOCK_DIR="${LOCKFILE}.d"

_acquire_lock() {
    local i=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
        [ $i -ge 50 ] && return 1  # 5s timeout
    done

    if command -v flock &>/dev/null; then
        exec 200>"$LOCKFILE"
        flock -w 5 200 || {
            rmdir "$LOCK_DIR" 2>/dev/null
            return 1
        }
    fi
    return 0
}

_release_lock() {
    if command -v flock &>/dev/null; then
        exec 200>&-
    fi
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

# Atomic write with lock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if _acquire_lock; then
        trap _release_lock EXIT
        if INBOX_FILE="$INBOX" \
           MSG_ID="$MSG_ID" \
           FROM_AGENT="$FROM" \
           TIMESTAMP="$TIMESTAMP" \
           MSG_TYPE="$TYPE" \
           CONTENT="$CONTENT" \
           "$SCRIPT_DIR/.venv/bin/python3" -c '
import yaml, sys, os

try:
    inbox_path = os.environ["INBOX_FILE"]
    
    # Load existing inbox
    data = None
    if os.path.exists(inbox_path):
        try:
            with open(inbox_path, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
        except Exception as e:
            # Auto-repair/self-heal if corrupted
            print(f"[inbox_write] WARNING: {inbox_path} is corrupted ({e}). Backing up and resetting.", file=sys.stderr)
            import shutil
            try:
                shutil.copy2(inbox_path, inbox_path + ".corrupt")
            except Exception:
                pass
            data = {"messages": []}

    # Initialize if needed
    if not data:
        data = {}
    if not data.get("messages"):
        data["messages"] = []

    # Add new message
    new_msg = {
        "id": os.environ["MSG_ID"],
        "from": os.environ["FROM_AGENT"],
        "timestamp": os.environ["TIMESTAMP"],
        "type": os.environ["MSG_TYPE"],
        "content": os.environ["CONTENT"],
        "read": False
    }
    data["messages"].append(new_msg)

    # Overflow protection: keep max 50 messages
    if len(data["messages"]) > 50:
        msgs = data["messages"]
        unread = [m for m in msgs if not m.get("read", False)]
        read = [m for m in msgs if m.get("read", False)]
        # Keep all unread + newest 30 read messages
        data["messages"] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    import tempfile
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox_path), suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox_path)
    except Exception as write_err:
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise write_err

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
'; then
            STATUS=0
        else
            STATUS=$?
        fi
        _release_lock
        trap - EXIT
        [ $STATUS -eq 0 ] && exit 0
        attempt=$((attempt + 1))
        [ $attempt -lt $max_attempts ] && sleep 1
    else
        # Lock timeout
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done

#!/usr/bin/env bash
# tests/test_parallel_dispatch.sh
#
# Verifies the orchestrator can dispatch to 3 specialists in parallel.
#
# Test strategy:
#   1. Snapshot inbox message counts for explorer, fixer, observer.
#   2. Use bash & to launch 3 inbox_write calls in parallel (true concurrency).
#   3. Time the wall clock of the parallel block.
#   4. Verify all 3 inboxes received the new dispatch message.
#   5. Verify the message count incremented by exactly 1 per specialist.
#   6. Compare parallel vs serial wall clock (catches accidental serialization).
#
# This is a real behavioral test — exercises the actual inbox_write.sh pipeline
# including flock-based concurrency and atomic writes.
#
# Compatibility: pure bash 3.2+ (no associative arrays, since macOS ships bash 3.2).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INBOX_WRITE="${ROOT_DIR}/scripts/inbox_write.sh"
INBOX_DIR="${ROOT_DIR}/queue/inbox"

if [ ! -x "$INBOX_WRITE" ]; then
    echo "FAIL: $INBOX_WRITE not executable" >&2
    exit 1
fi

# Preflight: venv required by inbox_write.sh
if [ ! -x "${ROOT_DIR}/.venv/bin/python3" ]; then
    echo "SKIP: ${ROOT_DIR}/.venv/bin/python3 not found; skipping parallel dispatch test" >&2
    echo "       Run: python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    exit 0
fi

mkdir -p "$INBOX_DIR"

ROLES=(explorer fixer observer)
MARKER="parallel-dispatch-marker-$(date +%s)-$$"
FAIL=0

# Per-role before/after count files (bash 3.2 compatible — no associative arrays).
COUNT_DIR=$(mktemp -d)
trap "rm -rf $COUNT_DIR" EXIT

snapshot_count() {
    local role=$1
    local inbox="${INBOX_DIR}/${role}.yaml"
    if [ ! -f "$inbox" ]; then
        echo 0
        return
    fi
    # Try yq first; fall back to grep on '- id:' lines.
    if command -v yq &>/dev/null; then
        yq '.messages | length' "$inbox" 2>/dev/null || echo 0
    else
        grep -c "^- id:" "$inbox" 2>/dev/null || echo 0
    fi
}

# Snapshot existing message counts.
for role in "${ROLES[@]}"; do
    snapshot_count "$role" > "${COUNT_DIR}/${role}.before"
done

# --- Parallel dispatch block -----------------------------------------------
START_NS=$(date +%s%N)
PIDS=()
for role in "${ROLES[@]}"; do
    (
        bash "$INBOX_WRITE" "$role" "$MARKER" task_assigned orchestrator
    ) &
    PIDS+=($!)
done

# Wait for all 3 to finish.
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        echo "FAIL: inbox_write sub-process pid=$pid exited non-zero" >&2
        FAIL=1
    fi
done
END_NS=$(date +%s%N)
PARALLEL_MS=$(( (END_NS - START_NS) / 1000000 ))
# ---------------------------------------------------------------------------

# --- Serial baseline (for comparison) -------------------------------------
START_NS=$(date +%s%N)
for role in "${ROLES[@]}"; do
    bash "$INBOX_WRITE" "$role" "${MARKER}-serial" task_assigned orchestrator >/dev/null
done
END_NS=$(date +%s%N)
SERIAL_MS=$(( (END_NS - START_NS) / 1000000 ))
# ---------------------------------------------------------------------------

echo "[parallel_dispatch] parallel=${PARALLEL_MS}ms serial=${SERIAL_MS}ms"

# Verify all 3 inboxes received the marker and the count delta is correct.
for role in "${ROLES[@]}"; do
    inbox="${INBOX_DIR}/${role}.yaml"
    if [ ! -f "$inbox" ]; then
        echo "FAIL: $inbox missing after dispatch" >&2
        FAIL=1
        continue
    fi

    if ! grep -q "$MARKER" "$inbox"; then
        echo "FAIL: $role inbox missing parallel marker" >&2
        FAIL=1
    fi

    AFTER=$(snapshot_count "$role")
    BEFORE=$(cat "${COUNT_DIR}/${role}.before")
    EXPECTED_DELTA=2   # 1 parallel + 1 serial
    ACTUAL_DELTA=$((AFTER - BEFORE))
    if [ "$ACTUAL_DELTA" -ne "$EXPECTED_DELTA" ]; then
        echo "FAIL: $role expected $EXPECTED_DELTA new messages, got $ACTUAL_DELTA (before=$BEFORE after=$AFTER)" >&2
        FAIL=1
    fi
done

# Verify parallel dispatch was not catastrophically slower than serial.
# Allow some slack — flock + python startup has baseline overhead.
if [ "$SERIAL_MS" -gt 0 ]; then
    # Use awk for floating-point division.
    RATIO=$(awk -v p="$PARALLEL_MS" -v s="$SERIAL_MS" 'BEGIN { printf "%.2f", p / s }')
    echo "[parallel_dispatch] parallel/serial ratio: $RATIO"
    # If parallel > 2x serial, something serialized them (catches lock contention bugs).
    IS_SLOW=$(awk -v r="$RATIO" 'BEGIN { print (r > 2.0) ? 1 : 0 }')
    if [ "$IS_SLOW" -eq 1 ]; then
        echo "WARN: parallel dispatch ratio ($RATIO) suggests serialization or lock contention" >&2
        # Soft warning, not a hard fail (CI variance can be high).
    fi
fi

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: parallel dispatch to 3 specialists recorded in inboxes (parallel=${PARALLEL_MS}ms, serial=${SERIAL_MS}ms)"
fi
exit $FAIL
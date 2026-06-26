#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# weekly_health_review.sh — Task 14 gap-closure
# ═══════════════════════════════════════════════════════════════
# Recurring (weekly) health-review checklist that inspects:
#   - Queue size and command activity
#   - Corrupt files / stale tmp / oversized inboxes
#   - Checkpoint latency (time since last orchestrator → shogun message)
#   - Validation misses (cmds marked done without required_validations)
#   - Test skips (SKIP = FAIL per CLAUDE.md Test Rules)
#   - Instruction drift (CLAUDE.md vs AGENTS.md vs generated/)
#
# The output is a markdown summary suitable for dashboard.md or Telegram.
#
# Usage:
#   bash scripts/weekly_health_review.sh [--since-days N] [--threshold N]
#
# Exit codes:
#   0  — all checks healthy
#   1  — usage error
#   2  — thresholds exceeded; recommendations emitted
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"

SINCE_DAYS=7
THRESHOLD=3  # emit a recommendation per check that exceeds this count

while [ $# -gt 0 ]; do
    case "$1" in
        --since-days) SINCE_DAYS="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ponytail: prefer a python3 with PyYAML; .venv/bin first, then system fallback.
PY=""
for candidate in "$PROJECT_ROOT/.venv/bin/python3" "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import yaml' 2>/dev/null; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    PY="$(command -v python3 2>/dev/null || echo python3)"
fi

RECS=()
WARNINGS=()

# ─── 1. Queue size & activity ───
echo "## 1. Queue size & activity"
if [ -f "$PROJECT_ROOT/queue/shogun_to_orchestrator.yaml" ]; then
    "$PY" - "$PROJECT_ROOT/queue/shogun_to_orchestrator.yaml" <<'PY'
import sys, yaml
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = yaml.safe_load(f) or {}
except Exception as e:
    print(f"  WARN: cannot read queue file: {e}")
    sys.exit()
key = "commands" if "commands" in d else "queue"
items = d.get(key, []) or []
active = sum(1 for c in items if isinstance(c, dict) and c.get("status") in ("pending", "in_progress"))
terminal = sum(1 for c in items if isinstance(c, dict) and c.get("status") in ("done", "cancelled", "paused"))
print(f"  active commands: {active}")
print(f"  terminal in active file (needs archive): {terminal}")
PY
fi

# ─── 2. Queue hygiene ───
echo ""
echo "## 2. Queue hygiene"
HYGIENE_OUTPUT=$("$PY" "$PROJECT_ROOT/scripts/queue_health_check.py" --queue-dir "$PROJECT_ROOT/queue" 2>&1 || true)
echo "$HYGIENE_OUTPUT" | grep -E "^  (corrupt|stale|oversized)" || echo "  (clean)"
CORRUPT_COUNT=$(echo "$HYGIENE_OUTPUT" | grep -c "corrupt inbox backup" || true)
STALE_COUNT=$(echo "$HYGIENE_OUTPUT" | grep -c "stale tmp file" || true)
OVERSIZE_COUNT=$(echo "$HYGIENE_OUTPUT" | grep -c "oversized inbox" || true)
[ "$CORRUPT_COUNT" -ge "$THRESHOLD" ] && RECS+=("- $CORRUPT_COUNT corrupt inbox backups — investigate yaml writer race conditions")
[ "$STALE_COUNT" -ge "$THRESHOLD" ] && RECS+=("- $STALE_COUNT stale tmp files — flock may be failing in inbox_write.sh")
[ "$OVERSIZE_COUNT" -ge "$THRESHOLD" ] && RECS+=("- $OVERSIZE_COUNT oversized inboxes — check specialist agent's inbox_write handler")

# ─── 3. Checkpoint latency ───
echo ""
echo "## 3. Checkpoint latency"
if [ -f "$PROJECT_ROOT/queue/orchestrator_checkpoints.yaml" ]; then
    "$PY" - "$PROJECT_ROOT/queue/orchestrator_checkpoints.yaml" "$SINCE_DAYS" <<'PY'
import sys, yaml
from datetime import datetime, timezone, timedelta
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = yaml.safe_load(f) or {}
    entries = d.get("checkpoints", []) or []
    if not entries:
        print("  no checkpoints recorded")
        sys.exit()
    last_ts = entries[-1].get("timestamp")
    if last_ts:
        try:
            last_dt = datetime.fromisoformat(last_ts)
            now = datetime.now(last_dt.tzinfo) if last_dt.tzinfo else datetime.now()
            age_hours = (now - last_dt).total_seconds() / 3600
            print(f"  last checkpoint: {last_ts} ({age_hours:.1f}h ago)")
        except Exception as e:
            print(f"  WARN: cannot parse last timestamp: {e}")
    # Distribution by phase
    by_phase = {}
    for e in entries:
        p = e.get("phase", "unknown")
        by_phase[p] = by_phase.get(p, 0) + 1
    print("  phase counts:")
    for p, n in sorted(by_phase.items()):
        print(f"    {p}: {n}")
except Exception as e:
    print(f"  WARN: {e}")
PY
else
    echo "  no checkpoint ledger yet (queue/orchestrator_checkpoints.yaml missing)"
fi

# ─── 4. Validation misses (cmds without required_validations) ───
# ponytail: a "validation miss" is a `status: done` command whose entry has
# no `required_validations` (absent or empty list). Grep/awk heuristics over
# YAML were inverted and brittle; Python parsing catches real structure.
echo ""
echo "## 4. Validation gate coverage"
MISSING_VALIDATION=$(MISSING_VALIDATION_OUT=0 "$PY" - "$PROJECT_ROOT" <<'PY'
import glob, os, sys, warnings
import yaml

project_root = sys.argv[1]
archive_dir = os.path.join(project_root, "queue", "archive")
ledger_path = os.path.join(project_root, "queue", "shogun_to_orchestrator_archive.yaml")


def _is_miss(cmd: dict) -> bool:
    if not isinstance(cmd, dict):
        return False
    if cmd.get("status") != "done":
        return False
    # Missing or empty required_validations both count as a miss.
    rv = cmd.get("required_validations")
    return not rv


def _extract_commands(doc) -> list:
    if not isinstance(doc, dict):
        return []
    cmds = doc.get("commands")
    if cmds is None:
        cmds = doc.get("queue", [])
    return cmds if isinstance(cmds, list) else []


def _count_file(path: str, *, source: str) -> int:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        return 0
    except yaml.YAMLError as e:
        print(f"  WARN: cannot parse {source} ({path}): {e}")
        return 0
    except Exception as e:
        print(f"  WARN: cannot read {source} ({path}): {e}")
        return 0
    return sum(1 for c in _extract_commands(doc) if _is_miss(c))


count = 0
if os.path.isdir(archive_dir):
    for path in sorted(glob.glob(os.path.join(archive_dir, "*.yaml"))):
        count += _count_file(path, source="archive")
if os.path.isfile(ledger_path):
    count += _count_file(ledger_path, source="ledger")
print(count)
PY
)
MISSING_VALIDATION="${MISSING_VALIDATION:-0}"

echo "  cmds marked done WITHOUT required_validations: $MISSING_VALIDATION"
[ "$MISSING_VALIDATION" -ge "$THRESHOLD" ] && RECS+=("- $MISSING_VALIDATION cmds marked done without required_validations — gate enforcement may be missing")

# ─── 5. Test skip count ───
echo ""
echo "## 5. Test skip count"
SKIP_COUNT=$(find "$PROJECT_ROOT/tests" -name "*.bats" -o -name "*.sh" -o -name "*.py" 2>/dev/null | \
    xargs grep -l "skip " 2>/dev/null | head -20 | \
    xargs grep -c "^[[:space:]]*skip" 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}')
echo "  skip directives found: ${SKIP_COUNT:-0}"
[ "${SKIP_COUNT:-0}" -ge "$THRESHOLD" ] && RECS+=("- $SKIP_COUNT skipped tests — investigate prerequisites or remove obsolete tests")

# ─── 6. Instruction drift ───
echo ""
echo "## 6. Instruction drift"
DRIFT=$(git -C "$PROJECT_ROOT" diff --stat "$PROJECT_ROOT/instructions/generated/" "$PROJECT_ROOT/AGENTS.md" "$PROJECT_ROOT/.github/copilot-instructions.md" "$PROJECT_ROOT/.opencode/agents/" 2>/dev/null | tail -1)
echo "  $DRIFT"

# ─── Summary ───
echo ""
echo "## Summary"
if [ ${#RECS[@]} -eq 0 ]; then
    echo "  ✅ All checks healthy. No new tasks recommended."
    exit 0
fi

echo "  ⚠️  ${#RECS[@]} recommendation(s) for new tasks:"
for r in "${RECS[@]}"; do
    echo "    $r"
done
echo ""
echo "  Run \`git diff --stat\` on the instruction output dir if drift is non-zero."
exit 2
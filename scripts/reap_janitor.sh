#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# reap_janitor.sh — Janitor for stale queue artifacts (W6)
# ═══════════════════════════════════════════════════════════════
# Reaps:
#   - queue/*.tmp older than AGE_MINUTES (default 60) — atomic-write leftovers
#   - queue/*.lock older than AGE_MINUTES — held past flock lifetime
#   - queue/*.bak.test (test backup files left after a bats run)
#   - queue/reports/*.yaml when no live task references the report's writer
#
# Usage:
#   bash scripts/reap_janitor.sh                  # dry-run (default)
#   bash scripts/reap_janitor.sh --apply          # actually delete
#   bash scripts/reap_janitor.sh --age-minutes N  # override age threshold
#
# Exit codes:
#   0 — clean (nothing to do or dry-run successful)
#   1 — usage error
#   2 — at least one reap action succeeded under --apply
#
# ponytail: a `find … -mmin +N -print` + `rm` loop. The whole script is
# ~50 lines because we deliberately do NOT model the queue as a graph.
# When the queue outgrows a find-based reaper, replace with a real cleanup
# service. Until then, this is enough.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
QUEUE_DIR="$PROJECT_ROOT/queue"

AGE_MINUTES=60
APPLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --age-minutes) AGE_MINUTES="$2"; shift 2 ;;
        --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

candidates=()

# 1. Stale atomic-write tmp files.
while IFS= read -r f; do
    candidates+=("$f")
done < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name "*.tmp" -mmin +"$AGE_MINUTES" 2>/dev/null)

# 2. Stale flock lock files.
while IFS= read -r f; do
    candidates+=("$f")
done < <(find "$QUEUE_DIR" -maxdepth 1 -type f -name "*.lock" -mmin +"$AGE_MINUTES" 2>/dev/null)

# 3. Test backup files left after a bats run (these have no retention need).
while IFS= read -r f; do
    candidates+=("$f")
done < <(find "$QUEUE_DIR" -type f -name "*.bak.test" 2>/dev/null)

# 4. Orphaned report YAMLs whose writer has no live task. Conservative
# heuristic: any *_{role}_report.yaml in queue/reports/ whose target role
# has no entry in queue/tasks/{role}.yaml with status pending/in_progress/assigned.
REPORTS_DIR="$QUEUE_DIR/reports"
if [ -d "$REPORTS_DIR" ]; then
    for report in "$REPORTS_DIR"/*_report.yaml; do
        [ -f "$report" ] || continue
        base=$(basename "$report")
        # Strip "<role>_report.yaml" suffix
        role="${base%_report.yaml}"
        task_file="$QUEUE_DIR/tasks/${role}.yaml"
        if [ ! -f "$task_file" ]; then
            candidates+=("$report")
            continue
        fi
        # If the role has no live task entry, treat the report as orphan.
        if ! grep -qE "status:[[:space:]]*(pending|in_progress|assigned)" "$task_file" 2>/dev/null; then
            candidates+=("$report")
        fi
    done
fi

if [ "${#candidates[@]}" -eq 0 ]; then
    echo "reap_janitor: nothing to do (age>${AGE_MINUTES}m, queue=$QUEUE_DIR)"
    exit 0
fi

echo "reap_janitor: ${#candidates[@]} candidate(s)$([ "$APPLY" -eq 1 ] && echo " — APPLYING" || echo " — dry-run (use --apply to remove)")"
for f in "${candidates[@]}"; do
    if [ "$APPLY" -eq 1 ]; then
        rm -f -- "$f" && echo "  REMOVED: $f" || echo "  FAILED:  $f" >&2
    else
        echo "  would remove: $f"
    fi
done

[ "$APPLY" -eq 1 ] && exit 2 || exit 0
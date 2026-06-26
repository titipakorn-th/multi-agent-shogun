#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# reap_inbox.sh — T1 inbox rotation + archival (W1)
# ═══════════════════════════════════════════════════════════════
# When a mailbox exceeds --max-entries OR has more than --max-read read
# entries, move excess read entries to queue/archive/inbox/{agent}-{date}.yaml.
# Unread messages are NEVER archived. Last K read entries are kept in-place
# for context (so the consumer still sees recent history).
#
# Usage:
#   bash scripts/reap_inbox.sh                         # default thresholds
#   bash scripts/reap_inbox.sh --agent shogun          # one agent only
#   bash scripts/reap_inbox.sh --max-entries 500 --max-read 200 --keep-read 50
#   bash scripts/reap_inbox.sh --dry-run               # list only
#
# Exit codes:
#   0 — nothing reaped (or dry-run only)
#   1 — usage error
#   2 — at least one agent had entries archived
#
# ponytail: a YAML roundtrip via Python. The reason it's not pure bash is
# that YAML comments / quoting / multi-line content make awk/grep unsafe
# for splitting entries. The Python body is ~30 lines. Add a streaming
# pipeline when an inbox exceeds 10k entries (none do today).
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
INBOX_DIR="$PROJECT_ROOT/queue/inbox"
ARCHIVE_DIR="$PROJECT_ROOT/queue/archive/inbox"

MAX_ENTRIES=200
MAX_READ=150
KEEP_READ=20
DRY_RUN=0
SINGLE_AGENT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --agent) SINGLE_AGENT="$2"; shift 2 ;;
        --max-entries) MAX_ENTRIES="$2"; shift 2 ;;
        --max-read) MAX_READ="$2"; shift 2 ;;
        --keep-read) KEEP_READ="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --help|-h) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# ponytail: prefer system python3 with PyYAML — same pattern as weekly_health_review.sh.
PY=""
for candidate in "$PROJECT_ROOT/.venv/bin/python3" "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import yaml' 2>/dev/null; then
        PY="$candidate"
        break
    fi
done
if [ -z "$PY" ]; then
    echo "reap_inbox: python3 with PyYAML is required" >&2
    exit 1
fi

if [ ! -d "$INBOX_DIR" ]; then
    echo "reap_inbox: $INBOX_DIR not found" >&2
    exit 1
fi

if [ -n "$SINGLE_AGENT" ]; then
    targets=("$INBOX_DIR/${SINGLE_AGENT}.yaml")
else
    targets=()
    for f in "$INBOX_DIR"/*.yaml; do
        # Skip mailbox backups (.corrupt, .lock, .tmp).
        case "$f" in
            *.corrupt|*.lock|*.tmp) continue ;;
        esac
        targets+=("$f")
    done
fi

reaped_any=0

for inbox in "${targets[@]}"; do
    [ -f "$inbox" ] || continue
    base=$(basename "$inbox" .yaml)

    # Pre-check: count entries and read:true via grep. Use `^- ` (entry start)
    # since the entry's `-` is on the first line of each message.
    total=$(grep -cE "^[[:space:]]*- " "$inbox" 2>/dev/null | head -1)
    total="${total:-0}"
    read_count=$(grep -c "read: true" "$inbox" 2>/dev/null | head -1)
    read_count="${read_count:-0}"

    if [ "$total" -lt "$MAX_ENTRIES" ] && [ "$read_count" -lt "$MAX_READ" ]; then
        continue
    fi

    # Capture Python output; if it emits nothing, nothing was reaped.
    out=$("$PY" - "$inbox" "$base" "$ARCHIVE_DIR" "$KEEP_READ" "$DRY_RUN" <<'PY'
import os, sys, datetime, yaml

inbox_path, agent, archive_dir, keep_read_s, dry_run_s = sys.argv[1:6]
keep_read = int(keep_read_s)
dry_run = dry_run_s == "1"

with open(inbox_path, "r", encoding="utf-8") as fh:
    doc = yaml.safe_load(fh) or {}

if not isinstance(doc, dict):
    sys.exit(0)

# Find the messages list under any key (messages / queue / commands).
msgs = None
for key in ("messages", "queue", "commands"):
    if key in doc and isinstance(doc[key], list):
        msgs = doc[key]
        del doc[key]
        break

if msgs is None:
    sys.exit(0)

# Partition: unread (never reap), read-but-keep (last K), read-to-archive (rest).
unread = [m for m in msgs if isinstance(m, dict) and m.get("read") is False]
read_all = [m for m in msgs if isinstance(m, dict) and m.get("read") is True]
keep = read_all[-keep_read:] if keep_read > 0 else []
archive = read_all[:-keep_read] if keep_read > 0 else read_all

if not archive:
    sys.exit(0)

if not dry_run:
    os.makedirs(archive_dir, exist_ok=True)
    today = datetime.date.today().isoformat()
    archive_path = os.path.join(archive_dir, f"{agent}-{today}.yaml")
    existing = []
    if os.path.isfile(archive_path):
        with open(archive_path, "r", encoding="utf-8") as fh:
            existing = (yaml.safe_load(fh) or {}).get("messages", [])
    combined = existing + archive
    with open(archive_path, "w", encoding="utf-8") as fh:
        yaml.safe_dump({"messages": combined}, fh, allow_unicode=True, sort_keys=False)

    # Rewrite live inbox: unread + kept-read only.
    new_msgs = unread + keep
    doc["messages"] = new_msgs
    with open(inbox_path, "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh, allow_unicode=True, sort_keys=False)

print(f"  {agent}: archived {len(archive)} read entries (kept {len(keep)}, unread {len(unread)})")
PY
)
    [ -n "$out" ] && reaped_any=1
    [ -n "$out" ] && echo "$out"
done

if [ "$reaped_any" -eq 0 ]; then
    echo "reap_inbox: nothing to do (max-entries=$MAX_ENTRIES, max-read=$MAX_READ)"
    exit 0
fi

[ "$DRY_RUN" -eq 1 ] && echo "reap_inbox: dry-run complete" || echo "reap_inbox: archival complete"
exit 2
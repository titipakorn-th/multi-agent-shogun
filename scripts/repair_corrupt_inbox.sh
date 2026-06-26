#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# repair_corrupt_inbox.sh — T3 corruption detect/quarantine/replay (W2)
# ═══════════════════════════════════════════════════════════════
# For each inbox file under queue/inbox/:
#   1. If it parses as YAML — skip (healthy).
#   2. If it does NOT parse:
#      - If .corrupt backup exists, salvage intact entries from the .corrupt.
#      - Otherwise quarantine current file to .corrupt (atomic rename).
#      - Salvage intact entries via line-level block parsing; rewrite inbox.
#      - Emit `inbox_corrupt` alert.
#
# Also triages existing queue/inbox/*.corrupt files: if they can be salvaged,
# writes recovered entries back to the live inbox (merged, deduped by id).
#
# Usage:
#   bash scripts/repair_corrupt_inbox.sh          # detect + salvage + alert
#   bash scripts/repair_corrupt_inbox.sh --triage # only triage existing .corrupt files
#   bash scripts/repair_corrupt_inbox.sh --dry-run
#
# Exit codes:
#   0 — all inboxes healthy
#   2 — at least one inbox repaired (or .corrupt file triaged)
#
# ponytail: line-level YAML recovery, not a parser. We split on `- content:`
# boundaries (every inbox message starts with `- content:`) and keep only
# blocks that also have a closing `  timestamp: '...'` line. Fragile against
# content fields that contain `- content:` substrings, but acceptable for
# the message stream we control.
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${PROJECT_ROOT_OVERRIDE:-$(dirname "$SCRIPT_DIR")}"
INBOX_DIR="$PROJECT_ROOT/queue/inbox"
LOG_FILE="$PROJECT_ROOT/logs/corrupt_inbox.log"
mkdir -p "$(dirname "$LOG_FILE")"

DRY_RUN=0
TRIAGE_ONLY=0
APPLY=0
PURGE_CORRUPT=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --triage) TRIAGE_ONLY=1; shift ;;
        --apply) APPLY=1; shift ;;
        --purge-corrupt) PURGE_CORRUPT=1; shift ;;
        --help|-h) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done
# Default: triage only (write recovered to queue/archive/inbox-recovered/)
# unless --apply is given. This prevents accidentally re-delivering days-old
# stale messages from a corrupt backup.

log_line() { echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE" >&2; }

# ponytail: prefer system python3 with PyYAML — same fallback as siblings.
PY=""
for candidate in "$PROJECT_ROOT/.venv/bin/python3" "$(command -v python3 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" -c 'import yaml' 2>/dev/null; then PY="$candidate"; break; fi
done
[ -z "$PY" ] && { echo "repair_corrupt_inbox: python3+yaml required" >&2; exit 1; }

repaired=0
healthy=0

# ─── Phase 1: triage existing .corrupt files ───
log_line "=== Phase 1: triage existing .corrupt files ==="
for corrupt_file in "$INBOX_DIR"/*.corrupt; do
    [ -f "$corrupt_file" ] || continue
    base=$(basename "$corrupt_file" .yaml.corrupt)
    live="$INBOX_DIR/${base}.yaml"
    log_line "triage: $base (corrupt=$(wc -l < "$corrupt_file" 2>/dev/null) lines)"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_line "  would attempt line-level salvage"
        continue
    fi

    # Without --apply, write recovered entries to a separate review file
    # so the operator can inspect before merging into the live inbox.
    if [ "$APPLY" -eq 0 ]; then
        review_dir="$PROJECT_ROOT/queue/archive/inbox-recovered"
        mkdir -p "$review_dir"
        live="$review_dir/${base}.recovered.yaml"
        log_line "  writing recovered entries to $live (review-only; pass --apply to merge)"
    fi

    out=$("$PY" - "$corrupt_file" "$live" "$base" <<'PY'
import os, re, sys, yaml

corrupt_path, live_path, agent = sys.argv[1], sys.argv[2], sys.argv[3]

with open(corrupt_path, "r", encoding="utf-8") as fh:
    text = fh.read()

# Salvage strategy: split on "- content:" boundaries; keep blocks that have
# a closing timestamp. Drop any block that is truncated mid-key.
blocks = []
lines = text.splitlines()
i = 0
header = "messages:\n"
while i < len(lines):
    line = lines[i]
    if re.match(r"^-\s+content:", line) or line.startswith("- content:"):
        block = [line]
        i += 1
        while i < len(lines):
            nxt = lines[i]
            # Stop at next entry start.
            if re.match(r"^-\s+content:", nxt) or nxt.startswith("- content:"):
                break
            block.append(nxt)
            i += 1
        blocks.append(block)
    else:
        i += 1

recovered = []
for block in blocks:
    joined = "\n".join(block)
    if "timestamp:" not in joined:
        continue
    if "id:" not in joined:
        continue
    # Try to parse this block in isolation.
    try:
        parsed = yaml.safe_load("messages:\n" + joined + "\n")
        if isinstance(parsed, dict) and parsed.get("messages"):
            recovered.extend(parsed["messages"])
    except Exception:
        continue

# Dedup by id, keep latest read state.
existing = []
if os.path.isfile(live_path):
    try:
        with open(live_path, "r", encoding="utf-8") as fh:
            d = yaml.safe_load(fh) or {}
        existing = d.get("messages", []) if isinstance(d, dict) else []
    except Exception:
        existing = []

by_id = {}
for m in existing:
    if isinstance(m, dict) and m.get("id"):
        by_id[m["id"]] = m
for m in recovered:
    if isinstance(m, dict) and m.get("id"):
        # Prefer live (existing) entry; only fill gaps from recovered.
        by_id.setdefault(m["id"], m)

merged = list(by_id.values())
print(f"  salvaged {len(recovered)} entries, merged {len(merged)} total into {agent}")

if merged and not os.path.isfile(live_path):
    with open(live_path, "w", encoding="utf-8") as fh:
        yaml.safe_dump({"messages": merged}, fh, allow_unicode=True, sort_keys=False)
    print(f"  recreated live inbox: {live_path}")
elif merged and os.path.isfile(live_path):
    with open(live_path, "w", encoding="utf-8") as fh:
        yaml.safe_dump({"messages": merged}, fh, allow_unicode=True, sort_keys=False)
    print(f"  merged salvaged entries into live inbox")
else:
    print(f"  no recoverable entries")
PY
)
    [ -n "$out" ] && echo "$out"
    [ -n "$out" ] && repaired=1

    # --purge-corrupt: once salvaged and merged, drop the original .corrupt
    # so the directory reaches a clean state. U1 (round-2 review) requires 0
    # .corrupt files; the salvage step is required first.
    if [ "$PURGE_CORRUPT" -eq 1 ] && [ "$APPLY" -eq 1 ] && [ -f "$corrupt_file" ]; then
        rm -f "$corrupt_file"
        log_line "  purged: $corrupt_file"
    fi
done

# ─── Phase 2: scan live inboxes for unread corruption ───
if [ "$TRIAGE_ONLY" -eq 0 ]; then
log_line "=== Phase 2: scan live inboxes ==="
for inbox in "$INBOX_DIR"/*.yaml; do
    [ -f "$inbox" ] || continue
    base=$(basename "$inbox" .yaml)

    # Cheap parse check: hand to yaml.safe_load.
    if "$PY" -c "import sys, yaml; yaml.safe_load(open(sys.argv[1]))" "$inbox" 2>/dev/null; then
        healthy=$((healthy + 1))
        continue
    fi

    log_line "CORRUPTED: $base (live inbox fails YAML parse)"

    if [ "$DRY_RUN" -eq 1 ]; then
        log_line "  would quarantine to ${inbox}.corrupt and salvage"
        continue
    fi

    # Quarantine: rename current to .corrupt (preserves original on disk).
    quarantine="${inbox}.corrupt"
    if [ ! -f "$quarantine" ]; then
        mv "$inbox" "$quarantine"
        log_line "  quarantined: $quarantine"
    else
        # Both .corrupt and live exist; live is corrupted on top. Keep .corrupt,
        # remove the corrupted live file so triage can re-merge.
        rm -f "$inbox"
        log_line "  removed corrupted live; .corrupt preserved"
    fi

    # Emit inbox_corrupt alert to Shogun (best-effort, never block).
    alert_msg="🚨 [corrupt_inbox] $base: live YAML unparseable, quarantined + triage pending"
    if [ -x "$SCRIPT_DIR/inbox_write.sh" ]; then
        bash "$SCRIPT_DIR/inbox_write.sh" shogun "$alert_msg" inbox_corrupt repair_corrupt_inbox 2>/dev/null || true
    fi
    log_line "  alert emitted: $alert_msg"
    repaired=1
done
fi

log_line "summary: healthy=$healthy repaired=$repaired"
if [ "$repaired" -gt 0 ]; then
    exit 2
fi
exit 0
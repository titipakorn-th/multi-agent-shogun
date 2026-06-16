#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# migrate_to_v2.sh — Migrate a v1 (karo/ashigaru/gunshi) layout
# to v2 (orchestrator + 7 specialists).
#
# What it does:
#   1. Detect running v1 tmux sessions (warning only)
#   2. Run validate_settings.sh on the new schema (must pass)
#   3. Back up queue/ and dashboard.md to logs/migration/v1-to-v2-{ts}/
#   4. Rename inbox/{old}.yaml → inbox/{new}.yaml for each mapping
#   5. Rename tasks/{old}.yaml → tasks/{new}.yaml
#   6. Rename reports/{old}_report.yaml → reports/{new}_report.yaml
#   7. Report counts and exit successfully
#
# What it does NOT do (out of scope for sub-D):
#   - Spawn v2 topology (handled by shutsujin_departure_v2.sh)
#   - Tear down v1 tmux sessions (operator decision)
#   - Smoke-test dispatcher (handled in shutsujin_departure_v2.sh hookup)
#
# Usage: bash scripts/migrate_to_v2.sh [--dry-run]
#   --dry-run  Print planned actions without renaming anything
#
# Mapping (per spec):
#   karo       → orchestrator
#   ashigaru1  → explorer
#   ashigaru2  → librarian
#   ashigaru3  → oracle
#   ashigaru4  → designer
#   ashigaru5  → fixer
#   ashigaru6  → observer
#   ashigaru7  → council
#   gunshi     → oracle   (gunshi folds into oracle; if both exist,
#                          gunshi_report.yaml merges into oracle_report.yaml)
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

echo "[migrate] starting v1 → v2 migration (dry_run=$DRY_RUN)"

# ─── Step 1: detect running v1 tmux sessions ───────────────────
if command -v tmux &>/dev/null; then
    RUNNING_V1=$(tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep -E '^(multiagent|shogun)$' || true)
    if [ -n "$RUNNING_V1" ]; then
        echo "[migrate] WARNING: v1 tmux sessions detected:" >&2
        echo "$RUNNING_V1" | sed 's/^/  /' >&2
        echo "[migrate]          teardown should happen AFTER successful smoke-test (sub-A handles spawn/teardown)" >&2
    else
        echo "[migrate] no v1 tmux sessions running"
    fi
else
    echo "[migrate] tmux not available; skipping session check"
fi

# ─── Step 2: validate settings schema ──────────────────────────
SETTINGS_FILE="$SCRIPT_DIR/config/settings.yaml"
if [ -f "$SETTINGS_FILE" ]; then
    if ! bash "$SCRIPT_DIR/scripts/validate_settings.sh" "$SETTINGS_FILE" >/dev/null; then
        echo "[migrate] FAIL: settings.yaml does not validate. Fix schema first." >&2
        exit 1
    fi
    echo "[migrate] settings.yaml validates"
else
    echo "[migrate] no settings.yaml found at $SETTINGS_FILE — copy from config/settings.yaml.sample first" >&2
    exit 1
fi

# ─── Step 3: back up queue + dashboard ──────────────────────────
TIMESTAMP="$(date +%Y%m%dT%H%M%S)"
BACKUP="$SCRIPT_DIR/logs/migration/v1-to-v2-$TIMESTAMP"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[migrate] (dry-run) would create backup at $BACKUP"
else
    mkdir -p "$BACKUP"
    if [ -d "$SCRIPT_DIR/queue" ]; then
        cp -R "$SCRIPT_DIR/queue" "$BACKUP/"
        echo "[migrate] backed up queue/ → $BACKUP/queue"
    fi
    if [ -f "$SCRIPT_DIR/dashboard.md" ]; then
        cp "$SCRIPT_DIR/dashboard.md" "$BACKUP/"
        echo "[migrate] backed up dashboard.md"
    fi
fi

# ─── Step 4-6: rename inbox/tasks/reports files ────────────────
# Note: macOS ships bash 3.2 which lacks associative arrays. Use parallel
# indexed arrays with a helper function instead.
ROLE_OLD=(
    "karo"
    "ashigaru1"
    "ashigaru2"
    "ashigaru3"
    "ashigaru4"
    "ashigaru5"
    "ashigaru6"
    "ashigaru7"
    "gunshi"
)
ROLE_NEW=(
    "orchestrator"
    "explorer"
    "librarian"
    "oracle"
    "designer"
    "fixer"
    "observer"
    "council"
    "oracle"
)

# Look up the new role name for a given old role.
# Echoes empty string if not found (caller should treat as skip).
role_map_lookup() {
    local key="$1" i
    for i in "${!ROLE_OLD[@]}"; do
        if [ "${ROLE_OLD[$i]}" = "$key" ]; then
            echo "${ROLE_NEW[$i]}"
            return 0
        fi
    done
    return 1
}

migrate_dir() {
    local subdir="$1" extension="$2"
    local moved=0 skipped=0
    local i old new src dst
    for i in "${!ROLE_OLD[@]}"; do
        old="${ROLE_OLD[$i]}"
        new="${ROLE_NEW[$i]}"
        src="$SCRIPT_DIR/queue/$subdir/${old}${extension}"
        dst="$SCRIPT_DIR/queue/$subdir/${new}${extension}"
        if [ ! -f "$src" ]; then
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
            echo "[migrate] (dry-run) would rename $subdir/${old}${extension} → ${new}${extension}"
            moved=$((moved + 1))
            continue
        fi
        # If destination exists (e.g., oracle already present when gunshi→oracle
        # runs), append messages from source into destination rather than clobber.
        if [ -f "$dst" ]; then
            "$SCRIPT_DIR/.venv/bin/python3" - "$src" "$dst" <<'PY' || true
import sys, yaml
src_path, dst_path = sys.argv[1], sys.argv[2]
try:
    with open(src_path) as f:
        src_data = yaml.safe_load(f) or {}
    with open(dst_path) as f:
        dst_data = yaml.safe_load(f) or {}
except Exception as e:
    print(f"[migrate] merge warning: {e}", file=sys.stderr)
    sys.exit(0)
src_msgs = (src_data.get("messages") or []) if isinstance(src_data, dict) else []
dst_msgs = (dst_data.get("messages") or []) if isinstance(dst_data, dict) else []
# Append src messages to dst, preserving order; dst first (newer on top per inbox_write)
merged = dst_msgs + src_msgs
if isinstance(dst_data, dict):
    dst_data["messages"] = merged
else:
    dst_data = {"messages": merged}
with open(dst_path, "w") as f:
    yaml.dump(dst_data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
PY
            rm "$src"
            echo "[migrate] merged $subdir/${old}${extension} → ${new}${extension}"
        else
            mv "$src" "$dst"
            echo "[migrate] renamed $subdir/${old}${extension} → ${new}${extension}"
        fi
        moved=$((moved + 1))
    done
    echo "[migrate]   $subdir: $moved renamed/merged, $skipped absent"
}

migrate_dir "inbox"   ".yaml"
migrate_dir "tasks"   ".yaml"
migrate_dir "reports" "_report.yaml"

# ─── Step 7: summary ────────────────────────────────────────────
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[migrate] (dry-run) complete — no files changed"
else
    echo "[migrate] migration complete; backup at $BACKUP"
    echo "[migrate] next steps:"
    echo "           1. bash scripts/shutsujin_departure_v2.sh   # spawn v2 topology"
    echo "           2. smoke-test dispatcher end-to-end"
    echo "           3. teardown v1 tmux sessions"
fi

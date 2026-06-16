#!/usr/bin/env bash
# TDD test for inbox_write.sh role validation (Task D.3).
#
# Verifies that inbox_write.sh rejects messages addressed to a role
# that is not declared in config/settings.yaml.roles, and accepts
# messages to declared roles.
#
# Test mechanism:
#   - We can't mutate config/settings.yaml (it's gitignored, may not
#     exist). Instead, the validation block looks for config/settings.yaml
#     at SCRIPT_DIR/../../config/settings.yaml — relative to the test
#     fixture's SCRIPT_DIR.
#   - So we create a temporary settings.yaml under a tmp dir, and use
#     a wrapper inbox_write.sh that resolves SCRIPT_DIR to that tmp dir.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INBOX_WRITE="${REPO_ROOT}/scripts/inbox_write.sh"

# Prereq
[ -f "$INBOX_WRITE" ] || { echo "FAIL: $INBOX_WRITE not found" >&2; exit 1; }

# Verify venv Python + PyYAML (same prereq as inbox_write itself)
[ -x "${REPO_ROOT}/.venv/bin/python3" ] || { echo "FAIL: ${REPO_ROOT}/.venv/bin/python3 not executable" >&2; exit 1; }
"${REPO_ROOT}/.venv/bin/python3" -c "import yaml" 2>/dev/null \
    || { echo "FAIL: PyYAML not installed in venv" >&2; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Build a fake project tree:
#   $TMPDIR/
#     scripts/inbox_write.sh   (wrapped copy with SCRIPT_DIR pointing to TMPDIR)
#     .venv -> REPO_ROOT/.venv (symlink so venv python is found)
#     queue/inbox/             (target directory for writes)
mkdir -p "$TMPDIR/scripts" "$TMPDIR/queue/inbox"

# Create config/settings.yaml with a small role list
mkdir -p "$TMPDIR/config"
cat > "$TMPDIR/config/settings.yaml" <<'YAML'
topology: v2
cli:
  default: claude
roles:
  orchestrator:
    model: opus
    pane_target: "multiagent:ops.0"
    prompt_path: "instructions/orchestrator.md"
  fixer:
    model: sonnet
    pane_target: "multiagent:ops.1"
    prompt_path: "instructions/fixer.md"
YAML

# Copy inbox_write.sh but rewrite SCRIPT_DIR to resolve to $TMPDIR
sed "s|SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/..*|SCRIPT_DIR=\"$TMPDIR\"|" \
    "$INBOX_WRITE" > "$TMPDIR/scripts/inbox_write.sh"
chmod +x "$TMPDIR/scripts/inbox_write.sh"

# Symlink venv
ln -sf "$REPO_ROOT/.venv" "$TMPDIR/.venv"

FAIL=0

# ─── Case 1: valid role (orchestrator) → exit 0 ───────────────
if ! bash "$TMPDIR/scripts/inbox_write.sh" orchestrator "hello orchestrator" task_assigned shogun 2>"$TMPDIR/err1.log"; then
    echo "FAIL: valid role 'orchestrator' was rejected" >&2
    cat "$TMPDIR/err1.log" >&2
    FAIL=1
else
    echo "PASS: valid role 'orchestrator' accepted"
fi

# ─── Case 2: another valid role (fixer) → exit 0 ──────────────
if ! bash "$TMPDIR/scripts/inbox_write.sh" fixer "hello fixer" task_assigned orchestrator 2>"$TMPDIR/err2.log"; then
    echo "FAIL: valid role 'fixer' was rejected" >&2
    cat "$TMPDIR/err2.log" >&2
    FAIL=1
else
    echo "PASS: valid role 'fixer' accepted"
fi

# ─── Case 3: invalid role (nonexistent) → exit 1 ──────────────
if bash "$TMPDIR/scripts/inbox_write.sh" nonexistent_role "hello" task_assigned shogun 2>"$TMPDIR/err3.log"; then
    echo "FAIL: invalid role 'nonexistent_role' was accepted" >&2
    FAIL=1
else
    if ! grep -qi "unknown role" "$TMPDIR/err3.log"; then
        echo "FAIL: expected 'unknown role' in error output, got:" >&2
        cat "$TMPDIR/err3.log" >&2
        FAIL=1
    else
        echo "PASS: invalid role 'nonexistent_role' rejected with error message"
    fi
fi

# ─── Case 4: legacy v1 role (orchestrator) with v2 settings → rejected
# (hard cutover — no legacy aliases per spec)
if bash "$TMPDIR/scripts/inbox_write.sh" orchestrator "legacy" task_assigned shogun 2>"$TMPDIR/err4.log"; then
    echo "FAIL: legacy v1 role 'orchestrator' was accepted in v2 settings" >&2
    FAIL=1
else
    echo "PASS: legacy v1 role 'orchestrator' rejected in v2 (hard cutover)"
fi

# ─── Case 5: role not declared in v1 settings is accepted
# (legacy behavior preserved when topology=v1)
cat > "$TMPDIR/config/settings.yaml" <<'YAML'
topology: v1
cli:
  default: claude
YAML

if ! bash "$TMPDIR/scripts/inbox_write.sh" orchestrator "legacy v1" task_assigned shogun 2>"$TMPDIR/err5.log"; then
    echo "FAIL: any role rejected under topology=v1 (legacy behavior)" >&2
    cat "$TMPDIR/err5.log" >&2
    FAIL=1
else
    echo "PASS: any role accepted under topology=v1 (legacy preserved)"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
fi
exit $FAIL

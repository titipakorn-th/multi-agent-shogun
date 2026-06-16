#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# validate_settings.sh — Validates config/settings.yaml against the v2 schema.
#
# Usage: bash scripts/validate_settings.sh [path/to/settings.yaml]
#        (default path: config/settings.yaml)
#
# Exit codes:
#   0  — settings file is valid
#   1  — settings file is invalid (with reasons on stderr)
#
# Implementation uses Python+PyYAML rather than yq because PyYAML is already
# a project dependency (inbox_write.sh relies on it via .venv).
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SETTINGS="${1:-config/settings.yaml}"

# ─── File existence check ──────────────────────────────────────
if [ ! -f "$SETTINGS" ]; then
    echo "FAIL: settings file not found: $SETTINGS" >&2
    exit 1
fi

# ─── Python availability ────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${SCRIPT_DIR}/.venv/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="$(command -v python3)"
fi
if [ -z "$PYTHON_BIN" ] || ! "$PYTHON_BIN" -c "import yaml" 2>/dev/null; then
    echo "FAIL: Python with PyYAML not available (need $SCRIPT_DIR/.venv/bin/python3 or system python3 with pyyaml)" >&2
    exit 1
fi

# ─── Run the validator in Python ────────────────────────────────
SETTINGS_PATH="$SETTINGS" "$PYTHON_BIN" - <<'PY'
import os
import sys
import yaml

settings_path = os.environ["SETTINGS_PATH"]

SUPPORTED_CLIS = {"claude", "codex", "copilot", "kimi", "opencode", "antigravity"}
READ_ONLY_ROLES = {"explorer", "librarian", "oracle", "observer", "council"}

errors = []

def fail(msg: str) -> None:
    errors.append(msg)

# ─── Load settings ──────────────────────────────────────────────
try:
    with open(settings_path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f)
except yaml.YAMLError as e:
    print(f"FAIL: settings file is not valid YAML: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("FAIL: settings file must be a YAML mapping at top level", file=sys.stderr)
    sys.exit(1)

# ─── Topology field ─────────────────────────────────────────────
topology = data.get("topology", "v1")
if topology not in ("v1", "v2"):
    fail(f"topology must be one of [v1, v2], got '{topology}'")

# Legacy v1: no per-role validation enforced
if topology == "v1":
    # Still warn if no roles block at all (informational only)
    pass

# ─── Roles block ────────────────────────────────────────────────
roles = data.get("roles") or {}
if not isinstance(roles, dict):
    fail("'roles' must be a mapping")
    _emit_and_exit(errors)
    sys.exit(0)  # unreachable; _emit_and_exit exits

if topology == "v2" and len(roles) < 9:
    fail(f"topology=v2 requires at least 9 roles (found {len(roles)})")

# ─── Per-role required fields and values ────────────────────────
pane_targets_seen = {}
cli_default = None
cli_block = data.get("cli") or {}
if isinstance(cli_block, dict):
    cli_default = cli_block.get("default")

for role, cfg in roles.items():
    if not isinstance(cfg, dict):
        fail(f"role '{role}': configuration must be a mapping")
        continue

    # Required fields
    for field in ("model", "pane_target", "prompt_path"):
        if not cfg.get(field):
            fail(f"role '{role}' missing required field '{field}'")

    # cli_variant (optional, defaults to cli.default)
    cli_variant = cfg.get("cli_variant", cli_default)
    if cli_variant and cli_variant not in SUPPORTED_CLIS:
        fail(f"role '{role}': cli_variant '{cli_variant}' not in supported list {sorted(SUPPORTED_CLIS)}")

    # pane_target uniqueness
    pt = cfg.get("pane_target")
    if pt:
        if pt in pane_targets_seen:
            fail(f"role '{role}': pane_target '{pt}' is duplicated (also used by role '{pane_targets_seen[pt]}')")
        else:
            pane_targets_seen[pt] = role

    # model — allow common values but warn on unknown (still pass)
    # (no enforcement — model support is CLI-specific)

# ─── Emit results ───────────────────────────────────────────────
if errors:
    print(f"FAIL: {settings_path} has {len(errors)} error(s):", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)

print(f"PASS: {settings_path} validates ({len(roles)} role(s), topology={topology})")
sys.exit(0)
PY

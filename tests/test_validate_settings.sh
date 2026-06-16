#!/usr/bin/env bash
# TDD test for scripts/validate_settings.sh
# Covers Task D.1: required-field validation, topology=v2 role count,
# duplicate pane_target detection, and unsupported CLI rejection.
#
# This test creates fixture YAML files in a temp dir and runs the validator
# against them. It does not depend on the project's config/settings.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="${SCRIPT_DIR}/scripts/validate_settings.sh"

# Prereq: validator must exist
if [ ! -f "$VALIDATOR" ]; then
    echo "FAIL: $VALIDATOR not found" >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0

# ─── Case 1: valid full v2 settings (9 roles) ──────────────────
cat > "$TMPDIR/valid.yaml" <<'YAML'
topology: v2
cli:
  default: claude
roles:
  shogun:
    model: opus
    pane_target: "shogun:main.0"
    prompt_path: "instructions/shogun.md"
  orchestrator:
    model: opus
    pane_target: "multiagent:ops.0"
    prompt_path: "instructions/orchestrator.md"
  explorer:
    model: haiku
    pane_target: "multiagent:research.0"
    prompt_path: "instructions/explorer.md"
  librarian:
    model: sonnet
    pane_target: "multiagent:research.1"
    prompt_path: "instructions/librarian.md"
  oracle:
    model: opus
    pane_target: "multiagent:research.2"
    prompt_path: "instructions/oracle.md"
  designer:
    model: sonnet
    pane_target: "multiagent:ops.2"
    prompt_path: "instructions/designer.md"
  fixer:
    model: sonnet
    pane_target: "multiagent:ops.1"
    prompt_path: "instructions/fixer.md"
  observer:
    model: sonnet
    pane_target: "multiagent:ops.3"
    prompt_path: "instructions/observer.md"
  council:
    model: opus
    pane_target: "multiagent:research.3"
    prompt_path: "instructions/council.md"
YAML

if ! bash "$VALIDATOR" "$TMPDIR/valid.yaml" >/dev/null 2>&1; then
    echo "FAIL: valid full v2 settings rejected" >&2
    FAIL=1
else
    echo "PASS: valid full v2 settings accepted"
fi

# ─── Case 2: invalid — missing required field `model` ───────────
cat > "$TMPDIR/no_model.yaml" <<'YAML'
topology: v2
roles:
  shogun:
    pane_target: "shogun:main.0"
    prompt_path: "instructions/shogun.md"
YAML

if bash "$VALIDATOR" "$TMPDIR/no_model.yaml" >/dev/null 2>&1; then
    echo "FAIL: settings missing 'model' was accepted" >&2
    FAIL=1
else
    echo "PASS: settings missing 'model' rejected"
fi

# ─── Case 3: invalid — duplicate pane_target values ─────────────
cat > "$TMPDIR/dup_pane.yaml" <<'YAML'
topology: v2
roles:
  shogun:
    model: opus
    pane_target: "multiagent:ops.0"
    prompt_path: "instructions/shogun.md"
  orchestrator:
    model: opus
    pane_target: "multiagent:ops.0"
    prompt_path: "instructions/orchestrator.md"
YAML

if bash "$VALIDATOR" "$TMPDIR/dup_pane.yaml" >/dev/null 2>&1; then
    echo "FAIL: duplicate pane_target was accepted" >&2
    FAIL=1
else
    echo "PASS: duplicate pane_target rejected"
fi

# ─── Case 4: invalid — unsupported CLI variant ──────────────────
cat > "$TMPDIR/bad_cli.yaml" <<'YAML'
topology: v2
roles:
  shogun:
    model: opus
    cli_variant: bogus-cli
    pane_target: "shogun:main.0"
    prompt_path: "instructions/shogun.md"
YAML

if bash "$VALIDATOR" "$TMPDIR/bad_cli.yaml" >/dev/null 2>&1; then
    echo "FAIL: unsupported cli_variant was accepted" >&2
    FAIL=1
else
    echo "PASS: unsupported cli_variant rejected"
fi

# ─── Case 5: invalid — topology=v2 with fewer than 9 roles ──────
cat > "$TMPDIR/few_roles.yaml" <<'YAML'
topology: v2
roles:
  shogun:
    model: opus
    pane_target: "shogun:main.0"
    prompt_path: "instructions/shogun.md"
YAML

if bash "$VALIDATOR" "$TMPDIR/few_roles.yaml" >/dev/null 2>&1; then
    echo "FAIL: topology=v2 with 1 role was accepted" >&2
    FAIL=1
else
    echo "PASS: topology=v2 with 1 role rejected (need 9)"
fi

# ─── Case 6: valid — topology=v1 with no roles block ────────────
cat > "$TMPDIR/v1.yaml" <<'YAML'
topology: v1
cli:
  default: claude
YAML

if ! bash "$VALIDATOR" "$TMPDIR/v1.yaml" >/dev/null 2>&1; then
    echo "FAIL: topology=v1 was rejected" >&2
    FAIL=1
else
    echo "PASS: topology=v1 (legacy) accepted"
fi

# ─── Case 7: invalid — file not found ───────────────────────────
if bash "$VALIDATOR" /tmp/does_not_exist_$$_$(date +%s).yaml >/dev/null 2>&1; then
    echo "FAIL: missing file was accepted" >&2
    FAIL=1
else
    echo "PASS: missing file rejected"
fi

if [ "$FAIL" -eq 0 ]; then
    echo "ALL TESTS PASSED"
fi
exit $FAIL

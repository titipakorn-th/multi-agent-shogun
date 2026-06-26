#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_build_specialist_variants.bats — Task 13 gap-closure
# ═══════════════════════════════════════════════════════════════
# Verifies scripts/lib/build_specialist_variants.py:
#   - Emits {role}.md and {cli}-{role}.md for every (role, cli) in settings
#   - Adds a new role to settings → emits it under all CLIs (no manual list)
#   - Falls back gracefully if Python generation fails (still emits files)
#   - One source of truth: settings.yaml drives the output
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILDER="$PROJECT_ROOT/scripts/lib/build_specialist_variants.py"
    TEST_TMP="$(mktemp -d)"
    # Minimal sandbox project structure.
    SANDBOX="$TEST_TMP/sandbox"
    mkdir -p "$SANDBOX/instructions" "$SANDBOX/config"
    cp "$PROJECT_ROOT/scripts/build_instructions.sh" "$SANDBOX/" 2>/dev/null || true
}

teardown() {
    rm -rf "$TEST_TMP"
}

# Helper: write a minimal settings.yaml with the given roles + clis.
write_settings() {
    local roles_yaml="$1"
    cat > "$TEST_TMP/settings.yaml" <<YAML
language: en
topology: v2
cli:
  default: claude
roles:
${roles_yaml}
YAML
}

# Helper: write a minimal role instruction file.
write_role_file() {
    local role="$1"
    echo "# Role: $role" > "$SANDBOX/instructions/${role}.md"
}

@test "T-BUILDER-001: emits canonical and per-CLI variants for each role" {
    write_role_file explorer
    write_role_file librarian
    write_settings "  explorer: { cli_variant: claude, model: sonnet, pane_target: p1, prompt_path: instructions/explorer.md }
  librarian: { cli_variant: codex, model: sonnet, pane_target: p2, prompt_path: instructions/librarian.md }"

    ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "$TEST_TMP/settings.yaml"

    # Both canonical files exist.
    [ -f "$SANDBOX/out/explorer.md" ]
    [ -f "$SANDBOX/out/librarian.md" ]
    # Per-CLI variants exist.
    [ -f "$SANDBOX/out/claude-explorer.md" ]
    [ -f "$SANDBOX/out/codex-explorer.md" ]
    [ -f "$SANDBOX/out/claude-librarian.md" ]
    [ -f "$SANDBOX/out/codex-librarian.md" ]
}

@test "T-BUILDER-002: new role added to settings → emitted under all CLIs (no manual list update)" {
    write_role_file explorer
    write_role_file new_specialist
    write_settings "  explorer: { cli_variant: claude, model: sonnet, pane_target: p1, prompt_path: instructions/explorer.md }
  new_specialist: { cli_variant: codex, model: sonnet, pane_target: p2, prompt_path: instructions/new_specialist.md }"

    ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "$TEST_TMP/settings.yaml"

    # new_specialist emitted under BOTH clis without any hard-coded update.
    [ -f "$SANDBOX/out/new_specialist.md" ]
    [ -f "$SANDBOX/out/claude-new_specialist.md" ]
    [ -f "$SANDBOX/out/codex-new_specialist.md" ]
}

@test "T-BUILDER-003: missing role file is skipped silently with warning" {
    # explorer.md missing.
    write_role_file librarian
    write_settings "  explorer: { cli_variant: claude, model: sonnet, pane_target: p1, prompt_path: instructions/explorer.md }
  librarian: { cli_variant: claude, model: sonnet, pane_target: p2, prompt_path: instructions/librarian.md }"

    run env ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" \
        "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "$TEST_TMP/settings.yaml"
    # Should still succeed (exit 0), only emit librarian variants.
    [ "$status" -eq 0 ]
    [ ! -f "$SANDBOX/out/explorer.md" ]
    [ -f "$SANDBOX/out/librarian.md" ]
    echo "$output" | grep -q "explorer.md not found"
}

@test "T-BUILDER-004: missing settings.yaml → error exit 1" {
    run env ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" \
        "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "/nonexistent/settings.yaml"
    [ "$status" -eq 1 ]
}

@test "T-BUILDER-005: no roles → exit 2" {
    cat > "$TEST_TMP/settings.yaml" <<'YAML'
language: en
topology: v2
cli:
  default: claude
YAML
    run env ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" \
        "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "$TEST_TMP/settings.yaml"
    [ "$status" -eq 2 ]
}

@test "T-BUILDER-006: emits file with body matching the source instruction" {
    write_role_file explorer
    echo "# Custom content" >> "$SANDBOX/instructions/explorer.md"
    write_settings "  explorer: { cli_variant: claude, model: sonnet, pane_target: p1, prompt_path: instructions/explorer.md }"

    ROOT_DIR="$SANDBOX" OUTPUT_DIR="$SANDBOX/out" "$PROJECT_ROOT/.venv/bin/python3" "$BUILDER" "$TEST_TMP/settings.yaml"
    grep -q "Custom content" "$SANDBOX/out/claude-explorer.md"
}
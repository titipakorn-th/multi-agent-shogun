#!/usr/bin/env bats
# tests/unit/test_skill_discovery.bats
#
# Regression test for per-agent skill folder layout (2026-06-16).
# Verifies:
#   1. The 8 migrated shogun skills live under skills/shogun/<skill>/.
#   2. SKILL.md name: fields lack the shogun- prefix.
#   3. 8 role folders exist: common + orchestrator + 7 specialists.
#   4. Each specialist instruction file has an "## Available Skills" section.
#   5. skill-creator remains at top level (universal).
#   6. Zero stale shogun-<skill> references in user-facing docs.
#   7. No legacy skills/shogun-* directories remain.

setup() {
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "skills/shogun/ contains all 14 migrated skills" {
  [ -d "$PROJECT_ROOT/skills/shogun" ]
  for skill in agent-status bloom-config changelog clonedeps diagnose \
              feature-spec grill-with-docs improve-codebase-architecture \
              model-list model-switch screenshot \
              subagent-driven-development worktrees zoom-out; do
    [ -f "$PROJECT_ROOT/skills/shogun/$skill/SKILL.md" ] || \
      { echo "MISSING: skills/shogun/$skill/SKILL.md"; return 1; }
  done
}

@test "no legacy skills/shogun-* directories remain in tracked tree" {
  # Use git ls-files so untracked working-tree files (e.g., skill drafts
  # not yet committed) don't trip the test. Tests should verify the
  # committed layout, not the developer's local in-progress files.
  run bash -c "cd $PROJECT_ROOT && git ls-files 'skills/shogun-*' | grep -q ."
  [ "$status" -ne 0 ]
}

@test "all 8 role skill folders exist" {
  for role in common orchestrator explorer librarian oracle \
              designer fixer observer council; do
    [ -d "$PROJECT_ROOT/skills/$role" ] || \
      { echo "MISSING: skills/$role"; return 1; }
  done
}

@test "every specialist instruction file has Available Skills section" {
  for role in orchestrator explorer librarian oracle \
              designer fixer observer council; do
    grep -q "^## Available Skills" "$PROJECT_ROOT/instructions/$role.md" || \
      { echo "MISSING section in instructions/$role.md"; return 1; }
  done
}

@test "no SKILL.md in skills/shogun/ has shogun- prefix in name field" {
  for f in "$PROJECT_ROOT"/skills/shogun/*/SKILL.md; do
    ! grep -q "^name: shogun-" "$f" || \
      { echo "STALE PREFIX in $f"; return 1; }
  done
}

@test "skill-creator remains at top level (universal skill)" {
  [ -f "$PROJECT_ROOT/skills/skill-creator/SKILL.md" ]
}

@test "no stale shogun-<skill> references in user-facing docs" {
  run bash -c "grep -rE '\bshogun-(grill-with-docs|diagnose|zoom-out|improve-codebase-architecture|changelog|subagent-driven-development|feature-spec|agent-status|bloom-config|model-list|model-switch|readme-sync|screenshot|clonedeps|worktrees)\b' \
    $PROJECT_ROOT/CLAUDE.md $PROJECT_ROOT/README.md $PROJECT_ROOT/AGENTS.md \
    $PROJECT_ROOT/instructions/ $PROJECT_ROOT/skills/skill-creator/SKILL.md \
    $PROJECT_ROOT/config/settings.yaml.sample 2>/dev/null"
  [ -z "$output" ] || { echo "STALE REFS: $output"; return 1; }
}

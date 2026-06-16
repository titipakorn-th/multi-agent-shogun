#!/usr/bin/env bats
# test_build_system.bats — Build System (build_instructions.sh) Unit Test
# Phase 2+3 Quality Test Infrastructure
#
# Test configuration:
#   - Build execution test: script finishes normally, directory created
#   - File generation test: verify generation of claude/codex/copilot/opencode roles
#   - Content validation test: not empty, contains role name & CLI specific sections
#   - AGENTS.md / copilot-instructions.md generation tests
#   - Idempotency test: no difference on 2 builds
#
# About Phase 2+3 unimplemented tests:
#   Tests for copilot/opencode generation, AGENTS.md, copilot-instructions.md
#   will FAIL until build_instructions.sh is extended (acceptance criteria).
#   Do not use SKIP (comply with SKIP=0 rule).

# --- Setup ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    export OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"

    # Verify parts directory existence (prerequisite)
    [ -d "$PROJECT_ROOT/instructions/roles" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/common" ] || return 1
    [ -d "$PROJECT_ROOT/instructions/cli_specific" ] || return 1

    # Execute build (only once before all tests)
    bash "$BUILD_SCRIPT" > /dev/null 2>&1 || true
}

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    BUILD_SCRIPT="$PROJECT_ROOT/scripts/build_instructions.sh"
    OUTPUT_DIR="$PROJECT_ROOT/instructions/generated"
}

# =============================================================================
# Build execution test
# =============================================================================

@test "build: build_instructions.sh exits with status 0" {
    run bash "$BUILD_SCRIPT"
    [ "$status" -eq 0 ]
}

@test "build: generated/ directory exists after build" {
    [ -d "$OUTPUT_DIR" ]
}

@test "build: generated/ contains at least 6 files" {
    local count
    count=$(find "$OUTPUT_DIR" -name "*.md" -type f | wc -l)
    [ "$count" -ge 6 ]
}

# =============================================================================
# File generation test — Claude
# =============================================================================

@test "claude: shogun.md generated" {
    [ -f "$OUTPUT_DIR/shogun.md" ]
}

@test "claude: orchestrator.md generated" {
    [ -f "$OUTPUT_DIR/orchestrator.md" ]
}

@test "claude: specialist.md generated" {
    [ -f "$OUTPUT_DIR/specialist.md" ]
}

# =============================================================================
# File generation test — Codex / OpenCode
# =============================================================================

@test "codex: codex-shogun.md generated" {
    [ -f "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "codex: codex-orchestrator.md generated" {
    [ -f "$OUTPUT_DIR/codex-orchestrator.md" ]
}

@test "codex: codex-specialist.md generated" {
    [ -f "$OUTPUT_DIR/codex-specialist.md" ]
}

@test "opencode: opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode: opencode-orchestrator.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-orchestrator.md" ]
}

@test "opencode: opencode-specialist.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-specialist.md" ]
}

@test "opencode: opencode-oracle.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-oracle.md" ]
}

@test "antigravity: antigravity-shogun.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-shogun.md" ]
}

@test "antigravity: antigravity-orchestrator.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-orchestrator.md" ]
}

@test "antigravity: antigravity-specialist.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-specialist.md" ]
}

@test "antigravity: antigravity-oracle.md generated" {
    [ -f "$OUTPUT_DIR/antigravity-oracle.md" ]
}

@test "opencode: generated markdown is LF-only and has no trailing whitespace [R6]" {
    local file

    for file in "$OUTPUT_DIR"/opencode-*.md "$PROJECT_ROOT"/.opencode/agents/*.md; do
        [ -f "$file" ] || continue

        if LC_ALL=C grep -n $'\r' "$file"; then
            echo "CR line ending found in $file" >&2
            return 1
        fi

        if grep -nE '[[:blank:]]+$' "$file"; then
            echo "Trailing whitespace found in $file" >&2
            return 1
        fi
    done
}

# =============================================================================
# File generation test — Copilot (Phase 2+3 Acceptance Criteria)
# =============================================================================

@test "copilot: copilot-shogun.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-shogun.md" ]
}

@test "copilot: copilot-orchestrator.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-orchestrator.md" ]
}

@test "copilot: copilot-specialist.md generated [Phase 2+3]" {
    [ -f "$OUTPUT_DIR/copilot-specialist.md" ]
}

# =============================================================================
# Content validation test — not empty
# =============================================================================

@test "content: shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/shogun.md" ]
}

@test "content: orchestrator.md is not empty" {
    [ -s "$OUTPUT_DIR/orchestrator.md" ]
}

@test "content: specialist.md is not empty" {
    [ -s "$OUTPUT_DIR/specialist.md" ]
}

@test "content: codex-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-shogun.md" ]
}

@test "content: codex-orchestrator.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-orchestrator.md" ]
}

@test "content: codex-specialist.md is not empty" {
    [ -s "$OUTPUT_DIR/codex-specialist.md" ]
}

@test "content: opencode-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "content: opencode-orchestrator.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-orchestrator.md" ]
}

@test "content: opencode-specialist.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-specialist.md" ]
}

@test "content: opencode-oracle.md is not empty" {
    [ -s "$OUTPUT_DIR/opencode-oracle.md" ]
}

@test "content: antigravity-shogun.md is not empty" {
    [ -s "$OUTPUT_DIR/antigravity-shogun.md" ]
}

# =============================================================================
# Content validation test — contains role name
# =============================================================================

@test "content: shogun.md contains shogun role reference" {
    grep -qi "shogun\\|Shogun" "$OUTPUT_DIR/shogun.md"
}

@test "content: orchestrator.md contains orchestrator role reference" {
    grep -qi "orchestrator\\|Karo" "$OUTPUT_DIR/orchestrator.md"
}

@test "content: specialist.md contains specialist role reference" {
    grep -qi "specialist\\|Ashigaru" "$OUTPUT_DIR/specialist.md"
}

@test "content: codex-shogun.md contains shogun role reference" {
    grep -qi "shogun\\|Shogun" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: codex-orchestrator.md contains orchestrator role reference" {
    grep -qi "orchestrator\\|Karo" "$OUTPUT_DIR/codex-orchestrator.md"
}

@test "content: codex-specialist.md contains specialist role reference" {
    grep -qi "specialist\\|Ashigaru" "$OUTPUT_DIR/codex-specialist.md"
}

@test "content: opencode-shogun.md contains shogun role reference" {
    grep -qi "shogun\\|Shogun" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: opencode-orchestrator.md contains orchestrator role reference" {
    grep -qi "orchestrator\\|Karo" "$OUTPUT_DIR/opencode-orchestrator.md"
}

@test "content: opencode-specialist.md contains specialist role reference" {
    grep -qi "specialist\\|Ashigaru" "$OUTPUT_DIR/opencode-specialist.md"
}

@test "content: opencode-oracle.md contains oracle role reference" {
    grep -qi "oracle\\|Gunshi" "$OUTPUT_DIR/opencode-oracle.md"
}

@test "content: antigravity-shogun.md contains shogun role reference" {
    grep -qi "shogun\\|Shogun" "$OUTPUT_DIR/antigravity-shogun.md"
}

# =============================================================================
# Content validation test — CLI specific section
# =============================================================================

@test "content: claude files contain Claude-specific tools" {
    # Claude Code specific tools: Read, Write, Edit, Bash etc.
    grep -qi "claude\|Read\|Write\|Edit\|Bash" "$OUTPUT_DIR/shogun.md"
}

@test "content: codex files contain Codex-specific content" {
    grep -qi "codex\|AGENTS.md\|Codex" "$OUTPUT_DIR/codex-shogun.md"
}

@test "content: opencode files contain OpenCode-specific content [R6]" {
    grep -qi "opencode\|OpenCode\|--agent" "$OUTPUT_DIR/opencode-shogun.md"
}

@test "content: antigravity files contain Antigravity-specific content" {
    grep -qi "antigravity\|Antigravity\|agy" "$OUTPUT_DIR/antigravity-shogun.md"
}

@test "content: copilot files contain Copilot-specific content [Phase 2+3]" {
    grep -qi "copilot\|Copilot" "$OUTPUT_DIR/copilot-shogun.md"
}

# =============================================================================
# AGENTS.md generation test (Phase 2+3 Acceptance Criteria)
# =============================================================================

@test "agents: AGENTS.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ]
}

@test "agents: AGENTS.md contains Codex-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/AGENTS.md" ] && grep -qi "codex\|agent" "$PROJECT_ROOT/AGENTS.md"
}

# =============================================================================
# OpenCode instruction generation (R6)
# =============================================================================

@test "opencode-inst: instructions/generated/opencode-shogun.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-shogun.md" ]
}

@test "opencode-inst: instructions/generated/opencode-orchestrator.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-orchestrator.md" ]
}

@test "opencode-inst: instructions/generated/opencode-specialist.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-specialist.md" ]
}

@test "opencode-inst: instructions/generated/opencode-oracle.md generated [R6]" {
    [ -f "$OUTPUT_DIR/opencode-oracle.md" ]
}

@test "opencode-agent: .opencode/agents/shogun.md generated [R6]" {
    [ -f "$PROJECT_ROOT/.opencode/agents/shogun.md" ]
}

@test "opencode-agent: generated agent frontmatter contains permission section [R6]" {
    grep -q '^permission:' "$PROJECT_ROOT/.opencode/agents/shogun.md"
}

@test "opencode-agent: tracked agent frontmatter excludes runtime routing [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
agents_dir = project_root / ".opencode" / "agents"
for path in sorted(agents_dir.glob("*.md")):
    if path.name.endswith("-runtime.md"):
        continue
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    assert "model" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
    assert "variant" not in frontmatter, f"{path.name}: tracked generated agent must not depend on local settings.yaml"
PYEOF
}

@test "opencode-agent: explorer read permissions allow own inbox/report/task [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

project_root = Path(os.environ["PROJECT_ROOT"])
text = (project_root / ".opencode/agents/explorer.md").read_text(encoding="utf-8")
parts = text.split("---", 2)
frontmatter = yaml.safe_load(parts[1])
perm = frontmatter["permission"]

assert perm["question"] == "deny"
assert perm["read"]["queue/inbox/*"] == "deny"
assert perm["read"]["queue/inbox/explorer.yaml"] == "allow"
assert perm["read"]["queue/tasks/*"] == "deny"
assert perm["read"]["queue/tasks/explorer.yaml"] == "allow"
assert perm["read"]["queue/reports/*"] == "deny"
assert perm["read"]["queue/reports/ashigaru1_report.yaml"] == "allow"

for tool_name in ("glob", "list"):
    assert perm[tool_name]["queue/inbox/*"] == "deny"
    assert perm[tool_name]["queue/inbox/explorer.yaml"] == "allow"
    assert perm[tool_name]["queue/tasks/*"] == "deny"
    assert perm[tool_name]["queue/tasks/explorer.yaml"] == "allow"
    assert perm[tool_name]["queue/reports/*"] == "deny"
    assert perm[tool_name]["queue/reports/ashigaru1_report.yaml"] == "allow"
PYEOF
}

@test "opencode-agent: grep permission is intentionally not path-scoped [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    perm = frontmatter["permission"]
    assert "grep" not in perm, f"{path.name}: grep must inherit '*: allow', not path-scoped rules"
    assert "grep intentionally inherits '*: allow'" in text, f"{path.name}: missing intentional grep comment"
PYEOF
}

@test "opencode-agent: shogun can read reports for oversight [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

path = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents/shogun.md"
text = path.read_text(encoding="utf-8")
frontmatter = yaml.safe_load(text.split("---", 2)[1])
perm = frontmatter["permission"]

assert perm["read"]["queue/reports/*"] == "allow"
assert perm["glob"]["queue/reports/*"] == "allow"
assert perm["list"]["queue/reports/*"] == "allow"
assert perm["edit"]["queue/reports/*"] == "deny"
PYEOF
}

@test "opencode-agent: inbox edits are denied for every role [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

agents_dir = Path(os.environ["PROJECT_ROOT"]) / ".opencode/agents"
for path in sorted(agents_dir.glob("*.md")):
    text = path.read_text(encoding="utf-8")
    frontmatter = yaml.safe_load(text.split("---", 2)[1])
    edit = frontmatter["permission"]["edit"]
    inbox_rules = {key: value for key, value in edit.items() if key.startswith("queue/inbox/")}
    exact_rule = edit.get("queue/inbox/*.yaml")
    unexpected_rules = {key: value for key, value in inbox_rules.items() if key != "queue/inbox/*.yaml"}

    assert exact_rule == "deny", f"{path.name}: queue/inbox/*.yaml edit rule missing or not deny: {exact_rule!r}"
    assert not unexpected_rules, f"{path.name}: unexpected inbox edit rules: {unexpected_rules}"
PYEOF
}

@test "opencode-agent: invalid permission YAML fails generation [R6]" {
    local permissions_file
    permissions_file="$BATS_TEST_TMPDIR/opencode-permissions.invalid.yaml"

    printf 'roles: [invalid\n' > "$permissions_file"
    run env OPENCODE_PERMISSIONS_FILE="$permissions_file" bash "$BUILD_SCRIPT"

    [ "$status" -ne 0 ]
}

@test "opencode-config: root edit permissions deny inbox YAML [R6]" {
    PROJECT_ROOT="$PROJECT_ROOT" "$PROJECT_ROOT/.venv/bin/python3" - <<'PYEOF'
from pathlib import Path
import os
import yaml

config = yaml.safe_load((Path(os.environ["PROJECT_ROOT"]) / "config/opencode-permissions.yaml").read_text(encoding="utf-8"))
assert config["common"]["edit_deny"]
assert "queue/inbox/*.yaml" in config["common"]["edit_deny"]
PYEOF
}

@test "opencode-tool: mark-as-read enforces current agent and inbox lock [R6]" {
    local tool_file="$PROJECT_ROOT/.opencode/tools/mark-as-read.ts"

    grep -q 'process.env.OPENCODE_AGENT_ID' "$tool_file"
    grep -q 'Refusing to mark another agent' "$tool_file"
    grep -q 'withInboxLock' "$tool_file"
    grep -q '.lock.d' "$tool_file"
}

# =============================================================================
# copilot-instructions.md generation test (Phase 2+3 Acceptance Criteria)
# =============================================================================

@test "copilot-inst: .github/copilot-instructions.md generated [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ]
}

@test "copilot-inst: contains Copilot-specific content [Phase 2+3]" {
    [ -f "$PROJECT_ROOT/.github/copilot-instructions.md" ] && \
        grep -qi "copilot" "$PROJECT_ROOT/.github/copilot-instructions.md"
}

# =============================================================================
# Idempotency test
# =============================================================================

# =============================================================================
# Codex /clear -> /new conversion test
# =============================================================================
# Because Codex CLI ends session on /clear, verify in AGENTS.md and codex-*.md
# that /clear does not remain as a command.
# Mention of /clear in comparison tables or conversion explanations is OK.

@test "codex-clear: AGENTS.md has no /clear Recovery section" {
    # /clear Recovery should be converted to /new Recovery
    run grep -c "## /clear Recovery" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has /new Recovery section" {
    grep -q "## /new Recovery" "$PROJECT_ROOT/AGENTS.md"
}

@test "codex-clear: AGENTS.md has no 'Forbidden after /clear'" {
    run grep -c "Forbidden after /clear" "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'sends \`/clear\` + Enter via send-keys' (unconverted)" {
    # Converted should be "sends /new + Enter"
    run grep -c 'sends `/clear` + Enter via send-keys$' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no 'delivers \`/clear\` to the agent' (unconverted)" {
    # Converted should be "delivers /new to the agent"
    run grep -c 'delivers `/clear` to the agent →' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: AGENTS.md has no '/clear wipes old context'" {
    run grep -c '`/clear` wipes old context' "$PROJECT_ROOT/AGENTS.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-specialist.md has no bare '/clear' in escalation table" {
    # /clear must not appear as a command except in the comparison table (from codex_tools.md)
    # NG if "/clear sent" is in the escalation line
    run grep -c '`/clear` sent (max once' "$OUTPUT_DIR/codex-specialist.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-specialist.md protocol uses CLI-neutral context reset" {
    # clear_command line in protocol.md is in CLI-neutral expression
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-specialist.md"
}

@test "codex-clear: codex-orchestrator.md has no bare '/clear' in redo protocol" {
    # In Redo Protocol, "delivers /clear to the agent ->" must not remain as is
    run grep -c 'delivers `/clear` to the agent →' "$OUTPUT_DIR/codex-orchestrator.md"
    [ "$output" = "0" ]
}

@test "codex-clear: codex-oracle.md protocol uses CLI-neutral context reset" {
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-oracle.md"
}

@test "codex-clear: codex-shogun.md protocol uses CLI-neutral context reset" {
    grep -q "context reset command via send-keys" "$OUTPUT_DIR/codex-shogun.md"
}

# =============================================================================
# Idempotency test
# =============================================================================

@test "idempotent: second build produces identical output" {
    # 1st build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_first
    checksums_first=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    # 2nd build
    bash "$BUILD_SCRIPT" > /dev/null 2>&1
    local checksums_second
    checksums_second=$(find "$OUTPUT_DIR" -name "*.md" -type f -exec md5sum {} \; | sort)

    [ "$checksums_first" = "$checksums_second" ]
}

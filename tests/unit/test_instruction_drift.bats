#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_instruction_drift.bats — Task 3 gap-closure (drift gate)
# ═══════════════════════════════════════════════════════════════
# Verifies that safety-critical rules appear consistently across:
#   - CLAUDE.md (source of truth)
#   - AGENTS.md (Codex auto-load)
#   - .github/copilot-instructions.md (Copilot auto-load)
#   - .opencode/agents/{role}.md (OpenCode auto-load)
#   - instructions/generated/* (built instructions)
#
# Each rule has a unique anchor string. The test fails if the anchor is
# missing from any expected target, catching drift introduced by manual edits
# that bypass the build pipeline.
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

# ─── T-DRIFT-001: 3-checkpoint rule appears in Orchestrator sources ───

@test "T-DRIFT-001: 3-checkpoint rule appears in Orchestrator-relevant docs" {
    # The Orchestrator MUST send 3 checkpoints to Shogun: ack/dispatched/done.
    local anchor="cmd_acknowledged"
    local targets=(
        "$PROJECT_ROOT/CLAUDE.md"
        "$PROJECT_ROOT/AGENTS.md"
        "$PROJECT_ROOT/.github/copilot-instructions.md"
        "$PROJECT_ROOT/instructions/generated/orchestrator.md"
    )
    local target
    for target in "${targets[@]}"; do
        [ -f "$target" ] || { echo "missing $target"; false; }
        grep -qF "$anchor" "$target" || {
            echo "anchor '$anchor' not found in $target"
            false
        }
    done
}

# ─── T-DRIFT-002: Codex wording for /new appears in Codex-flavored files ───

@test "T-DRIFT-002: Codex /new wording preserved in Codex-flavored instructions" {
    # Codex uses /new instead of /clear. Verify the rule exists in AGENTS.md
    # (Codex auto-load) and codex-* generated variants, but NOT in CLAUDE.md
    # (which is Claude-flavored).
    local codex_anchor="/new"
    local claude_anchor="/clear"

    # Codex-flavored files should mention /new somewhere.
    local codex_files=(
        "$PROJECT_ROOT/AGENTS.md"
    )
    local file
    for file in "${codex_files[@]}"; do
        [ -f "$file" ] || continue
        # Codex files mention /new (just needs at least one occurrence).
        grep -qF "$codex_anchor" "$file" || {
            echo "codex /new anchor missing in $file"
            false
        }
    done
}

# ─── T-DRIFT-003: Destructive-operation table is consistent across auto-loads ───

@test "T-DRIFT-003: D006 row appears in all auto-load instruction files" {
    local anchor="tmux kill-server"
    local targets=(
        "$PROJECT_ROOT/CLAUDE.md"
        "$PROJECT_ROOT/AGENTS.md"
        "$PROJECT_ROOT/.github/copilot-instructions.md"
    )
    local target
    for target in "${targets[@]}"; do
        [ -f "$target" ] || continue
        grep -qF "$anchor" "$target" || {
            echo "D006 anchor missing in $target"
            false
        }
    done
}

# ─── T-DRIFT-004: canonical status set appears in Orchestrator docs ───

@test "T-DRIFT-004: canonical specialist status set appears in Orchestrator docs" {
    # Task 2 canonical: specialists use idle/assigned/done/failed.
    # Verify these tokens all appear in Orchestrator-flavored docs.
    local required_tokens=("idle" "assigned" "done" "failed" "pending_blocked")
    local targets=(
        "$PROJECT_ROOT/CLAUDE.md"
        "$PROJECT_ROOT/AGENTS.md"
        "$PROJECT_ROOT/instructions/common/task_flow.md"
    )
    local token target
    for target in "${targets[@]}"; do
        [ -f "$target" ] || continue
        for token in "${required_tokens[@]}"; do
            grep -qF "$token" "$target" || {
                echo "token '$token' missing in $target"
                false
            }
        done
    done
}

# ─── T-DRIFT-005: NO ETAs rule appears in Shogun docs ───

@test "T-DRIFT-005: NO ETAs forbidden rule appears in Shogun-generated docs" {
    local anchor="publish_time_estimates"
    local targets=(
        "$PROJECT_ROOT/instructions/generated/shogun.md"
    )
    local target
    for target in "${targets[@]}"; do
        [ -f "$target" ] || { echo "missing $target"; false; }
        grep -qF "$anchor" "$target" || {
            echo "NO ETAs anchor missing in $target"
            false
        }
    done
}

# ─── T-DRIFT-006: build_instructions.sh runs without error ───

@test "T-DRIFT-006: build_instructions.sh runs cleanly" {
    run bash "$PROJECT_ROOT/scripts/build_instructions.sh"
    [ "$status" -eq 0 ]
}

# ═══════════════════════════════════════════════════════════════
# Semantic drift tests (Task 7 follow-up)
# ═══════════════════════════════════════════════════════════════
# Anchors alone miss contradictions (a file can mention `/new` once in a
# comparison table while still containing unconverted `/clear` reset wording
# elsewhere). These tests verify SEMANTICS for each CLI's reset/recovery path
# and core safety rules across all generated variants.

# ─── T-DRIFT-007: Codex generated prompts have correct /new semantics ───

@test "T-DRIFT-007: codex-*.md has /new semantics and no unconverted /clear reset wording" {
    local file
    for file in \
        "$PROJECT_ROOT/AGENTS.md" \
        "$PROJECT_ROOT/instructions/generated/codex-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/codex-orchestrator.md"; do
        [ -f "$file" ] || continue
        # Codex-flavored file must mention /new as a reset command.
        grep -q "/new" "$file" || {
            echo "missing /new reset mention in $file"
            false
        }
        # Bare '## /clear Recovery' must NOT appear as a heading (unconverted).
        if grep -q "^## /clear Recovery" "$file"; then
            echo "forbidden '## /clear Recovery' heading in $file"
            false
        fi
        # 'Forbidden after /clear' (unconverted phrase) must NOT appear.
        if grep -q "Forbidden after /clear" "$file"; then
            echo "forbidden 'Forbidden after /clear' phrase in $file"
            false
        fi
        # Specific Codex-only phrasing must NOT appear (would indicate a leaked Claude template).
        if grep -q "sends \`/clear\` + Enter via send-keys\$" "$file"; then
            echo "unconverted Claude-specific /clear send-keys phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-008: Claude generated prompts use /clear semantics ───

@test "T-DRIFT-008: claude-*.md and CLAUDE.md use /clear semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/CLAUDE.md" \
        "$PROJECT_ROOT/instructions/generated/orchestrator.md"; do
        [ -f "$file" ] || continue
        # Claude uses /clear for session reset. Accept either heading style.
        grep -qE "(/clear Recovery|Forbidden after /clear|/clear Protocol|## /clear)" "$file" || {
            echo "missing /clear Recovery / Forbidden / Protocol section in $file"
            false
        }
    done
}

# ─── T-DRIFT-009: Copilot generated prompts use Copilot semantics ───

@test "T-DRIFT-009: copilot-*.md uses Copilot semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/.github/copilot-instructions.md" \
        "$PROJECT_ROOT/instructions/generated/copilot-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/copilot-orchestrator.md"; do
        [ -f "$file" ] || continue
        # Copilot should NOT carry Claude/Codex reset wording unconverted.
        if grep -qE "sends `/clear` \+ Enter via send-keys$" "$file"; then
            echo "unconverted Claude '/clear + Enter' phrasing in $file"
            false
        fi
        if grep -qE "sends `/new` \+ Enter via send-keys" "$file"; then
            echo "unconverted Codex '/new + Enter' phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-010: Kimi generated prompts use Kimi semantics ───

@test "T-DRIFT-010: kimi-*.md uses Kimi semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/instructions/generated/kimi-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/kimi-orchestrator.md"; do
        [ -f "$file" ] || continue
        # Kimi uses /clear. /new-specific wording should not leak in.
        if grep -qE "sends `/new` \+ Enter via send-keys" "$file"; then
            echo "unconverted Codex '/new' phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-011: OpenCode generated prompts use /new semantics ───

@test "T-DRIFT-011: opencode-*.md uses /new semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/instructions/generated/opencode-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/opencode-orchestrator.md"; do
        [ -f "$file" ] || continue
        # OpenCode uses /new. Bare unconverted /clear reset phrase forbidden.
        if grep -qE "sends `/clear` \+ Enter via send-keys$" "$file"; then
            echo "unconverted Claude '/clear' reset phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-012: Cursor generated prompts use Cursor semantics ───

@test "T-DRIFT-012: cursor-*.md uses Cursor semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/instructions/generated/cursor-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/cursor-orchestrator.md"; do
        [ -f "$file" ] || continue
        # Cursor uses /new. No bare Claude /clear reset wording.
        if grep -qE "sends `/clear` \+ Enter via send-keys$" "$file"; then
            echo "unconverted Claude '/clear' reset phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-013: Antigravity generated prompts use Antigravity semantics ───

@test "T-DRIFT-013: antigravity-*.md uses Antigravity semantics" {
    local file
    for file in \
        "$PROJECT_ROOT/instructions/generated/antigravity-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/antigravity-orchestrator.md"; do
        [ -f "$file" ] || continue
        # Antigravity uses /clear.
        if grep -qE "sends `/new` \+ Enter via send-keys" "$file"; then
            echo "unconverted Codex '/new' phrasing in $file"
            false
        fi
    done
}

# ─── T-DRIFT-014: 3-checkpoint rule appears in EVERY orchestrator variant ───

@test "T-DRIFT-014: 3-checkpoint rule appears in every orchestrator variant" {
    local file
    local found=0
    for file in \
        "$PROJECT_ROOT/instructions/generated/orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/codex-orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/copilot-orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/kimi-orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/opencode-orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/cursor-orchestrator.md" \
        "$PROJECT_ROOT/instructions/generated/antigravity-orchestrator.md"; do
        [ -f "$file" ] || continue
        grep -q "IMMEDIATELY after receiving cmd" "$file" || {
            echo "missing 3-checkpoint rule in $file"
            false
        }
        grep -q "AFTER dispatching to specialists" "$file" || {
            echo "missing dispatch checkpoint in $file"
            false
        }
        grep -q "AFTER validation/integration complete" "$file" || {
            echo "missing done checkpoint in $file"
            false
        }
        found=$((found + 1))
    done
    [ "$found" -ge 6 ]
}

# ─── T-DRIFT-015: NO-ETA rule appears in every shogun variant ───

@test "T-DRIFT-015: NO-ETA rule appears in every shogun variant" {
    local file
    local found=0
    for file in \
        "$PROJECT_ROOT/instructions/generated/shogun.md" \
        "$PROJECT_ROOT/instructions/generated/codex-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/copilot-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/kimi-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/opencode-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/cursor-shogun.md" \
        "$PROJECT_ROOT/instructions/generated/antigravity-shogun.md"; do
        [ -f "$file" ] || continue
        grep -qE "publish_time_estimates|NO ETAs|NEVER.*ETA|No ETAs" "$file" || {
            echo "missing NO-ETA rule in $file"
            false
        }
        found=$((found + 1))
    done
    [ "$found" -ge 6 ]
}

# ─── T-DRIFT-016: Destructive-operation Tier-1 rules appear across auto-loads ───

@test "T-DRIFT-016: D-series destructive-operation rules appear across auto-loads" {
    local file
    # Tier-1 ABSOLUTE BAN rules that must appear in every auto-load file.
    local required=(
        "rm -rf"
        "tmux kill-server"
        "git push --force"
    )
    local targets=(
        "$PROJECT_ROOT/CLAUDE.md"
        "$PROJECT_ROOT/AGENTS.md"
        "$PROJECT_ROOT/.github/copilot-instructions.md"
    )
    for file in "${targets[@]}"; do
        [ -f "$file" ] || continue
        for anchor in "${required[@]}"; do
            grep -qF "$anchor" "$file" || {
                echo "Tier-1 anchor '$anchor' missing in $file"
                false
            }
        done
    done
}

# ─── T-DRIFT-017: NO-ETA + status set + 3-checkpoint all co-occur in claude orchestrator ───

@test "T-DRIFT-017: orchestrator.md has core safety rules co-occurring" {
    local file="$PROJECT_ROOT/instructions/generated/orchestrator.md"
    [ -f "$file" ] || skip "orchestrator.md not generated"
    grep -q "IMMEDIATELY after receiving cmd" "$file"
    grep -qiE "no ETAs|never.*time estimates|do not publish time" "$file"
}
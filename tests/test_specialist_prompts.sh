#!/usr/bin/env bash
# ============================================================
# Regression test for the v2 specialist prompt set (sub-C).
#
# Verifies each specialist's instructions/<role>.md:
#   1. Exists at the canonical path.
#   2. Contains the four required sections (## Role, ## Output Format,
#      ## Permissions, ## Multi-agent).
#   3. Is within the 150-300 line range.
#   4. Has a non-empty YAML frontmatter block.
#   5. References the agent_id used in tmux self-identification.
#
# SKIP = FAIL semantics: if any role is missing, the entire test fails.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INSTRUCTIONS_DIR="${ROOT_DIR}/instructions"

# 7 v2 specialist roles (sub-C scope).  orchestrator is sub-B scope; if its
# prompt is present we verify it too as a courtesy, but absence is not a fail.
SPECIALIST_ROLES=(
    explorer
    librarian
    oracle
    designer
    fixer
    observer
    council
)
OPTIONAL_ROLES=(orchestrator)

REQUIRED_SECTIONS=(
    "## Role"
    "## Output Format"
    "## Permissions"
    "## Multi-agent"
)

MIN_LINES=150
MAX_LINES=300

FAIL=0

# ------------------------------------------------------------
# helpers
# ------------------------------------------------------------
check_role() {
    local role="$1"
    local required="${2:-yes}"
    local file="${INSTRUCTIONS_DIR}/${role}.md"

    if [ ! -f "$file" ]; then
        if [ "$required" = "yes" ]; then
            echo "FAIL: ${file} does not exist" >&2
            FAIL=1
            return
        else
            echo "  (optional ${role}.md not present; skipping)"
            return
        fi
    fi

    # Required sections
    for section in "${REQUIRED_SECTIONS[@]}"; do
        if ! grep -qF "$section" "$file"; then
            echo "FAIL: ${file} missing section '${section}'" >&2
            FAIL=1
        fi
    done

    # Line count window
    local lines
    lines=$(wc -l <"$file" | tr -d ' ')
    if [ "$lines" -lt "$MIN_LINES" ]; then
        echo "FAIL: ${file} has ${lines} lines (min ${MIN_LINES})" >&2
        FAIL=1
    fi
    if [ "$lines" -gt "$MAX_LINES" ]; then
        echo "FAIL: ${file} has ${lines} lines (max ${MAX_LINES})" >&2
        FAIL=1
    fi

    # YAML frontmatter present (must begin with ---)
    local first_line
    first_line=$(head -n 1 "$file")
    if [ "$first_line" != "---" ]; then
        echo "FAIL: ${file} is missing YAML frontmatter (first line is not '---')" >&2
        FAIL=1
    fi

    # agent_id referenced (regression warning against role confusion)
    if ! grep -q "@agent_id" "$file"; then
        echo "FAIL: ${file} does not reference @agent_id (regression-warning coverage missing)" >&2
        FAIL=1
    fi

    # role: <role> frontmatter key
    if ! grep -qE "^role: ${role}\b" "$file"; then
        echo "FAIL: ${file} frontmatter does not declare 'role: ${role}'" >&2
        FAIL=1
    fi
}

# ------------------------------------------------------------
# run
# ------------------------------------------------------------
echo "Checking 7 specialist prompts in ${INSTRUCTIONS_DIR}..."

for role in "${SPECIALIST_ROLES[@]}"; do
    check_role "$role" "yes"
done

for role in "${OPTIONAL_ROLES[@]}"; do
    check_role "$role" "no"
done

if [ "$FAIL" -eq 0 ]; then
    echo "PASS: all 7 specialist prompts exist with required sections, line counts, frontmatter, and @agent_id references"
fi
exit $FAIL

#!/usr/bin/env bash
# auto_prompt_select.sh — sourced helper for Shogun's auto_prompt flow.
#
# Usage:
#   source scripts/lib/auto_prompt_select.sh
#   auto_prompt_select_next /path/to/plans
#
# Behavior:
#   Globs plans/*.md (sorted by filename, oldest first), finds the first
#   plan whose frontmatter does NOT declare `auto_continue: false` AND
#   whose `## Status` section contains at least one `- [ ]` task. Looks
#   up the matching `### Task N` body under `## Task Details` and prints
#   it as KEY=VALUE lines for the caller to consume.
#
# Output (on success):
#   RESULT=found
#   PLAN=<absolute path to plan file>
#   TASK_NUM=<integer>
#   TASK_TITLE=<text after "Task N: ">
#   TASK_BODY=<full body of the ### Task N section, multiline>
#   PROJECT=<frontmatter project: value, or empty if omitted>
#
# Output (no plans):
#   RESULT=no_plans
#
# Output (plans exist but all tasks done or auto_continue:false):
#   RESULT=no_pending
#
# Exit code: always 0 (RESULT line indicates outcome).

auto_prompt_select_next() {
    local plans_dir="${1:-./plans}"

    # ponytail: no plan dir or empty → no_plans
    if [[ ! -d "$plans_dir" ]]; then
        echo "RESULT=no_plans"
        return 0
    fi

    # Sorted glob — filenames are date-prefixed (YYYY-MM-DD-...) so
    # alphabetical sort matches chronological order.
    local plan_file
    for plan_file in $(ls -1 "$plans_dir"/*.md 2>/dev/null | sort); do
        # Skip README.md and other non-plan files.
        local basename_plan
        basename_plan=$(basename "$plan_file")
        if [[ "$basename_plan" == "README.md" ]]; then
            continue
        fi

        # Frontmatter: read lines between first `---` and second `---`.
        # If `auto_continue: false` is present, skip this plan.
        if grep -q "^auto_continue:[[:space:]]*false" "$plan_file" 2>/dev/null; then
            continue
        fi

        # Optional `project:` frontmatter — caller uses this for routing instead
        # of a hardcoded default. Empty string means "plan did not declare".
        local project
        project=$(awk '
            /^---/ { fm_count++; next }
            fm_count == 1 && /^project:[[:space:]]*/ {
                sub(/^project:[[:space:]]*/, ""); print; exit
            }
        ' "$plan_file")

        # Find first `- [ ]` line in `## Status` section. We use awk to
        # bound the search between `## Status` and the next `## ` heading.
        local pending_line
        pending_line=$(awk '
            /^## Status/ { in_status = 1; next }
            /^## /      { in_status = 0 }
            in_status && /^- \[ \]/ {
                print
                exit
            }
        ' "$plan_file")

        if [[ -z "$pending_line" ]]; then
            continue
        fi

        # Extract task number from `- [ ] Task N: title`
        local task_num
        task_num=$(echo "$pending_line" | sed -nE 's/^- \[ \] Task ([0-9]+):.*/\1/p')
        if [[ -z "$task_num" ]]; then
            # Malformed status line — skip this plan.
            continue
        fi

        # Extract task title (everything after `Task N: `).
        local task_title
        task_title=$(echo "$pending_line" | sed -nE "s/^- \[ \] Task [0-9]+:[[:space:]]*(.*)$/\1/p")

        # Look up `### Task N: ...` body under `## Task Details`.
        # Capture content between `### Task N` and the next `### ` or `## `.
        local task_body
        task_body=$(awk -v n="$task_num" '
            $0 ~ "^### Task " n "(:|[[:space:]])" { in_task = 1; next }
            /^### /                                  { if (in_task) exit; in_task = 0 }
            /^## /                                   { if (in_task) exit; in_task = 0 }
            in_task                                   { print }
        ' "$plan_file")

        # ponytail: trim trailing blank lines from body.
        task_body=$(echo "$task_body" | sed -e :a -e '/^$/N;/\n$/ba' | sed 's/[[:space:]]*$//')

        echo "RESULT=found"
        echo "PLAN=$plan_file"
        echo "TASK_NUM=$task_num"
        echo "TASK_TITLE=$task_title"
        echo "TASK_BODY=$task_body"
        echo "PROJECT=$project"
        return 0
    done

    echo "RESULT=no_pending"
    return 0
}

# Allow direct invocation: `bash scripts/lib/auto_prompt_select.sh /path/to/plans`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_prompt_select_next "$@"
fi
---
title: Adopt auto_prompt for Shogun
auto_continue: true
---

# Plan: Adopt auto_prompt for Shogun

## Status

- [x] Task 1: Add plans/README.md format spec
- [x] Task 2: Add auto_prompt section to instructions/shogun.md
- [x] Task 3: Add auto_prompt block to config/settings.yaml
- [x] Task 4: Initialize queue/auto_prompt_state.yaml
- [x] Task 5: Write tests/unit/test_auto_prompt.bats
- [ ] Task 6: Run bats suite, verify green, commit, push

## Problem

Shogun currently goes idle after every `report_completed` and waits for
the Lord to send the next command. For multi-step plans this is wasteful
— the Lord has to micromanage each task instead of trusting Shogun to
pick up the next pending item from a structured plan file. The Lord
expects Shogun to autonomously continue work with minimum interruptions,
only asking when truly necessary (no plans exist, all complete, or
explicit per-plan opt-out).

## Design

Adopt the `.plans` convention from
`/Users/prince/Workspaces/zed/.plans/01_auto_prompt.md` but adapt to the
multi-agent shogun's file-based, bash-driven flow. The Rust crate
`crates/auto_prompt/` does not port directly — its LLM-driven orchestration
loop and `AcpThreadEvent::Stopped` trigger are Zed-specific. Instead:

- **Source of next task**: structured `plans/*.md` files with `## Status`
  checkboxes. No LLM call needed for selection — deterministic parse.
- **Trigger**: insert into Shogun's Inbox Input Handling flow, after step
  3 (mark read:true) and before step 4 (go idle).
- **Safety**: `auto_prompt.max_dispatches_per_session` counter (default 5)
  caps auto-dispatch within a session to prevent infinite loops.
- **Opt-out**: per-plan `auto_continue: false` frontmatter skips plans
  requiring Lord confirmation.
- **Fallback**: when no plans have pending work, ask Lord via Telegram
  (`bash scripts/ntfy.sh "🏯 All plans complete! What's next?"`).

Five-case decision tree (adapted from Zed):

| Case | Trigger | Action |
|------|---------|--------|
| 1 | Plan found with `- [ ]` task | Dispatch first pending task |
| 2 | All plans complete | Ask Lord "what's next?" |
| 3 | `auto_continue: false` plan only | Ask Lord for confirmation |
| 4 | `dispatches_this_session >= max` | Ask Lord (cap reached) |
| 5 | `auto_prompt.enabled: false` | Stay silent |

## Task Details

### Task 1: Add plans/README.md format spec

Write `plans/README.md` documenting the frontmatter convention, `## Status`
checkbox syntax, `## Task Details` lookup pattern, and how to add a new
plan. Acceptance: README renders in markdown preview without errors;
auto_prompt section cross-links back to README.

### Task 2: Add auto_prompt section to instructions/shogun.md

Insert a new top-level section `## Auto-Prompt on Task Completion
(auto_prompt)` after the `## Progress Pings for Long Commands` section.
Also insert step 3.5 in the Inbox Input Handling → Processing Steps
between step 3 (mark read:true) and step 4 (go idle) that references the
new section. Acceptance: section renders; step 3.5 cross-references the
top-level section; no other instructions touched.

### Task 3: Add auto_prompt block to config/settings.yaml

Add at top level of `config/settings.yaml`:

```yaml
auto_prompt:
  enabled: true
  max_dispatches_per_session: 5
  prompt_when_no_plans: true
```

Acceptance: `yq` (or equivalent YAML parse) reads the block without error.

### Task 4: Initialize queue/auto_prompt_state.yaml

Create `queue/auto_prompt_state.yaml` with:

```yaml
dispatches_this_session: 0
last_reset_at: "2026-06-22T00:00:00+09:00"
session_id: "manual_init"
```

Acceptance: file exists; YAML valid.

### Task 5: Write tests/unit/test_auto_prompt.bats

Bats tests covering 6 scenarios:
1. Single plan, first task unchecked → returns that plan + task 1
2. All tasks checked → returns "no_pending"
3. Multiple plans, mixed states → returns oldest plan with first unchecked task
4. Plan with `auto_continue: false` → skipped, returns next eligible plan
5. No plans directory → returns "no_plans"
6. Frontmatter malformed → skipped gracefully (returns next plan or "no_pending")

Implementation: extract the plan-selection logic from `shogun.md` into a
sourced bash function (e.g., `scripts/lib/auto_prompt_select.sh`) so the
bats test can `source` it. Acceptance: 6/6 tests pass.

### Task 6: Run bats suite, verify green, commit, push

Run `bats tests/unit/test_auto_prompt.bats` (expect 6/6). Run full bats
suite to confirm no regressions. `git add` all new + modified files,
commit with conventional message, push to origin/main. Acceptance:
working tree clean on remote; CI (if any) green.

## Dependencies

None — first plan, no prior state.

## Estimated Effort

- Tasks 1-4: ~15 min (mechanical)
- Task 5: ~45 min (extracting logic + writing 6 tests)
- Task 6: ~5 min (verify + commit)
- Total: ~65 min
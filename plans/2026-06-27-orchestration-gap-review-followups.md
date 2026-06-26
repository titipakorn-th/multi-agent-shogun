---
title: Orchestration Gap Closure Review Follow-ups
auto_continue: true
created: "2026-06-27"
---

# Plan: Orchestration Gap Closure Review Follow-ups

## Status

- [x] Task 1: P0 Track all new executable helpers required by tests and build
- [x] Task 2: P0 Wire guard helpers into the live Orchestrator lifecycle
- [x] Task 3: P0 Complete Bloom auto-routing beyond config validation
- [x] Task 4: P0 Make build generation fail loudly when helper generation is unavailable
- [x] Task 5: P1 Fix generated trailing whitespace and add a whitespace gate
- [x] Task 6: P1 Repair weekly health review archive validation
- [x] Task 7: P1 Strengthen instruction-drift tests beyond anchor presence
- [x] Task 8: P2 Record completion evidence back into the original gap plan

### Evidence Notes

> Generated 2026-06-27 after running the verification slice.

- **Task 1**: All seven helper scripts now tracked in git (no longer
  `git check-ignore -v` matches). Re-confirmed with focused Bats slice (262
  passing).
- **Task 2**: `tests/unit/test_build_system.bats` guard-wiring tests assert
  each helper name in `instructions/orchestrator.md`; generated
  `instructions/generated/orchestrator.md` inherits the references.
- **Task 3**: `scripts/bloom_route.py` + `tests/unit/test_bloom_route.bats`
  prove `auto|manual|off` route differences. Orchestrator source has explicit
  fallback wording for ambiguous classification.
- **Task 4**: `scripts/build_instructions.sh` returns non-zero when
  `scripts/lib/build_specialist_variants.py` is missing unless
  `BUILD_ALLOW_FALLBACK=1` is set explicitly. Verified by
  `test_build_system.bats` (`invalid permission YAML fails generation`).
- **Task 5**: `git diff --check` exits 0; `test_build_system.bats` has a
  per-file whitespace gate covering all generated markdown.
- **Task 6**: `scripts/weekly_health_review.sh` now uses Python YAML parsing
  for both archive shapes (`queue/shogun_to_orchestrator_archive.yaml` and
  `queue/archive/`); inverted validation-miss logic fixed (was counting
  `done + required_validations present` instead of `done WITHOUT required_validations`).
  See follow-up plan `2026-06-27-orchestration-gap-review-followups-2.md` for
  the in-depth review.
- **Task 7**: `tests/unit/test_instruction_drift.bats` covers semantic checks
  per CLI (`/new` vs `/clear` wording, NO-ETA, 3-checkpoint rule, D-series
  Tier-1 anchors) — not just substring presence.
- **Task 8**: See `plans/2026-06-26-orchestration-gap-closure.md` updated
  Evidence Notes section (generated 2026-06-27).

## Review Summary

The recent implementation closes several local test gaps, and the targeted test
slice passed locally:

```bash
bats tests/unit/test_send_wakeup.bats \
  tests/unit/test_bloom_routing_setting.bats \
  tests/unit/test_build_specialist_variants.bats \
  tests/unit/test_instruction_drift.bats \
  tests/unit/test_required_validations.bats \
  tests/unit/test_check_role_permissions.bats \
  tests/unit/test_queue_health_check.bats \
  tests/unit/test_cmd_progress_summary.bats \
  tests/unit/test_check_batch_gates.bats \
  tests/unit/test_weekly_health_review.bats \
  tests/unit/test_slim_yaml.bats
```

Result: `150` tests passed.

Remaining gaps are mostly integration gaps: helpers exist locally but are ignored
by Git, guard scripts are not yet called by Orchestrator workflow, Bloom routing
is mostly config validation rather than dispatch behavior, and generated files
fail `git diff --check`.

## Findings

1. **P0: Required helper scripts are ignored by `.gitignore`.**  
   `scripts/build_instructions.sh` now calls
   `scripts/lib/build_specialist_variants.py`, and new tests call several new
   guard scripts, but all those files are still ignored by the whitelist
   `.gitignore`. Evidence:
   `git check-ignore -v scripts/lib/build_specialist_variants.py
   scripts/check_required_validations.py scripts/check_role_permissions.py
   scripts/check_batch_gates.py scripts/cmd_progress_summary.py
   scripts/queue_health_check.py scripts/weekly_health_review.sh`
   reports `.gitignore:7:*` for each file.

2. **P0: Guard helpers are standalone, not live gates.**  
   `check_required_validations.py`, `check_batch_gates.py`,
   `check_role_permissions.py`, `queue_health_check.py`, and
   `cmd_progress_summary.py` have tests, but Orchestrator instructions and
   runtime scripts do not yet call them at the required workflow points. That
   means live commands can still bypass validation, permission, batch, and queue
   gates unless an agent remembers to run the helpers manually.

3. **P0: Bloom routing is still mostly aspirational.**  
   `config/settings.yaml` now has `bloom_routing: auto`, and validation accepts
   the allowed values. The remaining missing part is the executable work-graph
   behavior required by the original task: when `auto`, Orchestrator must
   classify subtasks and route L1/L2/L3/L4/L5/L6 to the documented roles before
   dispatch.

4. **P0: `build_instructions.sh` masks the missing helper with a hard-coded fallback.**  
   If `scripts/lib/build_specialist_variants.py` is absent in a clean checkout,
   `build_instructions.sh` falls back to hard-coded specialist roles and CLIs.
   That preserves old behavior but fails the new acceptance criterion that
   adding a role in `config/settings.yaml` automatically emits variants without
   manual list updates.

5. **P1: Generated files fail whitespace verification.**  
   `git diff --check` reports trailing whitespace in generated orchestrator
   files:
   `instructions/generated/antigravity-orchestrator.md`,
   `instructions/generated/claude-orchestrator.md`,
   `instructions/generated/codex-orchestrator.md`,
   `instructions/generated/copilot-orchestrator.md`,
   `instructions/generated/cursor-orchestrator.md`,
   `instructions/generated/kimi-orchestrator.md`,
   `instructions/generated/orchestrator.md`.

6. **P1: Weekly health review checks the wrong archive shape.**  
   `scripts/weekly_health_review.sh` scans
   `queue/shogun_to_orchestrator_archive/*.yaml`, but this repo has
   `queue/shogun_to_orchestrator_archive.yaml` and `queue/archive/`. The current
   tests only assert that the script runs and prints section headers, so this
   false-negative path is not covered.

7. **P1: Drift tests are too shallow.**  
   Example: the Codex `/new` test only checks that `/new` appears somewhere in
   `AGENTS.md`. It does not validate every Codex generated prompt, nor does it
   protect against contradictory `/clear` wording remaining in Codex-specific
   contexts.

## Delegation Tasks

### Task 1: P0 Track all new executable helpers required by tests and build

Owner: fixer  
Validation: oracle  
Blocked by: None

What to build:
Update `.gitignore` allowlist so all new helper scripts are visible to Git:

- `scripts/lib/build_specialist_variants.py`
- `scripts/check_required_validations.py`
- `scripts/check_role_permissions.py`
- `scripts/check_batch_gates.py`
- `scripts/cmd_progress_summary.py`
- `scripts/queue_health_check.py`
- `scripts/weekly_health_review.sh`

Acceptance criteria:
- `git status --short --untracked-files=all` shows these scripts as tracked or
  staged, not hidden.
- `git check-ignore -v <each helper>` returns non-zero for every helper.
- A clean checkout can run `bash scripts/build_instructions.sh` without relying
  on ignored local files.

### Task 2: P0 Wire guard helpers into the live Orchestrator lifecycle

Owner: designer  
Implementation: fixer  
Validation: oracle  
Blocked by: Task 1

What to build:
Update Orchestrator source instructions and runtime flow so the new helpers are
called at concrete workflow points:

- `queue_health_check.py` before command processing or YAML slim.
- `check_role_permissions.py` before dispatching write-capable specialists.
- `check_required_validations.py` before marking a parent command done.
- `check_batch_gates.py` before batch2+ dispatch for large batch commands.
- `cmd_progress_summary.py` as the source for live stuck-command observability.

Acceptance criteria:
- The Orchestrator instructions name each helper and the workflow step where it
  runs.
- Tests fail if a done transition skips required validations.
- Tests fail if batch2 dispatch occurs before batch1 QC.
- The generated instructions are rebuilt and include the same helper workflow.

### Task 3: P0 Complete Bloom auto-routing beyond config validation

Owner: oracle  
Implementation: fixer  
Validation: council  
Blocked by: Task 2

What to build:
Implement an executable Bloom-routing step for Orchestrator work graph creation.
When `bloom_routing: auto`, every subtask must be classified and routed before
specialist dispatch. The output should be data in `queue/tasks/orchestrator.yaml`
or an equivalent work-graph artifact, not only prose.

Acceptance criteria:
- A test command with L1, L3, L4, L5/EVAL subtasks produces expected role
  assignments.
- The test proves `auto`, `manual`, and `off` differ.
- Orchestrator instructions define fallback behavior when classification is
  ambiguous or the classifier fails.
- The work graph records the Bloom level, route decision, and reason per task.

### Task 4: P0 Make build generation fail loudly when helper generation is unavailable

Owner: fixer  
Validation: oracle  
Blocked by: Task 1

What to build:
Remove or narrow the hard-coded fallback in `build_instructions.sh`. If the
Python helper is missing, the build should fail instead of silently producing
partial old-style outputs.

Acceptance criteria:
- Temporarily moving `scripts/lib/build_specialist_variants.py` out of the way
  makes `bash scripts/build_instructions.sh` fail with a clear error.
- Adding a new role to `config/settings.yaml` in a test emits variants for that
  role without any shell-list update.
- The fallback, if retained, is explicitly marked emergency-only and cannot be
  used in CI.

### Task 5: P1 Fix generated trailing whitespace and add a whitespace gate

Owner: fixer  
Validation: observer  
Blocked by: None

What to build:
Remove trailing whitespace at the source or normalization layer so regenerated
instruction files pass `git diff --check`.

Acceptance criteria:
- `git diff --check` exits 0.
- `bash scripts/build_instructions.sh` followed by `git diff --check` exits 0.
- Add a test or CI check for generated markdown whitespace.

### Task 6: P1 Repair weekly health review archive validation

Owner: fixer  
Validation: observer  
Blocked by: Task 1

What to build:
Update `scripts/weekly_health_review.sh` to inspect the repo's actual archive
locations: `queue/shogun_to_orchestrator_archive.yaml` and `queue/archive/`.
Add sandbox tests that create done commands with pending validations in both
archive layouts.

Acceptance criteria:
- A fixture with a done command and missing required validation increments the
  validation-miss count.
- A fixture without validation misses reports zero.
- Tests do not depend on the live queue directory.

### Task 7: P1 Strengthen instruction-drift tests beyond anchor presence

Owner: oracle  
Implementation: fixer  
Validation: council  
Blocked by: Task 5

What to build:
Convert drift tests from substring checks to semantic checks for each generated
target group.

Acceptance criteria:
- Codex generated prompts are checked for correct `/new` reset semantics and no
  contradictory Codex reset instruction.
- Claude/OpenCode/Copilot/Kimi/Antigravity generated prompts are checked against
  their own reset semantics.
- Checkpoint, status, destructive-operation, and NO-ETA rules are asserted
  across all generated targets that should contain them.

### Task 8: P2 Record completion evidence back into the original gap plan

Owner: shogun  
Support: oracle  
Blocked by: Tasks 1-7

What to build:
Update `plans/2026-06-26-orchestration-gap-closure.md` with completion evidence
for tasks that are genuinely complete, and leave unchecked any task still
blocked by these follow-ups.

Acceptance criteria:
- Each checked task has a short evidence note with the test or file that proves
  it.
- No task is marked complete solely because a helper script exists locally.
- The plan remains compatible with `auto_prompt`.

## Verification Commands

Run before closing this follow-up plan:

```bash
git check-ignore -v scripts/lib/build_specialist_variants.py \
  scripts/check_required_validations.py \
  scripts/check_role_permissions.py \
  scripts/check_batch_gates.py \
  scripts/cmd_progress_summary.py \
  scripts/queue_health_check.py \
  scripts/weekly_health_review.sh && exit 1 || true

bash scripts/validate_settings.sh
bash scripts/build_instructions.sh
git diff --check
bats tests/unit/test_send_wakeup.bats \
  tests/unit/test_bloom_routing_setting.bats \
  tests/unit/test_build_specialist_variants.bats \
  tests/unit/test_instruction_drift.bats \
  tests/unit/test_required_validations.bats \
  tests/unit/test_check_role_permissions.bats \
  tests/unit/test_queue_health_check.bats \
  tests/unit/test_cmd_progress_summary.bats \
  tests/unit/test_check_batch_gates.bats \
  tests/unit/test_weekly_health_review.bats \
  tests/unit/test_slim_yaml.bats
```

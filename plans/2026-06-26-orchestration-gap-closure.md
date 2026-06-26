---
title: Agentic Orchestration Gap Closure
auto_continue: true
project: lotuss
created: "2026-06-26"
---

# Plan: Agentic Orchestration Gap Closure

## Status

- [x] Task 1: P0 Fix lost `clear_command` retry when agents are busy
- [x] Task 2: P0 Reconcile the canonical task status model
- [x] Task 3: P0 Restore instruction generation parity and add drift gates
- [x] Task 4: P0 Make Bloom routing executable instead of aspirational
- [x] Task 5: P0 Enforce Orchestrator checkpoint notifications
- [x] Task 6: P0 Add validation-routing and acceptance-gate enforcement
- [x] Task 7: P1 Split the inbox watcher into deeper modules with explicit interfaces
- [x] Task 8: P1 Make role permissions enforceable across CLIs
- [x] Task 9: P1 Add queue hygiene and corruption recovery gates
- [x] Task 10: P1 Add live-state observability for stuck commands
- [x] Task 11: P1 Harden large-batch execution gates
- [ ] Task 12: P2 Document external/non-tmux audit mode
- [x] Task 13: P2 Consolidate generated specialist prompt variants
- [x] Task 14: P2 Add a recurring orchestration health review

### Evidence Notes

> Generated 2026-06-27 after the orchestration-gap-review follow-up plan.

- **Task 1**: `tests/unit/test_send_wakeup.bats` + `tests/e2e/e2e_busy_clear_guard.bats`
  — busy `clear_command` remains unread until reset is sent.
- **Task 2**: `instructions/common/task_flow.md` + `scripts/slim_yaml.py` agree on
  the canonical status set (idle/assigned/done/failed/pending_blocked);
  covered by `tests/unit/test_slim_yaml.bats`.
- **Task 3**: `tests/unit/test_instruction_drift.bats` (17 tests) checks
  reset/recovery semantics per CLI, 3-checkpoint rule, NO-ETA, and Tier-1
  destructive ops across all generated variants.
- **Task 4**: `scripts/bloom_route.py` (12 tests in `test_bloom_route.bats`)
  emits a work graph from `bloom_routing=auto|manual|off`; routes
  L1→explorer, L2-L3→orchestrator, L4→oracle, L5→oracle, L5/EVAL→council,
  L6→oracle.
- **Task 5**: `instructions/orchestrator.md` step 17 mandates 3 checkpoints;
  `tests/unit/test_check_required_validations.bats` enforces the gate.
- **Task 6**: `scripts/check_required_validations.py` +
  `scripts/check_role_permissions.py` wired into orchestrator step 8 and 16
  gates (verified by `tests/unit/test_build_system.bats` guard-wiring tests).
- **Task 7**: `scripts/inbox_watcher.sh` refactored into smaller modules;
  `tests/unit/test_watcher_supervisor.bats` covers the seams.
- **Task 8**: `scripts/check_role_permissions.py` + opencode-permissions.yaml
  agreement covered by `tests/unit/test_check_role_permissions.bats`.
- **Task 9**: `scripts/queue_health_check.py` + `tests/unit/test_queue_health_check.bats`
  reports corrupt / stale / oversized entries; orchestrator step 1.6 calls it.
- **Task 10**: `scripts/cmd_progress_summary.py` (covered by
  `tests/unit/test_cmd_progress_summary.bats`) is the live-state source
  referenced in orchestrator step 9.5.
- **Task 11**: `scripts/check_batch_gates.py` +
  `tests/unit/test_check_batch_gates.bats` enforce batch(N-1) QC before
  batch(N>=2) dispatch.
- **Task 13**: `scripts/lib/build_specialist_variants.py` is the single
  emission path; `scripts/build_instructions.sh` fails loudly when the
  helper is missing (BUILD_ALLOW_FALLBACK=1 for emergency use only).
  Verified by `tests/unit/test_build_specialist_variants.bats`. New
  inventory tests in `test_build_system.bats` reject legacy
  `claude-{shogun,orchestrator,telegram}.md` files and assert every CLI
  emits its command-layer variants.
- **Task 14**: `scripts/weekly_health_review.sh` scans both
  `queue/shogun_to_orchestrator_archive.yaml` and `queue/archive/`.
  Covered by `tests/unit/test_weekly_health_review.bats` (9 tests,
  including 4 fixture-based archive tests with proper YAML parsing,
  not the prior grep/awk heuristic).

Outstanding:
- **Task 12**: External/non-tmux audit mode doc is not yet written.

### Verification Outcomes (2026-06-27 review pass)

```bash
bash scripts/validate_settings.sh
git diff --check
bats tests/unit/test_send_wakeup.bats \
  tests/unit/test_bloom_route.bats \
  tests/unit/test_bloom_routing_setting.bats \
  tests/unit/test_build_specialist_variants.bats \
  tests/unit/test_instruction_drift.bats \
  tests/unit/test_required_validations.bats \
  tests/unit/test_check_role_permissions.bats \
  tests/unit/test_queue_health_check.bats \
  tests/unit/test_cmd_progress_summary.bats \
  tests/unit/test_check_batch_gates.bats \
  tests/unit/test_weekly_health_review.bats \
  tests/unit/test_slim_yaml.bats \
  tests/unit/test_build_system.bats
```

Observed:

- `validate_settings.sh`: PASS (`config/settings.yaml` validates — 9 roles,
  topology=v2).
- `git diff --check`: PASS (exit 0, no whitespace warnings).
- focused Bats slice: **262 tests passed, 0 skipped, 0 failed**.

Reopened in `plans/2026-06-27-orchestration-gap-review-followups-2.md`:
- Task 14 weekly-health-review validation-miss logic (P0-1) — fixed by replacing
  grep heuristic with Python YAML parsing and inverting the count condition.
- Plan files untracked (P0-2) — fixed by `git add` and `.gitignore` of
  `scratch/rust-ffmpeg/`.
- Claude command-variant inventory (P1-1) — fixed by removing legacy
  `claude-shogun.md` and adding inventory tests in `test_build_system.bats`.

## Problem

The orchestration is powerful, but several safety rules are currently split
between generated prose, source instructions, runtime shell scripts, tests, and
live queue state. That creates shallow modules: callers must remember too many
ordering rules, status exceptions, CLI differences, and recovery edge cases.

Key weaknesses found:

1. A redo/reset can be lost. `get_unread_info` marks special messages read
   before execution, including `clear_command`, while later processing skips
   `/clear` if the agent is busy. Evidence:
   `scripts/inbox_watcher.sh:487`, `scripts/inbox_watcher.sh:490`,
   `scripts/inbox_watcher.sh:493`, `scripts/inbox_watcher.sh:1164`,
   `scripts/inbox_watcher.sh:1168`.
2. The status interface is inconsistent. `AGENTS.md` says blocked work must
   stay in `queue/tasks/pending.yaml`, but `instructions/common/task_flow.md`
   still allows `blocked` inside specialist task files. Evidence:
   `AGENTS.md:47`, `AGENTS.md:50`,
   `instructions/common/task_flow.md:15`,
   `instructions/common/task_flow.md:80`,
   `instructions/common/task_flow.md:99`.
3. Generated instruction parity has drift. `CLAUDE.md` contains the
   three-checkpoint rule, but `AGENTS.md` does not show the corresponding
   task_status_transitions entry. Evidence: `CLAUDE.md:51`, `AGENTS.md:43`.
4. Bloom routing is mandatory in prose but not configured in the main settings
   file. Evidence: `AGENTS.md:62`, `config/settings.yaml:1`.
5. Orchestrator checkpoints and validation routing are instruction-only
   obligations unless tests assert the emitted inbox writes and validation
   queue states. Evidence: `instructions/orchestrator.md:147`,
   `instructions/orchestrator.md:157`,
   `instructions/orchestrator.md:112`.
6. The watcher module has too much behavior behind one shell interface:
   feature flags, metrics, special commands, context reset, stale-busy
   recovery, self-watch detection, nudging, and CLI normalization all share
   global state. Evidence: `scripts/inbox_watcher.sh:170`,
   `scripts/inbox_watcher.sh:760`, `scripts/inbox_watcher.sh:1215`.
7. Permissions are partly declarative. `config/settings.yaml` has
   `permissions_override`, while `config/opencode-permissions.yaml` is the
   concrete build input for OpenCode. Other CLIs mostly rely on prompt
   compliance. Evidence: `config/settings.yaml:78`,
   `config/opencode-permissions.yaml:3`.
8. Live queue hygiene is fragile. The active command queue is large, inbox
   `.corrupt` backups exist, and tmp files remain under `queue/`. This raises
   token cost and recovery ambiguity.

## Priority Legend

- P0: Can lose work, violate chain of command, mark incomplete work done, or
  make mandatory routing silently ineffective.
- P1: Causes operational fragility, high token cost, weak enforcement, or poor
  diagnosis during incidents.
- P2: Improves maintainability, review cadence, and non-core operating modes.

## Delegation Tasks

### Task 1: P0 Fix lost `clear_command` retry when agents are busy

Owner: fixer  
Validation: oracle  
Blocked by: None

What to build:
Move special-message acknowledgement after successful handling, or preserve
unhandled special messages as unread with retry metadata. A busy `clear_command`
must remain pending until a reset is actually sent or explicitly cancelled.

Acceptance criteria:
- A `clear_command` received while `agent_is_busy` remains `read: false`, or is
  rewritten to an equivalent pending retry message.
- Existing idle `clear_command` behavior still sends exactly one reset.
- Add regression coverage to `tests/unit/test_send_wakeup.bats` and
  `tests/e2e/e2e_busy_clear_guard.bats`.
- Verification shows no duplicate `/new` or `/clear` sends for rapid duplicate
  clear messages.

### Task 2: P0 Reconcile the canonical task status model

Owner: oracle  
Implementation: fixer  
Validation: council  
Blocked by: None

What to build:
Choose one canonical blocked-work model, then update source instructions,
generated instructions, fixtures, slim logic, and tests. Recommended model:
blocked work lives only in `queue/tasks/pending.yaml` as `pending_blocked`;
specialist task YAMLs use only `idle`, `assigned`, `done`, and `failed`.

Acceptance criteria:
- `instructions/common/task_flow.md`, `CLAUDE.md`, and `AGENTS.md` agree.
- E2E blocked-by tests use `queue/tasks/pending.yaml`, not pre-assigned blocked
  specialist files.
- `scripts/slim_yaml.py` active status sets match the canonical model.
- No test fixture teaches specialists to start from `status: blocked` unless
  the canonical decision explicitly keeps that status.

### Task 3: P0 Restore instruction generation parity and add drift gates

Owner: fixer  
Validation: oracle  
Blocked by: Task 2 if status wording changes

What to build:
Run the instruction-generation path through one source of truth and add a test
that fails when `CLAUDE.md`, `AGENTS.md`, generated role prompts, and
OpenCode/Copilot/Kimi variants drift in safety-critical rules.

Acceptance criteria:
- The three Orchestrator checkpoint rule appears in all relevant generated
  prompts.
- The Codex wording for `/new` remains correct without losing non-Codex rules.
- `bash scripts/build_instructions.sh` followed by `git diff --exit-code` is
  clean.
- Add a targeted test that asserts required safety strings across generated
  instruction outputs.

### Task 4: P0 Make Bloom routing executable instead of aspirational

Owner: oracle  
Implementation: fixer  
Validation: council  
Blocked by: None

What to build:
Define the real `bloom_routing` config interface and connect it to
Orchestrator dispatch. If set to `auto`, the Orchestrator must classify
subtasks and route L1/L2/L3/L4/L5/L6 work according to the documented mapping.

Acceptance criteria:
- `config/settings.yaml` has an explicit `bloom_routing` default with allowed
  values `off`, `manual`, and `auto`.
- `scripts/validate_settings.sh` rejects invalid values.
- Unit tests cover config parsing and routing decisions.
- E2E or integration coverage proves an `auto` command writes the intended
  work graph before dispatch.

### Task 5: P0 Enforce Orchestrator checkpoint notifications

Owner: fixer  
Validation: observer  
Blocked by: Task 3

What to build:
Add a small checkpoint ledger or testable inbox-write wrapper for Orchestrator
notifications to Shogun: acknowledged, dispatched, completed or failed.

Acceptance criteria:
- Every command path emits `cmd_acknowledged` before decomposition,
  `cmd_dispatched` after specialist assignment, and terminal
  `report_completed` or `report_failed`.
- Failure and action-required paths are covered.
- Tests fail if a command is marked done without the terminal Shogun message.

### Task 6: P0 Add validation-routing and acceptance-gate enforcement

Owner: fixer  
Validation: oracle  
Blocked by: Task 2

What to build:
Represent validation requirements in `queue/tasks/orchestrator.yaml` as data,
not only prompt text. A fixer implementation must require oracle review before
parent command completion; architecture decisions must require council review.

Acceptance criteria:
- The work graph records required validation routes per subtask.
- Orchestrator cannot mark parent command done while required validations are
  missing, failed, or stale.
- Acceptance criteria are checked against reports with an explicit pass/fail
  field.
- Add tests for missing validation, failed validation, and accepted validation.

### Task 7: P1 Split the inbox watcher into deeper modules with explicit interfaces

Owner: designer  
Implementation: fixer  
Validation: oracle  
Blocked by: Task 1

What to build:
Design and implement internal seams for the watcher: mailbox read/write,
special-command processing, nudge delivery, CLI reset mapping, busy detection,
metrics, and escalation policy. Keep the external command interface stable.

Acceptance criteria:
- Each internal module has a small test surface and avoids shared mutable
  globals except through an explicit state object.
- `inbox_watcher.sh` remains the public executable adapter.
- Existing watcher tests still pass, with new unit tests around each extracted
  module.

### Task 8: P1 Make role permissions enforceable across CLIs

Owner: council  
Implementation: fixer  
Validation: oracle  
Blocked by: Task 3

What to build:
Produce a permission-enforcement matrix for Claude, Codex, OpenCode, Copilot,
Kimi, and Antigravity. Where a CLI cannot enforce filesystem permissions,
add runtime guard scripts or preflight checks that detect forbidden file edits.

Acceptance criteria:
- `permissions_override` in `config/settings.yaml` has a documented consumer or
  is removed in favor of the real permission source.
- OpenCode permissions and prompt-level rules agree.
- Tests simulate a specialist attempting to edit another specialist's files and
  fail before completion.

### Task 9: P1 Add queue hygiene and corruption recovery gates

Owner: fixer  
Validation: observer  
Blocked by: Task 2

What to build:
Create a queue health checker that reports active queue size, terminal commands
left in active files, stale tmp files, corrupt inbox backups, and oversized
inboxes before Orchestrator work starts.

Acceptance criteria:
- Health check has dry-run and fix modes.
- It never deletes live unread messages.
- It reports active command count and byte size.
- Tests cover corrupt YAML, stale tmp files, and terminal command archiving.

### Task 10: P1 Add live-state observability for stuck commands

Owner: observer  
Implementation: fixer  
Validation: oracle  
Blocked by: Task 5

What to build:
Add a machine-readable command progress summary separate from `dashboard.md`,
including last checkpoint time, active specialists, unread report count,
validation state, and current blocker.

Acceptance criteria:
- Telegram `/dashboard` can fall back to live YAML when dashboard text is stale.
- The summary distinguishes "waiting on specialist", "waiting on validation",
  "waiting on Lord", and "delivery suspected stuck".
- Observer can verify a stuck-command fixture without reading pane scrollback.

### Task 11: P1 Harden large-batch execution gates

Owner: oracle  
Implementation: fixer  
Validation: council  
Blocked by: Task 6

What to build:
Turn the batch-processing protocol into executable checklist data for commands
with 30+ items: strategy review, batch1-only run, Shogun QC gate, stop-on-NG,
state restore, and final QC.

Acceptance criteria:
- Orchestrator refuses to dispatch batch2+ before batch1 QC is recorded.
- Batch tasks must include an unprocessed-item detection pattern.
- Test fixtures cover QC OK, QC NG, and missing quality template.

### Task 12: P2 Document external/non-tmux audit mode

Owner: librarian  
Implementation: fixer  
Validation: oracle  
Blocked by: None

What to build:
Document what a repo auditor can safely do when not running inside a Shogun
tmux pane. The current identity command fails outside tmux, but external
audits still happen.

Acceptance criteria:
- A short doc explains "external audit mode" versus live agent mode.
- It forbids processing live inboxes or mutating queue state without a verified
  agent id.
- It allows read-only architecture audits and plan creation.

### Task 13: P2 Consolidate generated specialist prompt variants

Owner: fixer  
Validation: oracle  
Blocked by: Task 3

What to build:
Remove redundant specialist generation paths so settings-driven discovery and
hard-coded specialist copying cannot disagree.

Acceptance criteria:
- One code path emits all specialist variants.
- Missing dependencies such as `yq` do not silently skip required generation if
  Python/YAML is already available.
- Tests cover adding a new role to `config/settings.yaml`.

### Task 14: P2 Add a recurring orchestration health review

Owner: shogun  
Support: oracle, observer  
Blocked by: Task 9 and Task 10

What to build:
Create a weekly health-review checklist that inspects queue size, corrupt
files, checkpoint latency, validation misses, test skips, and generated
instruction drift.

Acceptance criteria:
- The checklist is runnable without changing live task state.
- The output is suitable for `dashboard.md` or Telegram summary.
- The review recommends new tasks only when a threshold is exceeded.

## Suggested Parallelization

Wave 1:
- Task 1, Task 2, Task 4, and Task 5 can start independently.

Wave 2:
- Task 3 depends on the wording chosen in Task 2.
- Task 6 depends on the status model from Task 2.
- Task 9 depends on the queue/status model from Task 2.

Wave 3:
- Task 7 follows Task 1 so the watcher is not refactored around a known bug.
- Task 8 follows Task 3 so permission docs and generated prompts are stable.
- Task 10 follows Task 5 so observability can consume the checkpoint ledger.
- Task 11 follows Task 6 so batch gates reuse the same validation ledger.

Wave 4:
- Tasks 12, 13, and 14 are polish/maintenance work after the P0/P1 safety
  gates are in place.

## Verification Gate

Before marking this plan complete:

```bash
bats tests/*.bats tests/unit/*.bats
bash scripts/build_instructions.sh
git diff --exit-code instructions/generated/ AGENTS.md .github/copilot-instructions.md .opencode/agents/
```

Any skipped test is a failed verification unless the skip is explicitly
approved in the command acceptance criteria.

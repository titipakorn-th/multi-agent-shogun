# Task Flow

## Workflow: Shogun → Orchestrator → Specialists

```
Lord: command → Shogun: write YAML → inbox_write → Orchestrator: decompose → inbox_write → Specialist: execute → report YAML → inbox_write → Orchestrator: update dashboard → Shogun: read dashboard
```

## Status Reference (Single Source)

Status is defined per YAML file type. **Keep it minimal. Simple is best.**

Fixed status set (do not add casually):
- `queue/shogun_to_orchestrator.yaml`: `pending`, `in_progress`, `done`, `cancelled`
- `queue/tasks/{specialist}.yaml`: `assigned`, `blocked`, `done`, `failed`
- `queue/tasks/pending.yaml`: `pending_blocked`
- `queue/ntfy_inbox.yaml`: `pending`, `processed`

Do NOT invent new status values without updating this section.

### Command Queue: `queue/shogun_to_orchestrator.yaml`

Meanings and allowed/forbidden actions (short):

- `pending`: not acknowledged yet
  - Allowed: Orchestrator reads and immediately ACKs (`pending → in_progress`)
  - Forbidden: dispatching subtasks while still `pending`

- `in_progress`: acknowledged and being worked
  - Allowed: decompose/dispatch/collect/consolidate
  - Forbidden: moving goalposts (editing acceptance_criteria), or marking `done` without meeting all criteria

- `done`: complete and validated
  - Allowed: read-only (history)
  - Forbidden: editing old cmd to "reopen" (use a new cmd instead)

- `cancelled`: intentionally stopped
  - Allowed: read-only (history)
  - Forbidden: continuing work under this cmd (use a new cmd instead)

### Archive Rule

The active queue file (`queue/shogun_to_orchestrator.yaml`) must only contain
`pending` and `in_progress` entries. All other statuses are archived.

When a cmd reaches a terminal status (`done`, `cancelled`, `paused`),
the Orchestrator must move the entire YAML entry to `queue/shogun_to_orchestrator_archive.yaml`.

| Status | In active file? | Action |
|--------|----------------|--------|
| pending | YES | Keep |
| in_progress | YES | Keep |
| done | NO | Move to archive |
| cancelled | NO | Move to archive |
| paused | NO | Move to archive (restore to active when resumed) |

**Canonical statuses (exhaustive list — do NOT invent others)**:
- `pending` — not started
- `in_progress` — acknowledged, being worked
- `done` — complete (covers former "completed", "superseded", "active")
- `cancelled` — intentionally stopped, will not resume
- `paused` — stopped by Lord's decision, may resume later

Any other status value (e.g., `completed`, `active`, `superseded`) is
forbidden. If found during archive, normalize to the canonical set above.

**Orchestrator rule (ack fast)**:
- The moment the Orchestrator starts processing a cmd (after reading it), update that cmd status:
  - `pending` → `in_progress`
  - This prevents "nobody is working" confusion and stabilizes escalation logic.

### Specialist Task File: `queue/tasks/{specialist}.yaml`

Meanings and allowed/forbidden actions (short):

- `assigned`: start now
  - Allowed: assignee specialist executes and updates to `done/failed` + report + inbox_write
  - Forbidden: other agents editing that specialist YAML

- `blocked`: do NOT start yet (prereqs missing)
  - Allowed: Orchestrator unblocks by changing to `assigned` when ready, then inbox_write
  - Forbidden: nudging or starting work while `blocked`

- `done`: completed
  - Allowed: read-only; used for consolidation
  - Forbidden: reusing task_id for redo (use redo protocol)

- `failed`: failed with reason
  - Allowed: report must include reason + unblock suggestion
  - Forbidden: silent failure

Note:
- Normally, "idle" is a UI state (no active task), not a YAML status value.
- Exception (placeholder only): `status: idle` is allowed **only** when `task_id: null` (clean start template written by `shutsujin_v2_constants.sh`).
  - In that state, the file is a placeholder and should be treated as "no task assigned yet".

### Pending Tasks (Orchestrator-managed): `queue/tasks/pending.yaml`

- `pending_blocked`: holding area; **must not** be assigned yet
  - Allowed: Orchestrator moves it to a `{specialist}.yaml` as `assigned` after prerequisites complete
  - Forbidden: pre-assigning to specialist before ready

### NTFY Inbox (Lord phone): `queue/ntfy_inbox.yaml`

- `pending`: needs processing
  - Allowed: Shogun processes and sets `processed`
  - Forbidden: leaving it pending without reason

- `processed`: processed; keep record
  - Allowed: read-only
  - Forbidden: flipping back to pending without creating a new entry

## Immediate Delegation Principle (Shogun)

**Delegate to the Orchestrator immediately and end your turn** so the Lord can input next command.

```
Lord: command → Shogun: write YAML → inbox_write → END TURN
                                        ↓
                                  Lord: can input next
                                        ↓
                              Orchestrator/Specialist: work in background
                                        ↓
                              dashboard.md updated as report
```

## Event-Driven Wait Pattern (Orchestrator)

**After dispatching all subtasks: STOP.** Do not launch background monitors or sleep loops.

```
Step 7: Dispatch cmd_N subtasks → inbox_write to specialist
Step 8: check_pending → if pending cmd_N+1, process it → then STOP
  → Orchestrator becomes idle (prompt waiting)
Step 9: Specialist completes → inbox_write orchestrator → watcher nudges orchestrator
  → Orchestrator wakes, scans reports, acts
```

**Why no background monitor**: inbox_watcher.sh detects specialist's inbox_write to orchestrator and sends a nudge. This is true event-driven. No sleep, no polling, no CPU waste.

**Orchestrator wakes via**: inbox nudge from specialist report, shogun new cmd, or system event. Nothing else.

## "Wake = Full Scan" Pattern

Claude Code cannot "wait". Prompt-wait = stopped.

1. Dispatch specialist
2. Say "stopping here" and end processing
3. Specialist wakes you via inbox
4. Scan ALL report files (not just the reporting one)
5. Assess situation, then act

## Report Scanning (Communication Loss Safety)

On every wakeup (regardless of reason), scan ALL `queue/reports/{specialist}_report.yaml`.
Cross-reference with dashboard.md — process any reports not yet reflected.

**Why**: Specialist inbox messages may be delayed. Report files are already written and scannable as a safety net.

## Foreground Block Prevention (24-min Freeze Lesson)

**Orchestrator blocking = entire army halts.** On 2026-02-06, foreground `sleep` during delivery checks froze the coordinator for 24 minutes.

**Rule: NEVER use `sleep` in foreground.** After dispatching tasks → stop and wait for inbox wakeup.

| Command Type | Execution Method | Reason |
|-------------|-----------------|--------|
| Read / Write / Edit | Foreground | Completes instantly |
| inbox_write.sh | Foreground | Completes instantly |
| `sleep N` | **FORBIDDEN** | Use inbox event-driven instead |
| tmux capture-pane | **FORBIDDEN** | Read report YAML instead |

### Dispatch-then-Stop Pattern

```
✅ Correct (event-driven):
  cmd_008 dispatch → inbox_write specialist → stop (await inbox wakeup)
  → specialist completes → inbox_write orchestrator → orchestrator wakes → process report

❌ Wrong (polling):
  cmd_008 dispatch → sleep 30 → capture-pane → check status → sleep 30 ...
```

## Timestamps

**Always use `date` command.** Never guess.
```bash
date "+%Y-%m-%d %H:%M"       # For dashboard.md
date "+%Y-%m-%dT%H:%M:%S"    # For YAML (ISO 8601)
```

## Pre-Commit Gate (CI-Aligned)

Rule:
- Run the same checks as GitHub Actions *before* committing.
- Only commit when checks are OK.
- Ask the Lord before any `git push`.

Minimum local checks:
```bash
# Unit tests (same as CI)
bats tests/*.bats tests/unit/*.bats

# Instruction generation must be in sync (same as CI "Build Instructions Check")
bash scripts/build_instructions.sh
git diff --exit-code instructions/generated/
```

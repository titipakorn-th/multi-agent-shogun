---
title: Redo Auto-Recovery — "done" Status Not Guarded
auto_continue: false
created: "2026-06-27"
---

# Plan: Redo Auto-Recovery — "done" Status Not Guarded

Audit of the redo / `clear_command` auto-recovery path (`inbox_watcher.sh`
`enqueue_recovery_task_assigned` + the `process_unread` clear_command handler).

**This subsystem largely passes.** Unlike the prior four audits (auto_prompt,
team_monitor, LordChannel, inbox_watcher deferred-clear — each had a real P1/P2),
this path is well-built and I found no significant gap:

- Recovery enqueue is flock-protected with an atomic tmp+rename write.
- Dedup guard keeps only one pending `[auto-recovery]` hint at a time.
- A 5s wait lets the Orchestrator update the task YAML before the status check,
  mitigating the cancellation race.
- `clear_sent` is set ONLY when `send_cli_command` returns 0 (`:1313`), so a
  busy-defer (rc=2) or failure (rc=1) neither triggers auto-recovery nor loses
  the message — it goes to `deferred_ids` for retry. The rc=2 fix from
  `2026-06-27-inbox-watcher-deferred-clear-gap.md` is correctly honored here too.
- shogun `/clear` suppression is excluded from auto-recovery.

The single edge below is genuinely minor (P3) — recorded for completeness, not
because the path is broken.

> `auto_continue: false` — audit-surfaced, low priority. No rush.

## Status

- [ ] Task 1: P3 Add "done" to the auto-recovery status skip-guard (or confirm it's intended)

## Evidence

`scripts/inbox_watcher.sh:393` — the recovery skip-guard is:
```python
if task_status in ("cancelled", "idle"):
    print(f"SKIP_CANCELLED:{task_status}")
    raise SystemExit(0)
```
It skips auto-recovery when the agent's `queue/tasks/<agent>.yaml` status is
`cancelled` or `idle`, but **not** `done`. So if a `clear_command` arrives while
the task is `done` (e.g. a cleanup reset, or a redo where the new task YAML
hasn't been written yet at the moment of the check), the agent receives:

> `[auto-recovery] … Please re-read queue/tasks/<agent>.yaml and immediately
> resume the assigned task.`

— which tells it to resume a completed task. That contradicts the CLAUDE.md
`/clear` recovery rule for task-layer specialists: **`done = wait (DO NOT
re-report)`**. Worst case the agent re-executes or re-reports finished work.

**Why it's only P3 (real but well-defended):**
- The redo protocol normally writes the NEW task YAML (status `assigned`, new
  `task_id`) *before* sending `clear_command`, so by the 5s-delayed check the
  status is usually `assigned`, not `done`.
- The agent's own `/clear` recovery procedure independently applies `done=wait`.
- It only bites on a `clear_command` that lands while the YAML still reads
  `done` (cleanup resets, or a redo with a slow YAML write).

## Task Details

### Task 1: P3 Add "done" to the skip-guard (or document why not)

Either add `done` to the skip set at `inbox_watcher.sh:393`
(`if task_status in ("cancelled", "idle", "done"):`) so a completed task isn't
told to "resume," OR add a one-line comment documenting why `done` is
deliberately excluded (e.g. redo always overwrites `done`→`assigned` before the
clear_command, making the guard moot). If adding it, extend
`test_inbox_watcher_decisions.bats` / the recovery suite with a `status: done`
case asserting `SKIP_CANCELLED:done` (or a renamed `SKIP_TERMINAL:done`) so the
behavior is locked.

Acceptance: a `clear_command` processed while the task YAML reads `done` does
NOT enqueue an `[auto-recovery]` "resume" message (or the exclusion is
documented as intentional with the reasoning inline).

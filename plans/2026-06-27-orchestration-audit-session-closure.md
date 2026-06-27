---
title: Orchestration Audit Session — Closure
auto_continue: false
created: "2026-06-27"
---

# Plan: Orchestration Audit Session — Closure

Consolidated record of a multi-area audit of the orchestration system. Six
subsystems reviewed; every real gap found was fixed and tested in the same
session. **No open gaps of consequence remain.** The real outstanding action is
not more auditing — it is committing the accumulated work (see "Next action").

`auto_continue: false` — closure record, nothing to auto-dispatch.

## Status

- [x] auto_prompt wiring (4 rounds) — parser/runaway/consolidation all closed
- [x] team_monitor STALLED cooldown bypass (P1) — stable key + 8 tests
- [x] LordChannel callback-data format (P1) — unified opt_{i}, promote hardened, 24 tests
- [x] inbox_watcher deferred-/clear deadlock (P2) — rc=2 signal, gated resets, 93 tests
- [x] redo auto-recovery "done" status (P3) — done added to skip-guard, 7 tests
- [x] telegram bidirectional + option-select ask — assessed: already built+tested; P3 polish done (--tag, recipe doc, ask_lord.sh wrapper)
- [ ] (P3, optional) Make the recovery status-guard case-insensitive

## Audited areas + outcome

| Area | Plan | Severity found | State |
|------|------|----------------|-------|
| auto_prompt trigger/select/parser | `…-auto-prompt-wiring-gaps*.md` (×4) | P0/P1 (daemon dispatched nothing; later a live runaway) | closed, verified |
| team_monitor alerts | `…-team-monitor-alert-cooldown-gap.md` | P1 (cooldown defeated → 20× spam) | closed, verified |
| LordChannel ask | `…-lordchannel-callback-format-gap.md` | P1 (lord_ask answers corrupted) | closed, verified |
| inbox_watcher escalation | `…-inbox-watcher-deferred-clear-gap.md` | P2 (busy-defer re-armed deadlock) | closed, verified |
| redo / clear_command recovery | `…-redo-recovery-done-status-gap.md` | P3 (done not guarded) | closed, verified |
| telegram bidirectional + ask | `…-telegram-bidirectional-ask-assessment.md` | none (already built) | confirmed + P3 polish done |

Healthy subsystems confirmed in passing (no changes needed): `infra_liveness.sh`
fleet-active/at-rest detection; inbox hygiene cron (reap/reap_janitor/
repair_corrupt/backlog_alarm, idle under the 200-entry bound); team_monitor alert
delivery fallback; the redo auto-recovery flock/dedup/atomic-write/ordering.

## The one remaining micro-item (P3, optional)

`scripts/inbox_watcher.sh` `enqueue_recovery_task_assigned` status-guard
(`:393`) compares `task_status in ("cancelled", "idle", "done")` **case-
sensitively** (`test_inbox_watcher_recovery_done_skip.bats` test 24 codifies that
`DONE` uppercase does NOT skip). This matches the pre-existing cancelled/idle
behavior, so it is consistent, not broken. But a casing drift in how task status
is written would silently re-arm the done-resume edge the P3 fix just closed.

### Task: P3 (optional) normalize status casing in the recovery guard

Lower-case the parsed status before the membership check
(`task_status.lower() in ("cancelled", "idle", "done")`) so casing can't bypass
the guard. Update `test_inbox_watcher_recovery_done_skip.bats` test 24 to assert
uppercase `DONE` now DOES skip. Only worth doing if task YAMLs are not guaranteed
lowercase elsewhere; if they are, leave a one-line comment saying so and close
this out. Decision either way is fine — there is no live bug.

## Next action (not an audit task)

All session work is uncommitted. `git status` shows modified:
`scripts/inbox_watcher.sh`, `scripts/lib/lord_channel.py`, `scripts/lord_ask.sh`,
`scripts/team_monitor.sh`, `scripts/telegram_ask.py`, `instructions/shogun.md`;
plus new `scripts/ask_lord.sh`, the six `plans/2026-06-27-*` docs, and new test
suites (`test_team_monitor_alert_cooldown`, `test_lordchannel_callback_format`,
`test_inbox_watcher_deferred_clear`, `test_inbox_watcher_recovery_done_skip`,
`test_ask_lord_helper`). Recommend committing on a branch with a message
summarizing the six fixes, rather than running further audit rounds —
findings have reached P3 polish and the codebase is well-hardened.

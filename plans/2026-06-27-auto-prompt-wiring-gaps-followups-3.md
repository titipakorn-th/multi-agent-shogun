---
title: Auto-Prompt Wiring Gaps — Follow-ups Round 4 (residual hardening)
auto_continue: true
created: "2026-06-27"
---

# Plan: Auto-Prompt Wiring Gaps — Follow-ups Round 4

Rounds 1–3 are closed and verified at runtime: the daemon dispatches correctly,
the runaway is gone, the queue is clean, the session-cap resets, project routing
reads from the plan, the seen file is bounded, the hot loop is throttled, and the
two drifting parsers inside `auto_prompt_trigger.sh` now share
`scripts/lib/parse_inbox.sh`. All 33 bats across 4 suites pass.

What remains is **hardening, not breakage** — low-priority guards so the bug
class that bit us twice cannot return through the two parsers that were
intentionally left specialized, plus two small loose ends. Nothing here is
urgent; the system is correct as-is.

## Status

- [x] Task 1: P2 Guard self_heal & escalation_watchdog parsers against the END-only regression
- [x] Task 2: P3 Have self_heal/escalation reuse parse_inbox_entries (only if it stays lazy)
- [x] Task 3: P3 Verify the legacy `auto_1782130848` queue entry is intended, else remove
- [x] Task 4: P3 Trim the stale "Step 3.5 / step 6" comments now that the daemon owns dispatch

> **Closed 2026-06-27, verified at runtime.** T1: guard tests added & green —
> `TC-APR-11` (buried action_required still resolved) + escalation "multi-entry
> stale FIRST + read:true LAST still forwards"; both red if their parser reverts
> to END-only. T2: resolved as a documented decision (`parse_inbox.sh:20-30`) —
> specialized parsers are the deliberate end state, unified helper rejected as
> complexity. T3: legacy `auto_1782130848` removed (`grep -cE '^- id: auto_'` =
> 0). T4: stale "Step 3.5 / step 6" comments gone. Full suite 35/35 green;
> trigger runs clean; listener live.

## Evidence

**Two parsers still hand-rolled (by design).** `parse_inbox.sh:16-19` documents
the decision: `auto_prompt_self_heal.sh` (folds `content`) and
`escalation_watchdog.sh` (captures `timestamp` + `forwarded_at`) keep their own
parsers because they need fields the shared `parse_inbox_ids` /
`parse_inbox_entries` don't emit. Both currently use the correct
`flush()`-on-new-entry shape, so they are not broken. But the round-1/round-2
defect was *exactly* a hand-rolled parser silently reverting to an `END`-only
emit — and neither of these two has a test that would catch that regression
(their suites use small inboxes where the target entry is last/only). The
mitigation today is a doc comment; a one-line behavioral guard is cheaper
insurance.

**Loose ends.** `queue/shogun_to_orchestrator.yaml` still carries one historical
`auto_1782130848` cmd (a legit 2026-06-22 dispatch of the adopt-auto-prompt plan
Task 1) — confirm it is wanted, not leftover. And `auto_prompt_trigger.sh` still
references "Step 3.5" / "step 6 reset rule" in comments that predate the daemon
owning dispatch; harmless, but stale.

## Task Details

### Task 1: P2 Guard the two specialized parsers against the END-only regression

Add one bats case per script (`tests/unit/test_auto_prompt_action.bats`,
`tests/unit/test_escalation_watchdog.bats`): feed a **multi-entry** inbox where
the target entry (action_required for self_heal; stale action_required for
escalation) is **NOT last**, followed by at least one unrelated entry. Assert the
script still acts on the buried entry. These tests pass now and FAIL the instant
either parser reverts to an `END`-only emit — turning the `parse_inbox.sh` doc
note into an executable guard. Ponytail: two tests, no refactor.

Acceptance: each new test is green against the current parsers and red if the
parser is mutated to emit only at END.

### Task 2: P3 Reuse parse_inbox_entries in self_heal/escalation — only if it stays lazy

Optional. If (and only if) a shared parser can serve all field needs without
growing into a complex everything-emitter, extend `parse_inbox.sh` with one
function that emits the extra fields (e.g. `parse_inbox_full` →
`id\ttype\tread\ttimestamp\tforwarded_at\tcontent`) and have self_heal /
escalation consume it with a downstream `cut`/`awk`. If that helper ends up
harder to read than the two small parsers it replaces, **do not do it** — the
round-3 decision to keep them specialized stands. This task exists only so the
option is recorded, not mandated.

Acceptance: either one helper cleanly serves all four call sites with all suites
green, or a one-line note in `parse_inbox.sh` confirming the specialized parsers
are the deliberate end state.

### Task 3: P3 Confirm or remove the legacy auto_ queue entry

Check whether `auto_1782130848` in `queue/shogun_to_orchestrator.yaml` is still
meaningful (its plan task may already be done). If the adopt-auto-prompt Task 1
is complete, remove the stale entry; otherwise leave it. Verify with the
Orchestrator that nothing is mid-flight before deleting. Report before/after
`grep -cE '^- id: auto_'` counts.

### Task 4: P3 Trim stale comments in auto_prompt_trigger.sh

The comments referencing "Step 3.5 (manual auto_prompt check)" and "step 6 reset
rule" describe the pre-daemon manual flow. Update them to reflect that the
listener-driven trigger now owns dispatch and reset. Comment-only; no behavior
change. Keep the load-bearing `flush()` warnings intact.

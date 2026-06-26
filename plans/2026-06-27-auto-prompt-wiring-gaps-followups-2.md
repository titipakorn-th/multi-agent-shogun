---
title: Auto-Prompt Wiring Gaps — Follow-ups Round 3
auto_continue: false
created: "2026-06-27"
---

# Plan: Auto-Prompt Wiring Gaps — Follow-ups Round 3

Round 2 closed all four tasks with green unit tests — but runtime review found
Task 3 (seen-file pruning) reintroduced the **same last-entry-only awk bug** that
round-1 Task 1 fixed, in a second hand-rolled copy of the inbox parser. It is
**live and actively misbehaving**: idempotency is broken, the same
`report_completed` re-dispatches every loop, and the orchestrator queue already has 12
duplicate auto_ cmds. This round stops the bleeding, cleans the mess, adds the
test that would have caught it, and removes the duplication that lets this bug
keep coming back.

> `auto_continue: false` on this plan **on purpose** — the auto_prompt path is
> currently unsafe (runaway). Do not let it self-dispatch its own fix. Flip to
> `true` only after Task 1 lands and the runaway is confirmed stopped.

## Status

- [x] Task 1: P0 Fix the `inbox_ids` parser in the seen-prune block (live runaway)
- [x] Task 2: P0 Clean up runaway pollution: dedupe the queue + reset the counter
- [x] Task 3: P1 Add the regression test that catches a buried seen-id
- [x] Task 4: P1 Consolidate inbox parsing into ONE shared helper (kill the bug class)

> **Closed 2026-06-27, verified at runtime.** Parser fixed → `inbox_ids` emits
> 34/34 live; runaway halted (trigger exit 0, `dispatched=0`, idempotent).
> Queue cleaned: 12 dupes gone, 1 legit historical `auto_` cmd remains,
> `dispatches_this_session: 1`, dispatched-tracking empty. Regression test #13
> ("buried seen-id: NOT last → no re-dispatch") added and green. Consolidation:
> the two drifting same-field parsers inside `auto_prompt_trigger.sh` now share
> `scripts/lib/parse_inbox.sh` (`parse_inbox_ids` / `parse_inbox_entries`).
> `self_heal` (needs content) and `escalation_watchdog` (needs timestamp +
> forwarded_at) keep their own field-specific parsers **by design** — both
> already use the correct `flush()` shape; `parse_inbox.sh` documents the
> canonical pattern. All 33 bats across the 4 suites pass; listener live
> (PID-checked) and running the migrated trigger clean. Residual hardening →
> `plans/2026-06-27-auto-prompt-wiring-gaps-followups-3.md`.

## Evidence

**The regression (P0, live).** `auto_prompt_trigger.sh:40-45` computes
`inbox_ids` for seen-file pruning with:
```awk
/^- content:/ { in_entry = 1; cur_id = ""; next }
in_entry && /^  id:/ { sub(/^  id: */, ""); cur_id = $0; next }
in_entry && /^- / { in_entry = 0; next }
END { if (cur_id != "") print cur_id }
```
This only prints at `END` → emits **1** id (the last entry's) out of **34**.
Proof against the live inbox: parser emits `msg_20260627_033105_b3766279`
(last entry) only; the re-dispatched report `msg_20260626_141555_70fe7301`
is *not* in the set. So the prune `grep -Fxf inbox_ids .auto_prompt_seen`
drops the report's id from the seen file every loop → next loop treats it as
unseen → re-dispatches. This is byte-for-byte the bug round-1 Task 1 fixed in the
*main* parser; Task 3 copied the old broken shape instead of the `flush()` shape.

**Live blast radius (observed):**
- `queue/auto_prompt_state.yaml`: `dispatches_this_session: 14` and climbing.
- `queue/shogun_to_orchestrator.yaml`: **13 auto_ cmds, 12 identical** —
  all "Task 12: P2 Document external/non-tmux audit mode" from the same plan.
- Trigger log: same `msg_id=...141555...` processed pass after pass, `dispatched=1` each time.
- Task 1's reset zeroes `dispatches_this_session` whenever the auto_ cmd reports
  back, so the `max_dispatches_per_session: 20` cap never actually halts it.

**Why tests miss it:** the seen-prune test (#12) uses a tiny inbox where the
seen id is reachable/last — exactly the one position the broken parser reads.
Same blind spot as the original round-1 bug.

**Root cause is duplication.** Three scripts hand-roll the same inbox-entry awk:
`auto_prompt_trigger.sh` (twice now — main parser fixed, prune parser broken),
`auto_prompt_self_heal.sh` (correct `flush()` version), `escalation_watchdog.sh`.
Round 1 fixed one copy; round 2 broke a different copy. Until there is one
parser, this bug will keep resurfacing.

## Task Details

### Task 1: P0 Fix the `inbox_ids` parser in the seen-prune block

Replace the `END`-only awk at `auto_prompt_trigger.sh:40-45` with the `flush()`
-on-every-`/^- content:/` pattern already used by the main parser in the same
file (and by `auto_prompt_self_heal.sh:21-27`). After the fix, `inbox_ids` must
list **all** inbox ids, so a still-present `report_completed` stays in
`.auto_prompt_seen` and is not re-dispatched.

Acceptance: against the live `queue/inbox/shogun.yaml`, the `inbox_ids` awk emits
34/34 ids; the trigger log stops re-processing the same `msg_id`; a full loop
leaves `dispatched=0` when no genuinely-new report arrived. Runtime state, not
just a passing test.

### Task 2: P0 Clean up the runaway pollution

This is a runtime-state task (CLAUDE.md U5: done = observed state, not a green
suite). After Task 1 stops the source:
- Remove the duplicate auto_ cmds from `queue/shogun_to_orchestrator.yaml` —
  keep at most one dispatch of "Task 12: P2 Document external/non-tmux audit
  mode" (or none if the Orchestrator already actioned it; verify first). Confirm
  with the Orchestrator that no duplicate is mid-flight before deleting.
- Reset `queue/auto_prompt_state.yaml` → `dispatches_this_session: 0`.
- Reconcile `.auto_prompt_seen` / `.auto_prompt_dispatched` with the real inbox.

Acceptance: `grep -c 'id: auto_'` on the queue reflects only legitimately-pending
auto cmds; counter at a truthful value; before/after counts in the report.

### Task 3: P1 Add the regression test that catches a buried seen-id

Add a bats case to `tests/unit/test_auto_prompt_trigger.bats`: inbox with a
`report_completed read:true` whose id is **already in `.auto_prompt_seen`**, with
**other entries after it** (so it is NOT the last entry). Assert the trigger does
**not** re-dispatch and does **not** drop that id from the seen file. This must
FAIL against the current `inbox_ids` awk and PASS after Task 1.

Acceptance: the new test reproduces the runaway pre-fix and goes green post-fix.

### Task 4: P1 Consolidate inbox parsing into one shared helper

Extract a single `parse_inbox_entries` (or `inbox_ids`) helper — the correct
`flush()` parser — into one sourced lib, and have `auto_prompt_trigger.sh` (both
call sites), `auto_prompt_self_heal.sh`, and `escalation_watchdog.sh` call it
instead of each re-deriving the awk. One parser, one place to be correct.
Ponytail: this is the one abstraction worth adding here — the duplication has now
caused the *same* bug twice across two rounds; a single tested helper closes the
class. Audit `escalation_watchdog.sh` while consolidating — confirm whether its
copy has the same `END`-only defect and fix it in the move.

Acceptance: only one inbox-entry awk remains in the codebase; all callers use it;
existing suites stay green.

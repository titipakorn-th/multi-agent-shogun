---
title: Auto-Prompt Wiring Gaps — Follow-ups
auto_continue: true
created: "2026-06-27"
---

# Plan: Auto-Prompt Wiring Gaps — Follow-ups

Round 1 (`plans/2026-06-27-auto-prompt-wiring-gaps.md`) is closed and verified at
runtime — the daemon now genuinely dispatches (observed `session=2/20`, one
`auto_` cmd appended, `processed_reports=1`). Making it *work* exposed four
residual gaps that only matter now that the path is live. Two are P1 (silent
death + mis-tagged dispatches), two are P2 hygiene.

## Status

- [x] Task 1: P1 Implement the session-cap reset (counter is a one-way ratchet → permanent silent death at 20)
- [x] Task 2: P1 Stop hardcoding `project: safepay` — read the project from the plan
- [x] Task 3: P2 Bound `.auto_prompt_seen` growth (append-only, never pruned)
- [x] Task 4: P2 Stop full-scanning the inbox twice every 0.5s loop (trigger + self_heal)

> **Closed 2026-06-27 — but Task 3 shipped a P0 regression.** Code + unit tests
> all landed (18/18 bats green: reset #9, project flow #10/#11, seen-prune #12,
> throttle wired). HOWEVER runtime verification found Task 3's `inbox_ids` awk
> (`auto_prompt_trigger.sh:40-45`) reintroduced the **exact last-entry-only bug
> round-1 Task 1 fixed** — it emits 1 id of 34, so the seen file is wrongly
> pruned every loop and the same `report_completed` is re-dispatched endlessly.
> Live impact when reviewed: `dispatches_this_session=14` and climbing, **12
> identical auto_ cmds** for one task piled into the orchestrator queue. Task 1's
> reset compounds it (zeros the counter each time, so the cap never stops the
> runaway). Round 3 → `plans/2026-06-27-auto-prompt-wiring-gaps-followups-2.md`.

## Evidence

**Gap 1 — no reset path (P1, silent kill switch).**
`auto_prompt_trigger.sh:17` and `:94` *document* "if cmd id starts with `auto_`,
reset `dispatches_this_session`," but no code implements it. Both
`auto_prompt_trigger.sh:124` and `auto_prompt_self_heal.sh:51-52` only
**increment**. Repo-wide grep for any reset-to-0 of `dispatches_this_session`:
none. The counter is meant to be per-Lord-session but nothing resets it, so once
it reaches `max_dispatches_per_session` (20) the trigger's Gate 2
(`auto_prompt_trigger.sh:46`) blocks every future dispatch permanently until a
human hand-edits `queue/auto_prompt_state.yaml`. Currently `2/20` — not urgent,
but it *will* hit 20 and the autonomy silently dies with no error. This is the
same "looks healthy, does nothing" failure mode round 1 just fixed.

**Gap 2 — hardcoded project (P1, mis-routing).**
`auto_prompt_trigger.sh:97` hardcodes `local project="safepay"`, written into
every auto-dispatched cmd at `:110`. The system runs work across multiple
projects (Lotuss/MNS/FlowCore/safepay), and plans carry no `project:` field for
the trigger to read (grep `^project:` over `plans/*.md`: none). So every
auto-continued task is tagged `safepay` regardless of which plan produced it →
Orchestrator routes/contextualizes it under the wrong project.

**Gap 3 — unbounded seen file (P2).**
`queue/.auto_prompt_seen` is append-only (`auto_prompt_trigger.sh:74`), never
pruned. 3 lines today, but it grows one line per processed report forever — same
unbounded-growth class CLAUDE.md U5/U7 calls out for the inbox.

**Gap 4 — double O(n) scan every tick (P2).**
The listener loop (`telegram_listener.py`, `time.sleep(0.5)`) shells out to
*both* `auto_prompt_trigger.sh` and `auto_prompt_self_heal.sh` every ~0.5s, each
doing a full awk pass over the whole (unbounded) inbox. `self_heal` was designed
as a session-start guard (cmd_039), not a hot-loop scan. Cost grows with inbox
size × 2 scripts × 2/sec.

## Task Details

### Task 1: P1 Implement the session-cap reset

Make `dispatches_this_session` actually reset, matching the documented intent at
`auto_prompt_trigger.sh:17`. Pick the simplest correct trigger:
- When an `auto_`-prefixed cmd reaches `report_completed` in Shogun's inbox,
  reset the counter to 0 (the documented rule — the auto-dispatched work landed,
  so the "session" of pending auto-work is clear); **or**
- Reset on a real session boundary (new `session_id` written at Lord-session
  start / `/clear`), since the field is named per-session.
Whichever is chosen, write the reset where it is *observed to fire* (not just
defined) and update the now-stale comments at `:17` and `:94`. Add one bats case:
counter at max → an `auto_` report_completed arrives → counter resets to 0 → next
report dispatches again.

Acceptance: with the counter at `max`, completing an `auto_` cmd lets a
subsequent `report_completed` dispatch (proven by test + a live log line showing
the reset), instead of being blocked forever.

### Task 2: P1 Read the project from the plan instead of hardcoding

Add an optional `project:` frontmatter field to plans, have
`auto_prompt_select.sh` emit it (e.g. `PROJECT=<name>`), and have
`auto_prompt_trigger.sh` use it at `:97/:110` with a sane fallback when the plan
omits it. Backfill `project:` into existing plans that drive auto-dispatch.
Ponytail: one new frontmatter key + one `grep` in select + one var swap in
trigger — no schema, no validation layer.

Acceptance: an auto-dispatched cmd from a `project: lotuss` plan is written with
`project: lotuss`, not `safepay`; a plan with no `project:` falls back to a
documented default.

### Task 3: P2 Bound the seen file

Cap `queue/.auto_prompt_seen` (e.g. keep the last N ids, or prune ids whose
msg no longer exists in the inbox). Idempotency only needs to cover ids still
reachable in the inbox, so pruning to the inbox's current id set is sufficient
and self-limiting. One `grep -Ff` / `tail -n` is enough — no new store.

Acceptance: after many dispatches the seen file stays bounded; re-runs still
don't double-dispatch a still-present report.

### Task 4: P2 Throttle the hot-loop scans

Stop running both `auto_prompt_trigger.sh` and `auto_prompt_self_heal.sh` on
every 0.5s tick. Options: gate them behind an inbox-mtime check (only scan when
the inbox changed since last run), or run them on a slower cadence (every N
seconds) than the rest of the loop. self_heal in particular is a recovery guard,
not a per-tick job. Keep it idempotent.

Acceptance: with an unchanged inbox, the two scripts do not re-scan every tick
(proven by log cadence or an mtime short-circuit), and a changed inbox is still
processed promptly.

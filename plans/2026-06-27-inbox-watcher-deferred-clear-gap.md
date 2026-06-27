---
title: inbox_watcher Deferred /clear Re-Arms Busy Deadlock
auto_continue: false
created: "2026-06-27"
---

# Plan: inbox_watcher Deferred /clear Re-Arms Busy Deadlock

Audit of the `inbox_watcher.sh` escalation/delivery path (0-2min nudge → 2-4min
Escape+nudge → 4min+ /clear). Most of it is well-hardened: the phase-3 /clear is
gated by a cooldown, a codex skip, a command/analysis-layer skip, AND a
defense-in-depth `agent_is_busy` guard inside `send_cli_command` so a working
agent is never wiped mid-task. Good.

**The gap:** when phase-3 /clear is *deferred* because the agent is busy, the
caller treats it as if the /clear succeeded — resetting the latency timer and
starting the /clear cooldown. For a genuinely-stuck-but-"busy" agent this
re-arms the exact deadlock the stale-busy recovery net exists to break, so the
/clear can be deferred forever and the unread message never delivered.

> `auto_continue: false` — audit-surfaced. Let Shogun dispatch deliberately.

## Status

- [x] Task 1: P2 Make send_cli_command signal a busy-defer; don't reset timers on a /clear that didn't fire
- [x] Task 2: P2 Regression test: deferred /clear must NOT reset FIRST_UNREAD_SEEN / LAST_CLEAR_TS
- [x] Task 3: P3 Cap or escalate the non-claude "pause escalation timer while busy" path

> **Closed 2026-06-27, verified.** `send_cli_command` now returns `2` on
> busy-defer (`:699`); the phase-3 caller gates resets behind
> `if send_cli_command "/clear"; then …` so `LAST_CLEAR_TS`/`FIRST_UNREAD_SEEN`
> only reset on an actual send (rc=0), preserving the timer on defer (rc=2) and
> real failure (rc=1). Non-claude busy branch switched to set-if-unset so the
> stale-busy net can fire. 93/93 across `test_inbox_watcher_deferred_clear.bats`
> (8 new: rc=2, no send-keys, timer preserved on defer, LAST_CLEAR_TS not
> advanced, not-busy fires+resets, non-claude set-once, stale-busy net reachable),
> `test_inbox_watcher_decisions.bats`, `test_send_wakeup.bats`.

## Evidence

**The defer is silent.** `scripts/inbox_watcher.sh:692-695` — when `cmd == /clear`
and `agent_is_busy`, `send_cli_command` logs `[SKIP] … /clear deferred` and
`return 0`. Exit 0 is identical to a successful send; the caller cannot tell the
/clear was suppressed.

**The caller assumes success.** `scripts/inbox_watcher.sh:1473-1477` (phase-3
branch):
```
echo "... Sending /clear." >&2
send_cli_command "/clear"      # returns 0 whether it cleared OR deferred-on-busy
LAST_CLEAR_TS=$now             # cooldown starts even if nothing was sent
FIRST_UNREAD_SEEN=0            # latency timer reset even if nothing was sent
NEW_CONTEXT_SENT=0
```

**Why it deadlocks.** The stale-busy recovery net (`:1378-1381`,
`stale_busy_limit=300`) is meant to break a false-busy deadlock: if an agent has
unread for ≥5 min while "busy", force-create the idle flag and fall through to
escalation. But the idle *flag* is separate from `agent_is_busy()` (which reads
the pane "Working" state). So:

1. age hits 300s → net force-sets idle flag → falls through to phase-3.
2. phase-3 → `send_cli_command /clear` → still busy → deferred → `return 0`.
3. caller resets `FIRST_UNREAD_SEEN=0` (and `LAST_CLEAR_TS=$now`).
4. next cycle the busy-path (`:1373`) restarts `FIRST_UNREAD_SEEN=$now`; age must
   climb to 300 again before the net re-fires → step 1.

The latency timer never accumulates past `stale_busy_limit`, so the deadlock the
net was built to break is re-armed every cycle. Net effect: a genuinely stuck
"busy" agent gets its /clear perpetually deferred and the unread message is never
delivered. Secondary: `LAST_CLEAR_TS=$now` on a no-op forces a 5-min /clear
cooldown, so even a transient busy blip pushes the next *real* /clear out 5 min.

**Secondary (P3).** `:1395-1397` — for non-claude busy agents the timer is reset
(`FIRST_UNREAD_SEEN=$now`) every cycle ("pausing escalation timer while busy").
Intentional (no Stop hook to lean on), but it means the stale-busy net at
`:1380` can NEVER fire for codex/copilot/kimi/opencode — a false-busy non-claude
agent has no automatic recovery at all.

## Task Details

### Task 1: P2 Signal busy-defer and gate the post-/clear state mutations

Have `send_cli_command` return a distinct non-zero code (e.g. `2`) on the
busy-defer at `:694` instead of `0`. At the phase-3 call site (`:1473-1477`),
only run `LAST_CLEAR_TS=$now`, `FIRST_UNREAD_SEEN=0`, `NEW_CONTEXT_SENT=0` when
the command actually fired (exit 0). On a defer, leave `FIRST_UNREAD_SEEN`
untouched so latency keeps accumulating and the stale-busy net stays armed; do
not start the /clear cooldown for a /clear that never happened.

Acceptance: simulate a busy agent at phase-3 → `/clear` deferred →
`FIRST_UNREAD_SEEN` unchanged and `LAST_CLEAR_TS` not advanced; once the agent is
no longer busy, the next phase-3 actually sends /clear. Verify via the watcher's
log lines / a unit harness around the escalation function.

### Task 2: P2 Regression test for the deferred-/clear path

Add a test (extend an existing inbox_watcher/escalation suite, or new) that
drives the escalation function with `agent_is_busy` stubbed true at phase-3 and
asserts: (a) no /clear send-keys are emitted, (b) `FIRST_UNREAD_SEEN` is NOT
reset to 0, (c) `LAST_CLEAR_TS` is NOT advanced. It must fail against today's
unconditional resets and pass after Task 1. Use the existing `ASW_*` env knobs
to keep it hermetic.

Acceptance: red on current code, green after Task 1.

### Task 3: P3 Bound the non-claude "pause timer while busy" path

Decide how a false-busy non-claude agent recovers. Options: (a) let
`FIRST_UNREAD_SEEN` accumulate (set-if-unset, like the claude branch at
`:1390-1391`) so the stale-busy net can fire for non-claude too; or (b) keep the
pause but add a hard cap (e.g. after N consecutive busy cycles, force the idle
flag once). Without this, a non-claude agent wedged in a false-busy state has no
automatic recovery — only operator intervention.

Acceptance: a non-claude agent stuck "busy" with unread for a bounded time gets
an automatic recovery action (forced idle flag or escalation), proven by test or
log evidence.

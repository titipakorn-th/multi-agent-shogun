---
title: Auto-Prompt Wiring Gaps
auto_continue: true
created: "2026-06-27"
---

# Plan: Auto-Prompt Wiring Gaps

Investigation of whether `auto_prompt` is properly wired and working. Verdict:
**wired but broken in production**. The daemon trigger is hooked into the
listener loop and gated correctly, but a YAML parser bug means it never sees the
`report_completed` entry in a real (multi-entry) inbox, so it has been silently
dispatching **nothing**. Unit tests are all green because every fixture places
the `report_completed` entry last — the one position the buggy parser can read.
This is the exact U5/U6/U7 failure pattern from CLAUDE.md: green tests, inert
runtime.

## Status

- [x] Task 1: P0 Fix multi-entry inbox parser in auto_prompt_trigger.sh
- [x] Task 2: P0 Add multi-entry regression test (report_completed NOT last)
- [x] Task 3: P1 Verify the listener daemon (the only trigger caller) is actually running
- [x] Task 4: P2 Fix misleading hardcoded `processed_reports=0` log line
- [x] Task 5: P2 Decide + wire action_required self-heal (currently LLM-manual only)

> **Closed 2026-06-27, verified at runtime.** Parser reads 34/34 live inbox
> entries; bats test #8 (report_completed buried, not last) passes; listener
> live (PID-checked) and supervised by `listener_watchdog.sh` via the
> `infra_liveness.sh` cron (`*/5`); `processed_reports` now a real counter
> (logged `=1`); `self_heal_inbox` wired into the listener loop
> (`telegram_listener.py:2051-2062`), firing clean (`resolved=0`, exit 0).
> Residual gaps surfaced by the now-working system →
> `plans/2026-06-27-auto-prompt-wiring-gaps-followups.md`.

## Evidence

**Wiring that IS correct:**
- `config/settings.yaml:16` — `auto_prompt.enabled: true`, `max_dispatches_per_session: 20`, `prompt_when_no_plans: false`.
- `scripts/telegram_listener.py:2027-2040` — calls `scripts/lib/auto_prompt_trigger.sh` every loop iteration, logging to `logs/auto_prompt_trigger.log`. Idempotent + config-gated. Good.
- `auto_prompt_trigger.sh` gates: config flag (Gate 1), session cap (Gate 2), `read:true` filter, `.auto_prompt_seen` idempotency. All correct.
- `auto_prompt_select.sh` plan/task selection — reads `## Status` `- [ ]` lines, honors `auto_continue: false`. Correct, and uses the right parsing.

**The bug (root cause):** `scripts/lib/auto_prompt_trigger.sh:53-61`. The awk that
extracts `(id, type, read)` tuples only prints an entry on a blank line (`/^$/`)
or at `END`. Inbox entries are written back-to-back with **no blank line between
them**, so the next `- content:` resets the field buffers *without printing the
previous entry*. Net effect: **only the last entry in the file is ever emitted.**

Empirical proof against the live inbox:
```
$ awk '<trigger parser>' queue/inbox/shogun.yaml | wc -l
1                          # emitted
$ grep -c '^- content:' queue/inbox/shogun.yaml
34                         # actual entries
```
Isolated repro with `report_completed` first and a fresh `alert` last (realistic
ordering) → `dispatched=0`, no dispatch marker. Reverse the order and it fires.
So in production the `report_completed` is essentially never last → the whole
autonomous continuation mechanism is dead.

**Why tests miss it:** `tests/unit/test_auto_prompt_trigger.bats` — every fixture
(lines 65-73, 105, 136-145) has the `report_completed` as the only/last entry.
All 7 tests pass while the real path is broken.

**The correct pattern already exists in this repo:**
`scripts/lib/auto_prompt_self_heal.sh:21-27` uses a `flush()` function called on
each new `/^- content:/` (and at END). That handles back-to-back entries
correctly. `auto_prompt_trigger.sh` (written 3 days later) did not adopt it.

**Secondary findings:**
- `auto_prompt_trigger.sh:63` logs `processed_reports=0` as a hardcoded literal — it always says 0 regardless of reality, which actively hid this bug from the logs.
- The listener (`telegram_listener.py`) — the only caller of the trigger — was not running at investigation time (`ps` showed no process; last log line 2026-06-26 15:51). May be off-hours, but per CLAUDE.md U6/U7 "wiring is not running," needs a liveness/supervision check.
- `auto_prompt_self_heal.sh` + `auto_prompt_resolve_action.sh` (action_required auto-resolution) have **no automated caller**. They are invoked only as a manual LLM step in `instructions/shogun.md:728-730`. The daemon handles `report_completed` but not `action_required`; the latter depends entirely on the Shogun LLM remembering to run it at session start.

## Task Details

### Task 1: P0 Fix multi-entry inbox parser in auto_prompt_trigger.sh

Replace the blank-line/END-only emission in the awk block at
`scripts/lib/auto_prompt_trigger.sh:53-61` with the `flush()`-on-new-entry
pattern already proven in `scripts/lib/auto_prompt_self_heal.sh:21-27`: define a
`flush()` that emits the buffered `(id, type, read)` tuple when complete, call it
at the top of every `/^- content:/` match and once at `END`. Drop the
unreliable `/^$/` and `/^- /` emission rules.

Acceptance: running the parser against the live `queue/inbox/shogun.yaml`
(34 entries) emits one tuple per entry, not 1. The buried `report_completed`
entry is among them.

### Task 2: P0 Add multi-entry regression test (report_completed NOT last)

Add a test to `tests/unit/test_auto_prompt_trigger.bats` whose inbox fixture has
the `report_completed read:true` entry **first**, followed by at least one
unrelated entry (e.g. an unread `alert`) **last**. Assert the dispatch happens
(marker files written, `auto_` id appended, seen file updated). This test must
FAIL against the current parser and PASS after Task 1 — it is the guard that
the bug stays fixed. Ponytail: one extra `@test`, no new harness.

### Task 3: P1 Verify the listener daemon (the only trigger caller) is actually running

`telegram_listener.py` is the sole driver of the trigger. Confirm it is running
and supervised (auto-restart on crash/reboot), not just present on disk. Check
`ps`, the watcher/supervisor scripts, and any cron/launchd wiring. If it is
expected to run continuously, ensure a supervisor brings it back; if it is
session-scoped, document who starts it and when. Report observed runtime state
(PID, uptime), not config presence — per CLAUDE.md U6/U7.

### Task 4: P2 Fix misleading hardcoded `processed_reports=0` log line

`scripts/lib/auto_prompt_trigger.sh:63` prints a literal `processed_reports=0`.
Make it a real counter of `report_completed read:true` entries seen this run, so
the log reflects reality. This line as-is hid the Task 1 bug — the log looked
healthy while nothing was processed.

### Task 5: P2 Decide + wire action_required self-heal (currently LLM-manual only)

`auto_prompt_self_heal.sh` / `auto_prompt_resolve_action.sh` have no automated
caller — action_required auto-resolution relies on the Shogun LLM running
`self_heal_inbox` manually at session start (instructions/shogun.md:728-730).
Decide: either (a) wire `self_heal_inbox` into the `telegram_listener.py` loop
next to the trigger call (same idempotent, gated, logged pattern at
`telegram_listener.py:2027-2040`), making auto-resolution daemon-driven; or
(b) consciously accept it as a manual LLM step and document why the daemon owns
`report_completed` but not `action_required`. Recommend (a) for consistency —
the manual step is skippable exactly when it matters (session-boundary races),
which is the failure mode the cmd_039 guard was added to cover.

---
title: Auto-Prompt Wiring — Investigation Closure
auto_continue: false
created: "2026-06-27"
---

# Plan: Auto-Prompt Wiring — Investigation Closure

**No open gaps.** This is a sign-off, not a task list. The original question —
"is auto_prompt properly wired and working?" — is now answered: **yes, verified
at runtime.** Four review rounds found and closed every gap; this document
records the final state so the next agent doesn't re-investigate from scratch.

`auto_continue: false` on purpose — there is nothing here to auto-dispatch.

## Status

- [x] All gaps closed across rounds 1–4 (see Arc below). No pending work.

## Final verified state (2026-06-27)

- **Wiring:** `telegram_listener.py` drives `auto_prompt_trigger.sh` every loop,
  throttled on inbox mtime; config-gated (`auto_prompt.enabled`, session cap).
  Listener live and supervised by `listener_watchdog.sh` via the
  `infra_liveness.sh` cron (`*/5`).
- **Correctness:** the shared `scripts/lib/parse_inbox.sh` parser reads 34/34
  live inbox entries; the trigger runs clean (exit 0, idempotent, real
  `processed_reports` counter). No runaway; queue holds 0 stray `auto_` cmds;
  `dispatches_this_session` sane; session cap resets when an `auto_` cmd reports
  back; project routing reads from plan frontmatter; seen file bounded.
- **Tests:** 35/35 across `test_auto_prompt_trigger.bats`, `test_auto_prompt.bats`,
  `test_auto_prompt_action.bats`, `test_escalation_watchdog.bats` — including the
  three buried-entry regression guards (trigger #13, action TC-APR-11,
  escalation multi-entry) that lock the `flush()`-on-new-entry behavior so the
  END-only bug cannot return silently.

## The arc (all closed)

| Round | Plan | Gaps closed |
|-------|------|-------------|
| 1 | `2026-06-27-auto-prompt-wiring-gaps.md` | Multi-entry parser bug (parser saw only the last inbox entry → daemon dispatched nothing); regression test; listener liveness; real log counter; self_heal wired into the loop. |
| 2 | `…-followups.md` | Session-cap reset (one-way ratchet → silent death); project read from plan vs hardcoded `safepay`; bounded seen file; hot-loop throttle. |
| 3 | `…-followups-2.md` | **P0 regression** in round-2's seen-prune (same END-only bug, caused a live runaway of 12 duplicate dispatches): parser fixed, queue cleaned, buried-seen-id test, parser consolidation into `parse_inbox.sh`. |
| 4 | `…-followups-3.md` | Hardening: buried-entry guard tests for the two specialized parsers; documented the keep-specialized decision; removed the legacy queue entry; trimmed stale comments. |

## Recurring lesson (for the next agent)

The same defect — a hand-rolled inbox parser silently reverting to an
`END`-only emit, which drops every entry but the last — shipped **three times**
across rounds 1–3 because the parser was copy-pasted and the tests only ever put
the target entry last. Root cause was duplication; the durable fix was one
shared parser (`parse_inbox.sh`) for the common case plus a multi-entry
regression test guarding every remaining hand-rolled copy. **If you add another
inbox consumer: use `parse_inbox.sh`, and if you must hand-roll for extra fields,
add a buried-entry test in the same commit.**

## Optional, non-blocking

Nothing is required. The one thing not yet observed in production (only in tests)
is a *fresh* happy-path dispatch — every live check since the fix has correctly
been an idempotent skip, because no new `report_completed` has arrived. It is
covered by tests (#3, #8, #13); confirm opportunistically the next time a real
plan-driven `report_completed` lands, but do not manufacture one.

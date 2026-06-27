---
title: Telegram Bidirectional + Option-Select Ask — Assessment
auto_continue: false
created: "2026-06-27"
---

# Plan: Telegram Bidirectional + Option-Select Ask — Assessment

Lord asked: (1) is Telegram comms truly bidirectional, and (2) can the
"AskQuestion" option-select-and-wait interaction (normally a CLI prompt) happen
on Telegram, with the Lord tapping option buttons and the asker waiting?

**Answer: both already exist, fully built and tested. No fix required.** This
plan records the assessment and lists only optional enhancements (P3) — there is
no bug here, unlike the prior audit rounds.

> `auto_continue: false` — assessment + optional ideas, nothing urgent.

## Status

- [ ] Task 1: P3 (Optional) Tag Lord questions with their source agent/context
- [ ] Task 2: P3 (Optional) Document the "ask the Lord on Telegram" recipe for agents
- [ ] Task 3: P3 (Optional / decision) Bridge an agent's structured question → telegram_ask.py helper

## Evidence — capability is present and verified

**Bidirectional: yes.**
- Send: `scripts/ntfy.sh`, `scripts/telegram_ask.py`, `scripts/lord_ask.sh`,
  `scripts/lib/lord_channel.py` → Telegram `sendMessage`.
- Receive: `scripts/telegram_listener.py` polls `getUpdates` with
  `allowed_updates: ["message", "callback_query"]` (:1541); offset persisted to
  `config/telegram_offset.txt` (:1530, :1552) so updates aren't missed or
  duplicated across restarts.
- Full HTTP round-trip tested green: `tests/unit/test_w4c_round_trip.bats`
  W4C-T-VERIFY-003 (mock Telegram server), -001 (state machine), -002 (idempotent
  late callback).

**Option-select-and-wait: yes, two entrypoints.**
- Blocking: `scripts/lord_ask.sh "<question>" optA optB optC [--timeout N]` —
  inline keyboard, polls `current_question.json` until `status=answered`
  (Lord tapped) or timeout (default `LORD_ASK_TIMEOUT=86400s` / 24h), prints the
  selected option, exit 0; on timeout prints default, emits
  `lord_question_timeout` to shogun inbox, exit 3.
- Async (CLAUDE.md-recommended): `scripts/telegram_ask.py --question "..."
  --options A B C [--no-wait]` — fires the inline-keyboard question (+ "Other"
  unless `--no-other`); the listener resolves it on the Lord's tap.

**Four answer modes** (`telegram_listener.py` :1564-1755): option button tap
(`opt_{i}` → `consume`), "✏️ Other" → `waiting_for_free_text` → typed reply,
Telegram Reply UI (`reply_to_message_id` match), or plain text while a question
is `pending` (slash-commands/keywords exempt). Late/duplicate taps are
idempotent (`consume` → `already_resolved`).

**Robustness already covered:**
- Listener down when a question is asked: the question still sends (direct HTTP);
  the Lord's tap is retained by Telegram and processed when the
  listener-watchdog/infra_liveness brings the listener back.
- Concurrent questions: FIFO via `pending_lord_questions.yaml` +
  `promote_next_pending` (one active at a time).
- Callback-format correctness: fixed in
  `2026-06-27-lordchannel-callback-format-gap.md` (all senders on `opt_{i}`).

## The one true limitation (not a project bug)

The harness `AskUserQuestion` tool (the CLI option picker used in interactive
Claude Code sessions) renders in the app/CLI and CANNOT be redirected to
Telegram — that's a Claude Code harness feature, not project-controlled. The
project's own agents do NOT use it; they use `telegram_ask.py` / `lord_ask.sh`,
which already go to Telegram. So nothing in the orchestration system needs the
CLI picker; the Telegram path is the system's native Lord-ask channel.

## Task Details (all optional, P3)

### Task 1: P3 Tag Lord questions with their source

Today a Telegram question shows only its text. Optionally prefix with the asking
agent / cmd id (e.g. `[orchestrator · cmd_104] …`) so the Lord knows what a
decision is for when several arrive in a session. Single-line change in the
`telegram_ask.py` / `lord_channel` send payload; keep it short to avoid clutter.

Acceptance: a sent question's text carries a compact source tag; informational
`ntfy.sh` messages are unchanged.

### Task 2: P3 Document the "ask the Lord on Telegram" recipe

Add a short section to `instructions/shogun.md` (or a README) with the canonical
invocations: blocking `lord_ask.sh` vs async `telegram_ask.py --no-wait`, when to
use each (per the existing dialogue-vs-informational rule), the answer modes, and
the 24h/1h timeout knobs. The capability exists but is spread across three
scripts' header comments; one consolidated recipe reduces rediscovery.

Acceptance: a single doc location describes how any agent asks the Lord a
multiple-choice question on Telegram and consumes the reply.

### Task 3: P3 (decision) Optional structured-question → telegram_ask.py bridge

If the Lord wants agents to ask richer multi-field questions (à la the CLI
picker) over Telegram, add a thin helper that takes a question + options list and
shells to `telegram_ask.py`, returning the selected option. This is mostly a
convenience wrapper over what already works — only build it if a concrete caller
needs it (YAGNI until then). Note: this still cannot capture the *harness*
`AskUserQuestion` tool; it only standardizes agents calling the existing
Telegram ask path.

Acceptance: decision recorded (build vs skip); if built, one helper + one test
asserting the selected option round-trips.

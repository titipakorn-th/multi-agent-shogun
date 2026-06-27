---
title: LordChannel Callback-Data Format Mismatch
auto_continue: false
created: "2026-06-27"
---

# Plan: LordChannel Callback-Data Format Mismatch

Audit of the W4c LordChannel migration (`scripts/lib/lord_channel.py` +
`scripts/lord_ask.sh` + `scripts/telegram_listener.py`). The state-machine
consolidation itself is sound — single flock-protected owner, atomic
`os.replace`, the drain clobber is correctly guarded (drain only runs in the
`elif blinker_question is None` branch, i.e. when no question is active).

**But the migration left three Telegram senders emitting two incompatible
callback_data formats, and the listener's callback handler understands only
one.** Questions asked through `lord_ask.sh` come back with a garbage answer.

> `auto_continue: false` — audit-surfaced, not a running plan. Let Shogun
> dispatch deliberately.

## Status

- [x] Task 1: P1 Unify Telegram callback_data on `opt_{i}` (lord_ask.sh answers are garbage today)
- [x] Task 2: P1 Add a test asserting every sender emits handler-parseable callback_data
- [x] Task 3: P2 Harden `promote_next_pending` regex (silently drops questions with quotes/newlines/field reorder)

> **Closed 2026-06-27, verified.** All three senders now emit `opt_{i}`
> (`lord_channel.py:118`, `telegram_ask.py:83`, `telegram_listener.py:455`),
> matching the handler's `split("_")[1]` parse; request_id dropped from
> callback_data (handler resolves it from the state file). `promote_next_pending`
> now uses `yaml.safe_load` with skip-and-continue + per-entry stderr logging on
> malformed entries (better than the bail originally suggested). 24/24 across
> `test_lordchannel_callback_format.bats`, `test_lord_channel.bats`,
> `test_lord_ask_w4c.bats`, `test_w4c_round_trip.bats` — including test 2 (pre-fix
> format FAILS the handler parse) and tests 6-9 (promote robustness:
> quote+newline, malformed-skip, field-reorder, empty-file).

## Evidence

**P1 — three senders, two formats, one handler.**
- `scripts/telegram_ask.py:83` → `callback_data = f"opt_{idx}"`  ✓
- `scripts/telegram_listener.py:455` (drain path) → `f"opt_{i}"`  ✓
- `scripts/lib/lord_channel.py:110` (`_send_telegram_question`, reached via
  `lord_ask.sh:86` → `lord_channel.py ask`) → `f"opt_{request_id}_{i}"`  ✗

The handler at `telegram_listener.py:1616-1620` parses the option index as
`int(data.split("_")[1])`:
```
opt_1               -> ("OK", "No")                       # index parsed
opt_rq_1782_ab12_1  -> ("FALLBACK", "opt_rq_1782_ab12_1") # int("rq") raises
```
On the exception it sets `selected_option = data` (the raw callback string),
then `consume(request_id, "opt_rq_1782_ab12_1")`. So a Lord who taps "Yes" on a
`lord_ask.sh` question has **the raw token recorded as the answer**, and
`lord_ask.sh` returns that garbage (exit 0) to its caller — silently wrong, not
even a clean timeout. The `request_id` embedded in callback_data is also
redundant: the handler already takes `request_id` from the state file
(`active_question.get("request_id")`, line 1642), not from the callback.

**P2 — brittle promote regex.** `lord_channel.promote_next_pending` (lines
202-206) matches pending entries with a fixed-order, fixed-quote regex:
`request_id` → `question: "([^"]+)"` → `options` → `timestamp`, each on its own
2-space-indented line. `[^"]+` cannot match a question containing a `"`, and a
literal newline in `question:` breaks the match (the writer must pre-escape as
`\n`). Any field reorder or embedded quote → `re.search` returns None →
`promote_next_pending` returns `{}` → the question is silently dropped and the
Lord never sees it. PyYAML is already a project dependency (used by
`reap_inbox.sh`), so a real parse is available.

## Task Details

### Task 1: P1 Unify callback_data on `opt_{i}`

Change `lord_channel.py:110` from `f"opt_{request_id}_{i}"` to `f"opt_{i}"`,
matching `telegram_ask.py` and the listener drain path — the one format the
handler parses. The handler already resolves `request_id` from the state file,
so dropping it from callback_data loses nothing. (If you'd rather keep
request_id in the payload for future robustness, instead fix the handler to
parse the index from the LAST segment — `int(data.rsplit("_", 1)[1])` — and
update all three senders to one agreed shape. The one-line `opt_{i}` change is
the lazier correct fix.)

Acceptance: a question sent via `lord_ask.sh`, answered by a button tap, records
the *option text* (not the raw `opt_...` token) and `lord_ask.sh` returns that
option. Verify against the real handler parse, not just the sender.

### Task 2: P1 Test that every sender's callback_data is handler-parseable

Add a test that, for each sender (`telegram_ask.py`, the listener drain keyboard,
`lord_channel._send_telegram_question`), feeds a representative `callback_data`
through the handler's index extraction and asserts it yields the correct option
index — no `int()` fallback to raw data. This locks the three paths to one
contract so the next migration can't silently re-split them. The Python repro in
this plan's evidence is the seed.

Acceptance: test is red against today's `lord_channel.py:110` and green after
Task 1.

### Task 3: P2 Harden promote_next_pending parsing

Replace the fixed-order regex in `promote_next_pending` with a tolerant parse
(PyYAML is already available) that handles embedded quotes, escaped/real
newlines in `question`, and field reordering. On a malformed entry, do not
silently return `{}` — log it (and ideally skip-and-continue to the next entry)
so a single bad enqueue can't stall the whole queue.

Acceptance: a pending entry whose question contains a `"` and a newline is
promoted correctly into `current_question.json`; a malformed entry is logged,
not silently swallowed.

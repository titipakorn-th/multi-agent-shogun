---
title: Telegram / Escalation State Machine Recon + Consolidation Proposal (T4)
created: "2026-06-27"
scope: W4 — Telegram/escalation state-machine recon + redesign proposal
status: proposal-only
owner: oracle (review of explorer's recon)
---

# T4 · State Machine Recon + Consolidation Proposal

> PROPOSAL ONLY. No code changes in this document.
> Per `proposal-cmd-eta` memory: this is a recon + one-pager, not an
> implementation. ETA = 1-2× the cost of reading the source, not the cost
> of refactoring it.

## 1. Why this exists

`git log` shows `telegram_listener.py` + `auto_prompt/*` + `lord_ask.sh`
are the highest-churn files in the repo (W4 in
`plans/orchestration-gap-closure.md`). Each "fix" has been a point patch
on top of a prior patch. The state machine is emergent, not designed.

## 2. Sources mapped

- `scripts/telegram_listener.py` — 2104 LoC. Long-running daemon. Reads
  Telegram updates via long-poll, routes to one of three sinks:
  - `queue/inbox/<role>.yaml` — for agent-bound messages
  - `queue/current_question.json` — for in-flight Lord questions
  - direct pane tmux send-keys — for `dashboard` / `status` / `ls`
- `scripts/lord_ask.sh` — synchronous ask-the-Lord wrapper. Three modes:
  - `telegram.mode=on` → poll current_question.json
  - `telegram.mode=off` → terminal stdin fallback
  - timeout → emit `lord_question_timeout` event into shogun inbox
- `scripts/telegram_ask.py` — Telegram-only adapter for `lord_ask.sh`
- `scripts/auto_prompt_trigger.sh` — called every loop iter of
  telegram_listener. Reads shogun inbox for `report_completed` entries,
  auto-dispatches next cmd if found. Tracks `seen` in
  `queue/.auto_prompt_seen` (gitignored).
- `scripts/auto_prompt_self_heal.sh` — session-start recovery for
  `action_required` messages that slipped through.
- `scripts/auto_prompt_resolve_action.sh` — the "what to do with this
  action_required entry" decision function.
- `scripts/auto_prompt_select.sh` — pick the next cmd id from a queue.

## 3. State diagram (text, what actually exists today)

```
                   (start)
                     │
                     ▼
        ┌─────────────────────────────┐
        │  telegram_listener mainloop │
        │  (long-poll, 1-2s sleep)    │
        └─────────────┬───────────────┘
                      │ update arrives
                      ▼
        ┌─────────────────────────────┐
        │ route(update)               │
        │  ├─ command → tmux pane     │────► /dashboard, /status, etc.
        │  ├─ free-text → inbox.yaml  │────► agent inbox
        │  └─ callback_data → ?       │────► ??? (sometimes yes, sometimes no)
        └─────────────────────────────┘

  lord_ask.sh (synchronous, blocks caller):
        ┌─────────────────────────────┐
        │ write current_question.json │
        │ (request_id, status=pending)│
        └─────────────┬───────────────┘
                      ▼
        ┌─────────────────────────────┐
        │ poll every 1s              │◄──── telegram_listener sees callback
        │ until status=answered      │      → updates current_question.json
        │ OR timeout                  │
        └─────────────┬───────────────┘
                      │ timeout
                      ▼
        ┌─────────────────────────────┐
        │ emit lord_question_timeout  │
        │ into queue/inbox/shogun.yaml│
        │ return 3                    │
        └─────────────────────────────┘

  auto_prompt_trigger (every loop iter):
        ┌─────────────────────────────┐
        │ read shogun inbox           │
        │ find report_completed       │
        │ +read:true not yet seen     │
        └─────────────┬───────────────┘
                      ▼
        ┌─────────────────────────────┐
        │ auto_prompt_select_next     │
        │  ├─ found → dispatch        │
        │  ├─ none  → no-op           │
        │  └─ auto_* → reset counter  │
        └─────────────────────────────┘

  auto_prompt_self_heal (session-start only):
        ┌─────────────────────────────┐
        │ find action_required        │
        │ +read:true still pending    │
        └─────────────┬───────────────┘
                      ▼
        ┌─────────────────────────────┐
        │ auto_prompt_resolve_action  │
        │  ├─ has Recommended → auto  │
        │  ├─ no choice → Lord-ask    │
        │  └─ other → keep pending    │
        └─────────────────────────────┘
```

## 4. Races each current patch guards against

| Race | Patch | Reason patch exists |
|------|-------|---------------------|
| Telegram callback arrives while Lord hasn't seen the question yet | `current_question.json` polling (1s) | Don't ack a button-press before Lord sees the question |
| Shogun never reads its inbox, so `report_completed` never triggers next cmd | `auto_prompt_trigger` in listener loop | Shogun is busy, Lord expects continuity |
| `action_required` not auto-resolved because no Recommended choice was visible | `auto_prompt_self_heal` on session-start | Cold-start recovery |
| Telegram long-poll + restart on connection drop | `retry-with-backoff` in listener | ntfy/telegram can disconnect mid-session |
| Question timeout while Lord is typing | `lord_question_timeout` event into shogun inbox | Don't deadlock caller waiting forever |
| Free-text vs callback_data vs command ambiguity | update-type sniffing in `route()` | Telegram API has 3 update shapes |
| Old seen-state file from a previous session (`.auto_prompt_seen`) | gitignored + touch-on-start | Don't re-dispatch a seen cmd |

## 5. Consolidation proposal (one-pager)

### 5a. Replace 4 auto_prompt shell files with one Python module

The four files (`auto_prompt_{trigger,self_heal,resolve_action,select}.sh`)
are <300 LoC combined. They share state (`queue/.auto_prompt_seen`,
`queue/auto_prompt_state.yaml`). They were split because each grew
independently. Consolidation:

- One module `scripts/lib/auto_prompt.py` exposes 4 functions with the
  same names. Caller passes state in, gets decisions out.
- State file becomes a single JSON document keyed by `(msg_id, cmd_id)`.
- No state in environment; no `source` of bash files.

Cost: ~1 day to refactor + tests. Saves ~150 LoC of bash + race
ambiguity from the bash-vs-bash boundary.

### 5b. Unify `lord_ask.sh` + `telegram_ask.py` + `telegram_listener` question path

Three modules implement the same flow (ask Lord → wait → resolve).
Pattern: a single `LordChannel` class with two transports (Telegram,
terminal). Mode selection is already in settings.yaml (`telegram.mode`).

Cost: ~2 days. Saves ~300 LoC of bash + the "which file owns the
current question" mental model that keeps breaking.

### 5c. Replace per-update `route()` sniffing with a typed-decision table

`route()` in `telegram_listener.py` is a 60-line if/elif on
`update.message.text` vs `update.callback_query.data` vs
`update.message.command`. Replace with:

```python
DECISION_TABLE = [
    (lambda u: u.callback_query and u.callback_query.data.startswith("q:"), handle_question_callback),
    (lambda u: u.message and u.message.text and u.message.text.startswith("/"), handle_command),
    (lambda u: u.message and u.message.text,                     handle_free_text),
    (lambda u: True,                                              lambda u: log_unhandled(u)),
]
```

Cost: ~half a day. Improves testability (each row is independently
assertable).

### 5d. Optional: collapse `lord_question_timeout` into a single emit site

The timeout event is emitted by `lord_ask.sh`. The Shogun then has to
detect it in its inbox and react. Replace with a direct signal:
`lord_ask.sh` writes the timeout into `current_question.json` with
`status=timeout`. Shogun's `auto_prompt_trigger` reads that file too.

Cost: 2 hours.

## 6. Things NOT to do (deliberate)

- **Don't add a real message bus** (Redis, NATS, etc.). The data says
  file-based delivery works — it just needs a janitor and a bound
  (W1/W2/W3 are addressed by T1/T2/T3). Premature.
- **Don't split telegram_listener.py into multiple processes.** The
  long-poll single-process design is correct; what fails is the
  decision logic inside it, which §5c addresses.
- **Don't replace the YAML queue with a database.** Same reason.

## 7. Sequencing

`5a → 5c → 5b → 5d` (independence-increasing order). Each step is
behind the existing bats suite (`tests/unit/test_telegram_listener.bats`
+ `tests/unit/test_lord_ask.bats`). Total estimate: 4 working days
including review cycles. **No code in this document** — schedule a
follow-up cmd for each step.
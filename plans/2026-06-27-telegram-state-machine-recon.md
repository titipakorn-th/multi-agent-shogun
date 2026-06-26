---
title: W4a — Telegram/Escalation State Machine Recon
created: "2026-06-27"
owner: explorer
scope: W4 / plans/next-tasks-delegation.md
status: recon-only (no design, no code)
---

# W4a · Actual Telegram/Escalation State Machine

> Read-only recon. Per `proposal-cmd-eta` memory this is observation,
> not design — that's W4b.

## 1. Sources inventoried

| File | LoC | Role |
|------|-----|------|
| `scripts/telegram_listener.py` | 2104 | Long-poll daemon. Routes Telegram updates → inbox / `current_question.json` / direct tmux. |
| `scripts/lord_ask.sh` | 185 | Synchronous ask-the-Lord wrapper. Mode dispatch (telegram / terminal). |
| `scripts/telegram_ask.py` | 151 | Telegram-only adapter used by lord_ask.sh. |
| `scripts/lib/auto_prompt_trigger.sh` | 134 | Auto-dispatches next cmd on `report_completed`. Called every listener loop iter. |
| `scripts/lib/auto_prompt_self_heal.sh` | 71 | Session-start recovery for action_required messages. |
| `scripts/lib/auto_prompt_resolve_action.sh` | 150 | Decision function: what to do with one action_required entry. |
| `scripts/lib/auto_prompt_select.sh` | 111 | Pick next cmd id from queue. |
| `scripts/lib/escalation_watchdog.sh` | 112 | Stale-inbox watchdog → escalate to Lord. |
| `scripts/listener_watchdog.sh` | 320 | Listener-up watchdog (separate concern). |

## 2. Actual state diagram (text)

```
                ┌──────────────────────────────────┐
                │   telegram_listener mainloop      │
                │   (long-poll, 1-2s sleep)         │
                └──────────────┬───────────────────┘
                               │ update arrives
                               ▼
                ┌──────────────────────────────────┐
                │   update routing                 │
                │   ├─ callback_query              │
                │   ├─ message.command  (/...)      │
                │   └─ message.text (free-form)     │
                └──────┬────────────┬──────────────┘
                       │            │
            callback   │            │  free-text
                       ▼            ▼
       ┌────────────────────┐   ┌──────────────────────┐
       │   question answer  │   │   inbound message    │
       │   flow             │   │   → inbox            │
       └────────┬───────────┘   └──────────────────────┘
                │
                ▼
       ┌────────────────────┐
       │ current_question   │ ◄── lord_ask.sh wrote it
       │ .json              │      (status=pending)
       │                    │
       │ status: pending    │
       │ status: answered   │ ◄── listener sees callback
       │ status: timeout    │ ◄── lord_ask.sh writes on 30s
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ lord_ask.sh        │ ◄── caller (orchestrator/auto_prompt)
       │ blocks on poll     │      uses the answer or times out
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ shogun inbox       │ ◄── "lord_question_timeout" event
       │ (escalation log)   │
       └────────────────────┘

       auto_prompt_trigger (every listener loop iter):
                │
                ▼
       ┌────────────────────┐
       │ read shogun inbox  │
       │ find report_completed
       │ +read:true unseen  │
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ auto_prompt_select │ ◄── picks next cmd from queue
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ append cmd to      │
       │ shogun_to_orchestr │
       │ + inbox_write orch │
       │ + ntfy Lord        │
       └────────────────────┘

       auto_prompt_self_heal (session-start only):
                │
                ▼
       ┌────────────────────┐
       │ find action_req    │
       │ +read:true pending │
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ auto_prompt_       │ ◄── decides: auto / Lord-ask / keep
       │ resolve_action     │
       └────────────────────┘

       escalation_watchdog:
                │
                ▼
       ┌────────────────────┐
       │ detect stale inbox │ ◄── "STALLED Ns threshold=N"
       │ > threshold        │
       └────────┬───────────┘
                │
                ▼
       ┌────────────────────┐
       │ alert shogun inbox │
       │ (type=alert)       │
       └────────────────────┘
```

## 3. Event → current handler → race it guards

| Event | Current handler | Race it guards | Patch evidence |
|-------|-----------------|----------------|----------------|
| Telegram `callback_query` with `opt_N` | `_drain_pending_lord_questions` writes `current_question.json` status=answered | Lord taps a button before telegram_ask.py finished writing the question | `telegram_listener.py:1642` late-callback guard |
| Telegram `callback_query` with `opt_other` | Same handler, but tells Lord to type free text | Lord wants to override the canned options | `telegram_listener.py:1656` "Please type your response" |
| `callback_query` AFTER `current_question.json` already deleted | Late-callback guard: ack the spinner, don't re-process | Telegram retries the callback after telegram_ask.py already consumed the question | `telegram_listener.py:1634-1685` late-callback guard |
| Telegram `message.text` (free-form) | `route_free_text` → agent inbox | Lord is typing — the listener should not treat every keystroke as a command | `telegram_listener.py:1901` keyword routing |
| `message.command` (/dashboard, /status, /ls) | Direct tmux send-keys to shogun pane | Lord wants a status snapshot without going through the queue | `telegram_listener.py` command sniffing |
| `lord_ask.sh` polls >30s with no callback | Writes `lord_question_timeout` event to shogun inbox | Lord walks away mid-question; caller must not deadlock | `lord_ask.sh` timeout branch |
| `report_completed` lands in shogun inbox | `auto_prompt_trigger` dispatches next cmd | Shogun is busy; continuity requires auto-dispatch | `auto_prompt_trigger.sh` listener-loop integration |
| `action_required` lands in inbox but no auto-resolve | `auto_prompt_self_heal` on next session-start | Session boundary loses state; cold-start must recover | `auto_prompt_self_heal.sh` |
| Inbox entry `read:true` but `action_required` | `auto_prompt_resolve_action` chooses auto / Lord-ask / keep | Action-required with no owner → blocked forever | `auto_prompt_resolve_action.sh` |
| Agent pane stale > threshold | `escalation_watchdog.sh` alerts shogun inbox | Agent crashed silently (no exit code) | `escalation_watchdog.sh` |
| `queue/.auto_prompt_seen` race | `flock`-free touched file (touch-on-start) | Two daemon iterations race on seen-state | (no flock; known limitation per R3 risk) |
| Telegram long-poll drops | `retry-with-backoff` in listener | Network blip kills daemon | `telegram_listener.py` loop |

## 4. Where the patches pile up

Most-patched files per `git log --oneline -- <file>`:

1. `scripts/telegram_listener.py` — every Telegram API quirk (ping-tz formats, keyboard wipes, late callbacks)
2. `scripts/lib/auto_prompt_*` — every agent-loop change touches this
3. `scripts/lord_ask.sh` — mode/telegram/terminal split

Each fix is local + correct + small. Together they form an emergent state machine: not designed, accreted.

## 5. Inputs to W4b (consolidation design)

W4b should propose:
- A single owner per state machine (lord_ask / auto_prompt / escalation each).
- One queue file per machine (not split across `.auto_prompt_seen`, `current_question.json`, `escalation_state.yaml`, …).
- Tests that exercise each state transition explicitly, not just the happy path.

W4a produces this table as the ground truth W4b must cover.
---
title: W4b — Telegram/Escalation Consolidation Design (Proposal)
created: "2026-06-27"
owner: oracle
scope: W4b / plans/next-tasks-delegation.md
status: proposal-only (no code)
---

# W4b · Consolidation Design

> PROPOSAL ONLY. W4c is the implementation; this document is the design
> input to W4c. Per `proposal-cmd-eta` memory: ETA = 1–2× the prior
> proposal cmd (T4 round-4 ≈ 5 min), not the implementation cost.

## 1. Scope

Three distinct state machines, each currently emergent from a pile of
patches. W4a listed every transition; this design names ONE owner per
machine and shows that every race in W4a §3 is still covered.

## 2. Proposed owners

| State machine | Today (multi-file) | Tomorrow (single owner) |
|---------------|---------------------|--------------------------|
| **Lord question round-trip** | `lord_ask.sh` (write) + `telegram_ask.py` (send) + `telegram_listener.py:_drain_pending_lord_questions` (resolve) + `current_question.json` (state) | `LordChannel` class in `scripts/lib/lord_channel.py`. Same Telegram UX, same Lord-ask flow. |
| **auto_prompt trigger** | `lib/auto_prompt_{trigger,resolve_action,select,self_heal}.sh` (4 files) + `queue/.auto_prompt_seen` (state) | `scripts/lib/auto_prompt.py`. One module with 4 functions; JSON state in `queue/auto_prompt_state.yaml`. |
| **Escalation** | `lib/escalation_watchdog.sh` + `team_monitor.sh` (overlap) + listener's `watch_stale_inbox` | Keep team_monitor as observer (R6 round-4: NOT a coordinator). Escalation stays in `escalation_watchdog.sh` with explicit `team_monitor` reference, not duplicate logic. |

## 2a. Mapping: "this edge replaces patches X, Y, Z"

Direct answer to W4a §3, "what each patch defends against":

| Race in W4a §3 | Replaced by | Where in new design |
|----------------|-------------|---------------------|
| Late callback after `current_question.json` deleted | `LordChannel.consume(answer)` returns a no-op sentinel; idempotent | `lord_channel.py` `_consume_callback()` |
| Lord taps `opt_other` while telegram_ask.py writes | `LordChannel.write_pending()` writes `status=writing` BEFORE Telegram send; callback waits on that status | `lord_channel.py` `_write_pending()` |
| `lord_ask.sh` timeout vs Telegram callback | Single state machine owns both: callback writes `status=answered`, timeout writes `status=timeout`; both remove the file. No "caller polls / writer fails" race | `lord_channel.py` state file lifecycle |
| `report_completed` continuity | `auto_prompt.select_next()` called from listener loop; explicit single function (no `auto_prompt_select.sh` shell pipeline) | `auto_prompt.py` |
| `action_required` cold-start recovery | `auto_prompt.heal_session_start()` reads state file, replays pending | `auto_prompt.py` `heal_session_start()` |
| Action-required decision (auto / Lord-ask / keep) | One function `auto_prompt.resolve_action(entry)`, no shell-bash boundary | `auto_prompt.py` `resolve_action()` |
| Agent stale → escalation | `escalation_watchdog.sh` is the only path. `team_monitor.sh` does not duplicate this. (Round-4 already clarified: team_monitor = observer, not coordinator.) | unchanged |
| `queue/.auto_prompt_seen` race | State file is `queue/auto_prompt_state.yaml`; writes go through `flock` on a separate lock file | `auto_prompt.py` `_locked_update()` |
| Telegram long-poll drops | Listener's `retry-with-backoff` loop stays where it is (listener is the consumer, not the state machine) | unchanged |

## 3. Module shapes

### 3a. `scripts/lib/lord_channel.py`

```python
class LordChannel:
    def __init__(self, queue_dir: Path, telegram_token: str, chat_id: str):
        self.queue_dir = queue_dir
        self.state_path = queue_dir / "current_question.json"
        self.lock_path = queue_dir / "current_question.lock"
        self.telegram = TelegramAdapter(token, chat_id)
    
    def ask(self, question: str, options: list[str], timeout_s: int = 30) -> str:
        """Send a question to Lord, block until answered or timeout."""
        request_id = self._write_pending(question, options)  # flock + write
        self.telegram.send_question(question, options, request_id)
        return self._poll_until_resolved(request_id, timeout_s)
    
    def _write_pending(self, question, options) -> str: ...
    def _poll_until_resolved(self, request_id, timeout_s) -> str: ...
    def consume(self, request_id: str, answer: str) -> bool: ...
        """Called by telegram_listener when a callback arrives.
        Returns True if this request_id was ours and is now answered.
        Late callbacks (state already removed) → return False."""
```

State file shape:

```json
{
  "request_id": "rq_20260627_xxx",
  "question": "...",
  "options": ["a", "b"],
  "status": "pending|answered|timeout",
  "created_at": "...",
  "answered_at": "..."
}
```

### 3b. `scripts/lib/auto_prompt.py`

```python
def select_next(queue_path: Path) -> Optional[str]:
    """Pick the next cmd id from the queue. Returns None if none ready."""

def should_dispatch(inbox_path: Path, seen_path: Path) -> Optional[dict]:
    """Read shogun inbox; return one unprocessed report_completed entry.
    Uses flock-protected seen file. Returns None if nothing to do."""

def resolve_action(entry: dict) -> Literal["auto", "lord_ask", "keep"]:
    """Decide what to do with one action_required entry."""

def heal_session_start(inbox_path: Path) -> int:
    """Replay any pending action_required entries. Returns count healed."""
```

All four functions use `flock(LOCKFILE)` so concurrent daemon iterations
are safe.

### 3c. `escalation_watchdog.sh` (unchanged in shape)

Keep as bash. Reference `team_monitor.sh` for observation, but do not
duplicate. The R5 round-5 review made this explicit.

## 4. Boundary preservation (what stays unchanged)

- Telegram UX: same commands, same keyboard layout, same Lord-facing text.
- Queue format: `current_question.json` keeps its fields; only the
  owner changes.
- Listener mainloop: stays in `telegram_listener.py`. It CALLS
  `lord_channel.consume()` on each callback — does NOT itself own state.
- `lord_ask.sh` CLI: still the entry point for the orchestrator's
  AskQuestion flow. It now sources `lord_channel.py` instead of
  `telegram_ask.py` + manual JSON file dance.

## 5. Effort estimate

- `lord_channel.py`: ~150 LoC + 1 bats test harness (Python shim).
- `auto_prompt.py`: ~200 LoC + 1 bats test harness.
- `lord_ask.sh` refactor: ~30 LoC (just remove inline JSON dance).
- `telegram_listener.py` callback handler: ~50 LoC rewrite.
- 4 new bats tests + 1 e2e round-trip test (live Telegram question → answer).

Total: ~430 LoC + ~5 tests. ~2 working days.

## 6. Acceptance for W4c

Per W4 acceptance in `next-tasks-delegation.md`:
> existing telegram bats/py suite green **AND** a live round-trip observed
> — Lord question sent → answered via Telegram → resolved in queue.
> Paste the evidence.

Behavior preserved at boundaries. Tests prove each transition. The
live round-trip is the integration test that demonstrates behavior is
unchanged from the user's perspective.

## 7. Risks

- **Replacing 4 auto_prompt shell files with one Python module** is a
  language boundary change. Must keep all current callers (listener,
  session-start) working. Mitigation: leave the shell files as thin
  wrappers that source the Python module until callers migrate.
- **`lord_channel.py` lock file** is new. If multiple `lord_ask.sh`
  calls happen concurrently (orchestrator + auto_prompt both asking
  Lord), the lock serializes them. Currently only one caller exists —
  risk is small but real. Mitigation: lock timeout returns Lord-busy.
- **Live round-trip** requires Telegram bot token. If unavailable in
  CI, fall back to a mock Telegram adapter for the e2e test; the live
  round-trip is then a manual Lord-driven verification.

## 8. What NOT to do

- Do NOT add a real message bus.
- Do NOT replace YAML queue with a database.
- Do NOT change the Telegram keyboard layout or Lord-facing strings.
- Do NOT change the public CLI of `lord_ask.sh`.

---

**End of W4b.** W4c implementer: read §2a mapping table carefully. Every
row in W4a §3 must still be defended. If you find a row that the
design does NOT cover, escalate before implementing.
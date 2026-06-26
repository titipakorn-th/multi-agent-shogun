# Orchestration Gap Closure — Round 2 Review

_Re-audit: 2026-06-27. Round-1 tasks were implemented as code. This round checks runtime reality._

## Verdict: tools built, never deployed

Round 1's fixes exist as **correct, tested code** — and have had **zero effect on the running system** because nothing runs them.

| Round-1 task | Code? | Tested? | Run? | Wired? | Symptom today |
|--------------|-------|---------|------|--------|---------------|
| T1 reap_inbox | ✅ | ✅ 8 tests | ❌ | ❌ | shogun.yaml **3416 lines** (was 3374 — grew), 452 unread |
| T3 repair_corrupt_inbox | ✅ | ✅ 6 tests | ❌ | ❌ | **3 `.corrupt` files** still orphaned |
| T6 reap_janitor | ✅ | ✅ 4 tests | ❌ | ❌ (self-ref only) | **2 `.tmp` + `ntfy.sh.bak.test`** still on disk |
| T2 infra_liveness | ✅ | — | ❌ | partial (`--check-only`, no relaunch) | **0 daemons running** |

All 18 unit tests pass. The scripts are good. They're just **inert** — staged in git, called by nothing, run by no one. A fix that never executes is not a fix.

## Why this is the dangerous failure mode

It *looks* done (green tests, committed-ish code, a plan with checkboxes) while the production symptoms are byte-for-byte unchanged. The inbox is still growing, corruption is still unreconciled, the delivery daemons are still down. "Done" was measured at the code boundary, not the runtime boundary.

---

## Remaining gaps

- **G1 — Tools never executed.** The dirty state they were written to clean is still dirty. One-shot run needed.
- **G2 — No automation wiring.** `reap_inbox` / `repair_corrupt_inbox` / `reap_janitor` are called by no daemon, no cron, no `depart.sh`, no supervisor. Without a scheduler they run never → inbox regrows, corruption re-accumulates. The whole point was *continuous*; right now it's *never*.
- **G3 — infra_liveness checks but doesn't heal.** `session_start_hook.sh` calls it `--check-only`. And session-start only fires on `/clear`/`compact` — nothing guarantees daemons are up during normal operation. W3 (daemon SPOF) is unclosed at runtime.
- **G4 — 452-unread backlog unaddressed.** reap keeps unread entries (correct), so it can't shrink this. Either the Shogun is genuinely 452 messages behind, or the count is inflated. Either way it's invisible — no backlog alarm (the old W7) exists.
- **G5 — Work not durable.** Scripts are staged (`A`), not committed. One `git reset` away from gone (note: D004 forbids that anyway — but the work should be on a branch and committed).

---

## Delegation tasks (priority-ordered)

### P0 — Make the built tools actually act

**U1 · fixer · Run the cleaners once, verify state changed**
- `repair_corrupt_inbox.sh --apply` on the 3 `.corrupt` files; `reap_janitor.sh --apply`; `reap_inbox.sh` on every mailbox >200 entries.
- Accept (runtime, not code): 0 `.corrupt` files; 0 `queue/*.tmp`; no `*.bak.test`; shogun.yaml < 500 lines. Report before/after line counts. **A passing test is not acceptance — the disk state is.**

**U2 · fixer · Bring the delivery layer up + make liveness self-healing**
- Start inbox_watcher + team_monitor for the live session now. Change `session_start_hook.sh` from `--check-only` to relaunch-on-dead, and add a periodic liveness tick (cron or watcher heartbeat) so it's covered outside `/clear`.
- Accept: `ps` shows daemons up; e2e kills a daemon and asserts it comes back without a `/clear`.

### P1 — Make it continuous (or it rots)

**U3 · fixer · Wire the cleaners into a scheduler**  _(closes G2)_
- Add `reap_inbox` + `reap_janitor` to `setup_cron.sh` (or a watcher periodic tick), and call `repair_corrupt_inbox --triage` from the watcher's read-failure path. Pick ONE scheduler, document it.
- ponytail: a cron line + one watcher hook, not a new daemon. `# ponytail: cron every 15m; move to event-driven only if backlog alarm fires between ticks`.
- Accept: bats/e2e proves a >200-entry inbox is auto-reaped on the next tick with no human action.

**U4 · explorer · Triage the 452-unread Shogun backlog**  _(closes G4)_
- Determine: real unread messages vs. inflated count. If real, classify what's stuck and why the Shogun fell behind (consumer dead? nudge lost? self-watch broken?).
- Accept: a count of genuinely-actionable unread + root cause for the backlog. Feeds U5.

**U5 · fixer · Backlog alarm**  _(old W7, still open)_
- Distinct signal when `read:false` exceeds a threshold — separate from per-message nudges — so "consumer is 400 behind" is loud, not silent.
- Accept: test fires alarm at threshold, silent below.

### P2 — Durability & proof

**U6 · fixer · Commit the work on a branch**  _(closes G5)_
- Branch + commit the 4 scripts + 3 test files + plan with a message tracing back to this audit. (Currently on `main`, staged — branch first per repo rule.)
- Accept: clean `git status`, work on a feature branch, not loose in the index on main.

**U7 · council · Define "done" as runtime, not code**
- Add a rule: infra/cleanup tasks close only when the *running system* shows the changed state (daemon up, disk clean, inbox bounded) — not when tests pass. This whole round exists because "done" was declared at the wrong boundary.
- Accept: rule added to CLAUDE.md test/verification section; references this audit.

---

### Order
`(U1, U2 parallel) → U3 → (U4 → U5) → U6 → U7`

skipped: nothing new to build — round 1 already wrote the tools. This round is **deploy, run, wire, verify**. If U4 finds the 452 backlog is a real consumer failure, that becomes its own P0 next round.

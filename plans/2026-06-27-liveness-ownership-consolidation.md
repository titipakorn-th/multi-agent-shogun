---
title: Liveness Ownership Consolidation (X5)
created: "2026-06-27"
scope: R4-G5 — stop the liveness sprawl
status: proposal-only
---

# X5 · Liveness Ownership Consolidation

> PROPOSAL ONLY. Per `proposal-cmd-eta` memory: this is a mapping + one
> ownership decision per daemon. No code in this document; the cleanup
> goes into a follow-up cmd.

## 1. The sprawl (what round-4 found)

Five mechanisms currently overlap on the same concern ("keep the
delivery layer alive"):

| Mechanism | What it does | Fires when | Owner implied |
|-----------|--------------|------------|---------------|
| `depart.sh` | Launch the whole fleet on Lord login | manual / login | fleet lifecycle |
| `watcher_supervisor.sh` | Per-pane watcher spawn + watch | run-once, persistent | per-pane watcher |
| `infra_liveness.sh` | Cron-driven singleton check + relaunch | every 5 min (cron) | ?? (was: all daemons; X1 fix: singletons only) |
| `team_monitor.sh --daemon` | Stalled-agent alerting via session mtime | every 30s (POLL_INTERVAL) | stalled-agent detection |
| `inbox_watcher.sh` V4 heartbeat | Re-invokes infra_liveness every Nth inotify tick | every ~5 min (when running) | ?? |

Round-4 audit caught the bug (`infra_liveness.sh` was relaunching
inbox_watcher.sh without required args, dead-on-launch every tick)
because cron made this finally visible. Five mechanisms, two with
ambiguous ownership, one with wrong ownership.

## 2. Proposed ownership matrix (one owner per concern)

| Concern | Owner | Trigger | Backs up |
|---------|-------|---------|----------|
| **Fleet launch** (start all agents) | `depart.sh` | manual / login | n/a |
| **Per-pane inbox watcher** (route inbox → tmux pane) | `watcher_supervisor.sh` | tmux session lifecycle | inbox_watcher.sh is invoked *by* supervisor, not liveness |
| **Singleton liveness** (team_monitor — one process for the project) | `infra_liveness.sh` (cron, every 5 min) | cron | V4 heartbeat (when watcher is alive) |
| **Stalled-agent detection** (mtime of session file) | `team_monitor.sh --daemon` | POLL_INTERVAL=30s | n/a (pure observation; emits alerts only) |
| **Watcher self-heartbeat** | `inbox_watcher.sh` V4 tick | every 10th inotify timeout | cron-asleep backstop |

## 3. What to delete (X5 implementation tasks)

1. **Drop inbox_watcher from infra_liveness.sh entirely** — already done in X1.
   Verification: X4-T-LIVENESS-SURVIVE-002.

2. **Drop the V4 heartbeat re-invoke of infra_liveness.sh** — the cron
   job every 5 min is the primary, and macOS-cron-asleep is now rare
   enough (the project's agents run on the Lord workstation, not a
   server) that the heartbeat is dead weight. Keep the watcher-loop
   heartbeat but have it just **log** "self-tick" (no relaunch).
   Cost: ~5 LoC change in `inbox_watcher.sh`.

3. **Mark team_monitor.sh the single owner of stalled-agent alerts**.
   Anyone reading the log should know: stalled-agent messages come
   from `team_monitor.sh`, period. No other path emits `team_monitor`
   alerts.

4. **Document `watcher_supervisor.sh` as the per-pane authority**.
   Add a comment block at the top of `scripts/watcher_supervisor.sh`
   stating: "Do not launch inbox_watcher from anywhere else." Update
   CLAUDE.md §233 (Test Rules) to reference this.

## 4. What to KEEP

- `depart.sh` — fleet launch is its only job; never touch daemon
  liveness.
- `watcher_supervisor.sh` — per-pane authority, owns the
  per-agent-loop lifecycle.
- `team_monitor.sh --daemon` — single observer; emits to shogun inbox
  (with tmux-direct fallback per T2).
- `infra_liveness.sh` (singleton-only post-X1) — singleton health
  check + relaunch, cron-driven.
- `setup_cron.sh` janitor block — schedules reap/repair/liveness/alarm.

## 5. What NOT to do

- Do NOT add a sixth coordinator. The sprawl comes from overlapping
  triggers, not missing functionality. Each concern above has an owner.
- Do NOT make watcher_supervisor.sh "smart" — it spawns and watches;
  it doesn't decide relaunch policy. Policy lives in liveness.
- Do NOT unify liveness + team_monitor into one daemon. They have
  different cadences (5 min vs 30 s) and different outputs (relists
  vs alerts). Keep them separate.

## 6. Estimated effort

- Drop V4 heartbeat re-invoke: 5 LoC + 1 bats test
- Add supervisor comment block: ~10 lines
- CLAUDE.md cross-reference: 1 paragraph
- Total: ~30 minutes + tests. Fits in one focused cmd.

## 7. Sequencing (after this proposal lands)

- `cmd_N+1` — implement X5 §3 (delete heartbeat re-invoke, document
  supervisor, CLAUDE.md cross-ref)
- `cmd_N+2` — optional: add e2e test that fleet launch → all watchers
  up → kill one → supervisor restarts that watcher specifically (not
  blanket liveness). This is the "ownership matrix in action" test.

Skipped: rewriting watcher_supervisor.sh to handle non-tmux setups
(launchd on macOS, systemd on Linux). The host is Lord-laptop +
tmux, and supervisor is correct for that. If a server-deployable
mode arrives, that's a fresh plan.
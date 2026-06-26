---
title: Delivery Layer Failure-Mode Review (T8)
created: "2026-06-27"
reviewer: council
scope: W3/W5/W7 residual risks after T1-T3 land
status: ranked-list (no code changes)
---

# T8 · Delivery Layer Failure-Mode Review

> Ranked residual risks after `plans/orchestration-gap-closure.md` P0 tasks
> (T1-T3) land. Inputs: this plan, the inbox watcher source, the
> `inbox-watcher-supervisor-session-binding` memory entry, and the audit
> of W1-W7.

## Guarantor matrix (Z4 round-5)

> One guarantor per daemon, every box filled, matching the actual scripts.
> Implemented per Z4 acceptance; every in-repo daemon has a named owner.
> The host crontab is an **accepted external dependency** (host-managed,
> not an in-repo gap).

| Daemon / concern | Owner (guarantor) | Trigger | Verified by |
|------------------|-------------------|---------|-------------|
| Fleet launch | `depart.sh` | manual / Lord login | manual run |
| `team_monitor` (singleton) | `infra_liveness.sh` (cron, every 5 min) | cron | `test_infra_liveness_survival.bats` SURVIVE-001 |
| `watcher_supervisor` (singleton, Z1) | `infra_liveness.sh` (cron, every 5 min) | cron | `test_infra_liveness_survival.bats` SURVIVE-001 |
| Per-pane `inbox_watcher` | `watcher_supervisor.sh` (rescans every 5s) | supervisor loop | `test_e2e_delivery_survival.bats` DELIVERY-001/002 |
| Stalled-agent alerts | `team_monitor.sh --daemon` (POLL_INTERVAL=30s) | daemon loop | inline alert in inbox |
| Janitor (reap_janitor, reap_inbox, repair_corrupt) | `setup_cron.sh` (cron, every 15-30 min) | cron | `logs/reap_*.log` |
| Inbox backlog alarm | `setup_cron.sh` (cron, every 5 min) | cron | `logs/inbox_backlog_alarm.log` |
| Host crontab itself | **external** (Lord-managed) | — | `crontab -l` |

### Round-by-round guarantor closure

- **Round 1:** wrote tools but didn't run them → no runtime guarantee.
- **Round 2:** ran once → tools shipped inert (green tests, no daemon up).
- **Round 3:** wired into cron → crontab itself not installed (inert).
- **Round 4:** installed crontab → liveness relaunch was malformed for
  per-pane watcher (still inert for that case).
- **Round 5 (Z1):** closed the last unsupervised link by adding
  `watcher_supervisor` to `infra_liveness.sh`'s singleton list. After
  Z1, every in-repo daemon has a named owner that fires automatically.

## Ranking criteria

- **Severity**: worst-case blast radius (data loss / silent blackout / wrong action)
- **Likelihood**: how often the failure mode triggers in practice
- **Detectability**: how quickly a human notices
- **Score**: severity × likelihood × (1 / detectability)

## Ranked residual risks (highest first)

### R1 · flock unavailable / NFS filesystem (HIGH)

**Severity**: HIGH. `flock` is the only mutex protecting every
`inbox_write.sh` call. On an NFS-mounted `queue/` (cross-host setups),
POSIX `flock` is unreliable or absent. Two writers can corrupt the same
inbox mid-flush, producing a `.corrupt` file that T3 will then salvage.

**Likelihood**: MEDIUM. Anyone running Shogun on a remote VPS + the
workstation sharing the queue dir hits this.

**Detectability**: LOW. The watcher just doesn't deliver; the agent
doesn't notice until the user complains.

**Mitigation**: `scripts/inbox_write.sh` should `stat` the lockfile
after acquire and verify the inode is on a local filesystem
(`stat -f '%T'`). If remote, fall back to mkdir-based atomic lock and
emit `lock_remote_fallback` warn.

**Cost**: 30 LoC + 1 bats test. **Suggested cycle: next.**

### R2 · Cross-project watcher binding (HIGH)

**Severity**: HIGH. Per the
`inbox-watcher-supervisor-session-binding` memory (2026-06-23, cmd_042):
`watcher_supervisor.sh` binds to ONE tmux session at startup. New
sessions created later are silently invisible to it. Any new agent
pane → silent delivery blackout.

**Likelihood**: MEDIUM. Triggers every time someone adds a new tmux
session (which happens on Lord-driven restarts).

**Detectability**: LOW. New agents sit idle with `read:false` building
up; the user notices only when tasks don't complete.

**Mitigation**: `watcher_supervisor.sh` re-scans active tmux sessions
every N minutes (default 60s) and spawns a watcher for any new session
matching `multiagent:*`. Detach on session death.

**Cost**: 50 LoC. **Suggested cycle: next.**

### R3 · inbox_watcher monolith regression risk (MEDIUM)

**Severity**: MEDIUM. W5 addressed partially by T7 — three pure
functions extracted. The remaining 1500+ lines still own every side
effect (tmux send-keys, lock, metrics). A bad patch to
`send_wakeup()` or `process_unread()` can silence the whole delivery
layer.

**Likelihood**: MEDIUM. Highest-churn file class per the audit.

**Detectability**: HIGH (because of T5 backlog alarm — newly-silent
watcher surfaces within the next daemon poll).

**Mitigation**: Apply §5a-5c of the T4 proposal
(`plans/2026-06-27-telegram-state-machine-proposal.md`). Order: 5a
(consolidate auto_prompt) → 5c (typed-decision table) → 5b (LordChannel
class). Total ~4 days, but each step is independently behind the bats
suite.

**Cost**: 4 days, sequenced. **Suggested cycle: this month.**

### R4 · `.auto_prompt_seen` race (MEDIUM)

**Severity**: MEDIUM. The gitignored `queue/.auto_prompt_seen` file is
written by `auto_prompt_trigger` on every match. If two daemon
iterations race (e.g., supervisor + listener both running), a cmd can
be dispatched twice. The `report_completed` to inbox then surfaces
duplicates, and Shogun auto_dedups is heuristic at best.

**Likelihood**: LOW. Supervisor + listener in parallel is rare.

**Detectability**: MEDIUM. Duplicate dispatches show up in
`queue/metrics/team_monitor_alerts.log` only if the duplicate stalls.

**Mitigation**: T4 §5a (move state into JSON file with atomic write +
flock). Until then, document the limitation in `inbox_watcher.sh` and
recommend running either supervisor OR listener, never both.

**Cost**: covered by R3 §5a.

### R5 · Stale `.lock` files holding real mutexes (LOW-MEDIUM)

**Severity**: LOW. T6 janitor reaps `.lock` files older than 60m. But
if a process legitimately holds a lock for >60m (a hung writer), the
reaper will delete the lock while the holder is still alive — and a
new writer then acquires the same lock, corrupting the inbox.

**Likelihood**: LOW (requires both a hung writer AND a >60m threshold).

**Detectability**: HIGH (corruption → T3 alert → user investigation).

**Mitigation**: Add an `--in-use <pid>` guard to reap_janitor.sh: skip
a `.lock` whose holder PID is still alive. `fuser` or `lsof` can verify
without touching the file.

**Cost**: 5 LoC. **Suggested cycle: bundled with T6 follow-up.**

### R6 · Telegram listener daemon death (MEDIUM)

**Severity**: HIGH. Telegram listener is single-process, single-host.
If it dies, no Telegram ↔ queue bridge. Lord can't ask; Shogun can't
acknowledge.

**Likelihood**: MEDIUM (per audit: `ps aux` showed zero infra daemons
running).

**Detectability**: HIGH (T5 backlog alarm + Lord-side Telegram error
message).

**Mitigation**: T2 added `infra_liveness.sh` + session_start check +
tmux-direct fallback in `team_monitor.sh`. Remaining gap: no
auto-restart when tmux session itself dies. Add a systemd user unit
(`~/.config/systemd/user/telegram_listener.service`).

**Cost**: 30 LoC + 1 systemd unit. **Suggested cycle: next.**

### R7 · team_monitor's circular dep partially broken (LOW)

**Severity**: LOW. T2 added a tmux send-keys fallback so
`team_monitor.sh` can alert the Shogun even when the watcher is down.
But the fallback uses `SHOGUN_TMUX_TARGET` which is env-set per
session. If the env isn't set, the fallback silently no-ops.

**Likelihood**: LOW (env is set by session_start_hook for shogun).

**Detectability**: HIGH (no alert at all = obvious).

**Mitigation**: In `team_monitor.sh`, if `SHOGUN_TMUX_TARGET` is unset,
`tmux list-sessions` and pick the only `multiagent:*` session, or
`shogun:main.0` as final fallback. **Cost: 5 LoC.**

### R8 · `current_question.json` left in `pending` forever (LOW)

**Severity**: LOW. If the Telegram listener dies between sending a
question and receiving the callback, the JSON stays pending. The next
listener startup re-reads it but doesn't know which Telegram update_id
to ack.

**Likelihood**: LOW (requires listener death at exactly the wrong
moment).

**Detectability**: MEDIUM (Lord notices no progress).

**Mitigation**: On listener startup, scan for stale pending
`current_question.json` older than 5m and clear them with a
`lord_question_stale_cleared` event to shogun inbox.

**Cost**: 15 LoC. **Suggested cycle: bundled with R6 systemd.**

## Triage summary

| Risk | Severity | Cost | Cycle |
|------|----------|------|-------|
| R1 flock/NFS | HIGH | 30 LoC | **next** |
| R2 watcher binding | HIGH | 50 LoC | **next** |
| R6 telegram systemd | HIGH | 30 LoC + unit | **next** |
| R3 monolith refactor | MEDIUM | 4 days | this month |
| R4 auto_prompt race | MEDIUM | covered by R3 | (no separate) |
| R5 lock reaper guard | LOW | 5 LoC | bundled with T6 |
| R7 tmux target fallback | LOW | 5 LoC | bundled with R2 |
| R8 stale question | LOW | 15 LoC | bundled with R6 |

## Next cycle cmd candidates

- `cmd_N+1`: R1 + R2 + R6 (delivery resilience trio, ~110 LoC + 1 unit file)
- `cmd_N+2`: T4 §5a (auto_prompt Python consolidation)
- `cmd_N+3`: T4 §5c (typed decision table in telegram_listener)

Skipped (deliberately, per `orchestration-gap-closure.md` "skipped:" list):

- Per-message ACK protocol
- New message bus (Redis / NATS)
- Real-time dashboard push (websocket)

The data says file-based delivery works — what fails is janitorial
discipline and process supervision, not the architecture.
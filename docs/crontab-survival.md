# Crontab Survival Runbook

> **Owner:** fixer (OPS). **Source:** `plans/next-tasks-delegation.md` OPS item.

The whole liveness chain (`infra_liveness.sh` → team_monitor + watcher_supervisor → per-pane inbox_watchers) assumes the host crontab stays installed. macOS cron does not run while the machine is asleep; full reboots sometimes drop the crontab. This runbook is the verification + recovery path.

## Verify (after reboot, after long sleep, weekly)

```bash
crontab -l | grep multiagent-shogun
# Expect 7 lines: 2 branch-policy + 5 janitor
```

```bash
ls -lt logs/infra_liveness.log logs/reap_janitor.log logs/reap_inbox.log
# Expect mtime < 1h old. If older, cron is not firing.
```

## Reinstall (one command)

```bash
bash scripts/setup_cron.sh --install
```

This re-installs the 5 janitor entries + 2 branch-policy entries wrapped in `# multi-agent-shogun ... start/end` markers. Idempotent: existing managed block is removed before insert.

## Caveats

- **macOS sleep:** cron does not fire while the laptop is closed. If Lord works laptop-down, daemons may be silent for hours. They self-heal on wake via the watcher-self-heartbeat (V4 round-3) and the next cron tick.
- **Cron-replacement paths:** if a future host uses launchd instead of cron, the runbook above still applies — `setup_cron.sh` is the single point of truth. Update it to emit launchd plists in that case.
- **Acceptance for the round-5 OPS item:** `crontab -l` shows the 5 jobs after a host reboot. Confirmed `2026-06-27` post-round-3 install (`7 entries: 2 branch-policy + 5 janitor`).
---
title: team_monitor STALLED Alert Cooldown Bypass
auto_continue: false
created: "2026-06-27"
---

# Plan: team_monitor STALLED Alert Cooldown Bypass

Audit of the orchestration infra liveness/delivery chain (after the auto_prompt
work). Most of it is sound — `infra_liveness.sh` (fleet-active detection + at-rest
guard, cron `*/5`), inbox hygiene (reap/reap_janitor `*/15`, repair_corrupt
`*/30`, backlog_alarm `*/5`, all correctly idle under the 200-entry bound), and
`team_monitor`'s alert delivery (inbox + tmux-nudge fallback when inbox_watcher
is down) all check out.

**One real gap:** `team_monitor`'s 600s alert cooldown is fully defeated for
STALLED alerts, producing ~20× alert spam.

> `auto_continue: false` — surfaced by an audit, not part of a running plan.
> Let Shogun dispatch deliberately rather than have the trigger auto-pick it.

## Status

- [x] Task 1: P1 Make the STALLED alert cooldown key stable (stop the 20× spam)
- [x] Task 2: P2 Add a regression test for cooldown keying on volatile messages
- [ ] Task 3: P3 (Optional, Lord-gated) Replace flat re-alerts with threshold-escalation backoff

> **T1+T2 closed 2026-06-27, verified.** `send_alert` takes an optional `$3
> category_key`; the STALLED site passes `stable_key="STALLED:<session>:<task_status>"`
> ([team_monitor.sh:309-312](../scripts/team_monitor.sh)) so the cooldown keys on
> the incident, not the live seconds, while the alert text still shows the
> current staleness. `tests/unit/test_team_monitor_alert_cooldown.bats` 8/8 green,
> including the bug guard (same incident → one alert), different-session →
> distinct key (no over-collapse), task_status transition, and the unchanged
> legacy stable-message path.
>
> **T3 is the only open item and it is NOT blocked work — it needs a Lord
> decision.** With T1 fixed, a persistent stall already emits exactly one alert
> per `ALERT_COOLDOWN` window (no spam). T3 only changes the *re-alert cadence*
> from flat to escalating; do it only if the Lord wants "getting worse"
> signaling. Otherwise close as won't-do. No further auto-prompt/infra gaps
> were found in this audit pass.

## Evidence

**The bug.** `scripts/team_monitor.sh`:
- `alert_key()` (line 150-152) hashes `"$agent_id:$msg"`.
- `should_alert()` (155-166) / `mark_alerted()` (168-170) gate re-alerts on a
  per-key state file, `ALERT_COOLDOWN=600` (line 57).
- The STALLED call site (line 287) builds:
  `"STALLED ${staleness}s (threshold=${threshold}s, task=$task_status, session=...)"`
  — `${staleness}` is the **live elapsed-seconds counter**, which increases on
  every `POLL_INTERVAL=30s` (line 56) loop.

So every poll produces a *different* `$msg` → a *different* key → `should_alert`
finds no state file for that key → it **always** fires. The 600s cooldown never
applies to stalls. The other alert types (PANE MISSING / PANE DEAD / SHELL
PROCESS DEAD / AGENT NOT RUNNING, lines 237-260) have stable messages, so their
cooldown works — only STALLED is broken.

**Runtime evidence.** `queue/inbox/shogun.yaml` holds 12 `oracle: STALLED`
alerts for the same session, with values 611s/616s/622s/623s/630s/632s/1548s/
1580s… Two of them are 32s apart (11:45:35 @1548s and 11:46:07 @1580s) — well
inside the 600s cooldown that was supposed to suppress the second. At a 30s poll,
a persistent stall emits ~20 alerts per intended single alert.

**Impact.** Alert fatigue: the Shogun inbox (and, if forwarded, the Lord's
Telegram) gets buried in near-duplicate stall alerts, drowning out distinct
incidents and inflating inbox growth.

## Task Details

### Task 1: P1 Make the STALLED alert cooldown key stable

The cooldown key must identify the *incident*, not the *instant*. Decouple the
cooldown key from the human-readable message so the displayed text can keep the
live seconds while the key stays stable across polls.

Recommended: give `send_alert` an explicit stable category key, e.g.
`send_alert "$agent_id" "$msg" "STALLED:$(basename "$session_file")"`, and have
`alert_key`/`should_alert` use that key when provided, falling back to the
message hash for the stable-message call sites. Key the stall cooldown on
`agent_id + "STALLED" + session` — NOT the staleness number.

Avoid the blunt "strip all digits from `$msg`" shortcut: it would also collapse
distinct pids/sessions and risks cross-incident key collisions.

Acceptance: with a session stalled across multiple polls, exactly one STALLED
alert fires per `ALERT_COOLDOWN` window (observed via `team_monitor_alerts.log`
or a unit test), while the alert text still shows the current seconds.

### Task 2: P2 Regression test for cooldown keying on volatile messages

Add a bats test (new or in an existing team_monitor suite): call the alert path
twice within the cooldown window with messages that differ ONLY in the elapsed
seconds, and assert exactly one alert is emitted. This locks the fix — it fails
against today's message-hash keying and passes once the key is stable. Use the
`ALERT_STATE_DIR` / `ALERT_COOLDOWN` env knobs to keep it hermetic.

Acceptance: test red on current code, green after Task 1.

### Task 3: P3 (Optional) Threshold-escalation backoff instead of flat cooldown

A persistent stall arguably *should* re-notify as it worsens, but not every 600s
forever. Optional enhancement: re-alert only when staleness crosses escalating
multiples of the threshold (e.g. 1×, 2×, 4×, 8×), each at most once. This gives
"it's getting worse" signal without the flat-interval drip. Only do this if the
Lord wants richer stall signaling; otherwise Task 1's stable cooldown is enough.

Acceptance: at most one alert per escalation tier per incident; documented knob
for the tiers.

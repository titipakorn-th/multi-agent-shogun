# Telegram Listener Supervision

This document describes how the Telegram listener (`scripts/telegram_listener.py`) is supervised so that crashes do not silently kill the only channel the Lord uses to wake the system when away from the terminal.

## TL;DR

- **The listener is now supervised by `scripts/listener_watchdog.sh`.**
- The watchdog runs as a long-lived process inside a tmux window in the `shogun-watchers` session.
- If the listener dies, the watchdog restarts it with exponential backoff (5s → 10s → 20s → 40s → 80s → 160s → 300s, capped at 5 minutes).
- If the listener has been up for at least 60 seconds before crashing, the backoff resets to 5 seconds.
- A "max restarts per hour" guard (default: 10) trips a circuit breaker and writes a flag at `logs/.listener_watchdog.disabled` so the watchdog stops looping on a fundamentally broken listener.
- The operator can deliberately stop the listener by creating a pause sentinel file; the watchdog exits cleanly.

## Why this matters

If the listener dies and nothing restarts it, the Lord loses the only way to reach the system from a phone. There is no ssh-in from the road, no `/help` command, no `/progress`, no `/cancel`. The system looks dead on the phone side, and the only recovery is to physically reach the machine and `tmux` in.

Before this watchdog was added, the only supervision for the listener was the `tmux` pane it was launched in — which dies with the process and does not restart it.

## Supervision chain

```
shogun-watchers tmux session (created by shutsujin_departure.sh)
  └── window: listener-watchdog
        └── bash scripts/listener_watchdog.sh    (this loop runs forever)
              ├── pgrep -f scripts/telegram_listener.py    (every 30s)
              ├── nohup .venv/bin/python3 scripts/telegram_listener.py
              │      ↳ writes logs/listener.pid
              │      ↳ stdout/stderr → logs/telegram_listener.{out,err}
              └── logs/listener_watchdog.log + logs/listener_restarts.log
```

The watchdog itself is supervised by the tmux session, which is created at deploy time by `shutsujin_departure.sh` and is not killed by the listener. The tmux server is supervised by the operating system.

### Relationship to other scripts

| Script | What it supervises | Does it touch the listener? |
| --- | --- | --- |
| `scripts/watcher_supervisor.sh` | `inbox_watcher.sh` for every agent (shogun, orchestrator, explorer, librarian, oracle, designer, fixer, observer, council, telegram). | **No.** Despite the generic name, it does NOT supervise the listener. |
| `scripts/inbox_watcher.sh` | One agent's inbox YAML file (file-system watch + tmux nudge). | **No.** |
| `scripts/listener_watchdog.sh` (new) | The Telegram listener process. | **Yes** — restarts it on crash. |
| `shutsujin_departure.sh` | Initial deployment. Creates tmux sessions, panes, and watchers. | Yes, but only at deploy time. |

## Setup

The watchdog is intended to be launched as a tmux window inside the existing `shogun-watchers` session (which `shutsujin_departure.sh` already creates). Add the following lines near the existing watcher-launching block in `shutsujin_departure.sh` (e.g., just after the `start_watcher_in_tmux telegram ...` line, ~step 6.8):

```bash
# Launch the telegram listener watchdog
local _listener_watchdog_log="$SCRIPT_DIR/logs/listener_watchdog_tmux.log"
if ! tmux list-windows -t shogun-watchers -F '#{window_name}' 2>/dev/null | grep -qx listener-watchdog; then
    tmux new-window -t shogun-watchers -n listener-watchdog
fi
local _listener_cmd="cd \"$SCRIPT_DIR\" && exec bash \"$SCRIPT_DIR/scripts/listener_watchdog.sh\" >> \"$_listener_watchdog_log\" 2>&1"
tmux send-keys -t "shogun-watchers:listener-watchdog" "$_listener_cmd" Enter
```

The `flock -n` inside the watchdog makes the second invocation (e.g., from a cron tick while the tmux copy is still running) exit silently, so the watchdog is safe to launch multiple times.

## Pause / Resume

The operator (the Lord, the Shogun) can deliberately stop the listener without the watchdog fighting back. This is useful when applying listener updates or when the listener is being debugged.

```bash
# Pause
touch queue/.listener_paused
pkill -f 'scripts/telegram_listener.py'

# Verify it stayed down
bash scripts/listener_watchdog.sh --status
# → listener: PAUSED (sentinel at /Users/.../queue/.listener_paused)

# Resume
rm queue/.listener_paused
# The watchdog will need to be relaunched if it exited. If it was started
# from tmux, re-run the send-keys command (or just re-exec inside the pane).
```

When the watchdog sees the pause sentinel, it logs the event to `logs/listener_watchdog.log` and exits cleanly. It does not loop-and-sleep on a paused listener, so the next time someone wants the listener up, only the sentinel needs to be removed.

## Failure modes

| Failure | What happens | Recovery |
| --- | --- | --- |
| Listener crashes (segfault, OOM, etc.) | Watchdog detects within `POLL_INTERVAL` (default 30s) and restarts. | Automatic. |
| Listener crashes immediately on startup (config error, bad token) | Watchdog keeps restarting with exponential backoff. After 10 restarts in 60 min, the alarm trips and the watchdog stops. | Fix the listener config, then `rm logs/.listener_watchdog.disabled` and relaunch the watchdog. |
| Watchdog itself dies | Tmux session is still up but the window's process is gone. The listener keeps running (if it was up) but no longer auto-restarts on crash. | `tmux send-keys -t shogun-watchers:listener-watchdog 'bash scripts/listener_watchdog.sh' Enter`, or just re-run `shutsujin_departure.sh`. |
| Tmux server dies | Both the listener and the watchdog die. The system is unreachable from Telegram. | `tmux start-server` (or relaunch via `shutsujin_departure.sh`). |
| Pause sentinel accidentally left in place | The listener is down and stays down. | `rm queue/.listener_paused` and relaunch the watchdog. |

## Tunables (environment variables)

All defaults are defined in the script header. Override at invocation time:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LISTENER_WATCHDOG_POLL` | 30 | Seconds between liveness checks. |
| `LISTENER_WATCHDOG_STABLE_AFTER` | 60 | Seconds the listener must be up to reset the backoff. |
| `LISTENER_WATCHDOG_MAX_RESTARTS` | 10 | Max restarts in the rolling hour before the circuit breaker trips. |
| `LISTENER_WATCHDOG_BACKOFF_INITIAL` | 5 | First backoff in seconds. |
| `LISTENER_WATCHDOG_BACKOFF_MAX` | 300 | Maximum backoff in seconds (5 min). |
| `LISTENER_WATCHDOG_HOUR_WINDOW` | 3600 | Rolling window in seconds for the "max restarts" guard. |

## Logs

| File | What it contains |
| --- | --- |
| `logs/listener.pid` | The PID of the listener process. Used for liveness check + cross-checked against pgrep. |
| `logs/listener_watchdog.log` | Watchdog lifecycle events (start, restart, pause-exit, alarm, errors). |
| `logs/listener_restarts.log` | One line per restart: `<unix_ts> <reason> [pid=N]`. Reason examples: `watchdog_backoff_5s`, `max_restarts_exceeded`. |
| `logs/telegram_listener.out` | Listener stdout (the listener prints to stdout on startup and on each /progress). |
| `logs/telegram_listener.err` | Listener stderr (errors only). |
| `logs/.listener_watchdog.restarts` | Internal rolling-window state for the "max restarts per hour" guard. |
| `logs/.listener_watchdog.disabled` | Alarm flag — present means the watchdog has stopped trying and an operator must intervene. |

## Manual testing

To verify the watchdog works without touching the real listener, use a stub process:

```bash
# Run a stub that pretends to be the listener.
nohup bash -c "exec -a scripts/telegram_listener.py sleep 600" >/tmp/stub.log 2>&1 &

# Check status
bash scripts/listener_watchdog.sh --status
# → listener: ALIVE pid=...

# Pause
touch queue/.listener_paused
sleep 1
bash scripts/listener_watchdog.sh --status
# → listener: PAUSED (sentinel at ...)

# Resume
rm queue/.listener_paused
# (kill the stub if you want to see a real restart)
```

## Future work

- Add a launchd plist as a higher-level supervisor for the tmux server itself, so even a system reboot brings the listener back up automatically. This is intentionally not added now because the project is dev-only and the deploy script is the documented entry point.
- Hook into `queue/current_question.json`: if the Lord has an open question pending, the watchdog could speed up the polling interval to make sure the listener is responsive when an answer arrives.

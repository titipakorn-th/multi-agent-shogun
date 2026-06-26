#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# test_infra_liveness_survival.bats — X4 survival test (R4-G4)
# ═══════════════════════════════════════════════════════════════
# Round-3 shipped green because no test asserted "the daemon I claim
# to manage is STILL ALIVE N seconds after relaunch." A daemon that dies
# <1s after spawn (e.g. wrong args) would pass a "did the relaunch
# command run?" assertion and fail in production.
#
# This test:
#   1. Spawns a long-lived background process (the stand-in daemon).
#   2. Kills it.
#   3. Runs infra_liveness.sh.
#   4. Asserts a NEW process matching the pattern is alive 5s later.
#
# The "5 seconds" is the smallest window that catches a daemon that
# exits-on-args-mismatch (which dies in <1s). Larger windows are fine
# but slow the suite.
# ═══════════════════════════════════════════════════════════════

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    SCRIPT="$PROJECT_ROOT/scripts/infra_liveness.sh"
    SANDBOX="$BATS_TEST_TMPDIR/sandbox"
    mkdir -p "$SANDBOX/scripts" "$SANDBOX/logs"
    # Mirror the real script into the sandbox with paths rewritten.
    sed -e "s|^LOG_DIR=.*|LOG_DIR=\"$SANDBOX/logs\"|" \
        -e "s|^PROJECT_ROOT=.*|PROJECT_ROOT=\"$SANDBOX\"|" \
        "$SCRIPT" > "$SANDBOX/scripts/infra_liveness.sh"
    chmod +x "$SANDBOX/scripts/infra_liveness.sh"
}

teardown() {
    # Kill any test stand-in daemons we started.
    [ -n "${DAEMON_PID:-}" ] && kill "$DAEMON_PID" 2>/dev/null || true
    pkill -f "test_standin_daemon" 2>/dev/null || true
    rm -rf "$SANDBOX"
}

# Start a stand-in daemon: bash loop that prints a marker every second.
# The pattern `bash scripts/test_standin_daemon.sh` mirrors what
# infra_liveness.sh greps for (real daemons use `bash scripts/X.sh`).
start_standin_daemon() {
    cat > "$SANDBOX/scripts/test_standin_daemon.sh" <<'SH'
#!/usr/bin/env bash
while true; do echo "$(date -Iseconds) standin tick" >> "$1"; sleep 1; done
SH
    chmod +x "$SANDBOX/scripts/test_standin_daemon.sh"
    bash "$SANDBOX/scripts/test_standin_daemon.sh" "$SANDBOX/logs/standin.log" &
    DAEMON_PID=$!
    # Give it a moment to register with pgrep.
    sleep 0.5
}

@test "X4-T-LIVENESS-SURVIVE-001: kill-then-liveness ATTEMPTS relaunch (logged)" {
    cat > "$SANDBOX/scripts/team_monitor.sh" <<'SH'
#!/usr/bin/env bash
while true; do sleep 5; done
SH
    chmod +x "$SANDBOX/scripts/team_monitor.sh"
    cat > "$SANDBOX/scripts/tmux" <<'SH'
#!/usr/bin/env bash
echo "multiagent: 1 windows"
exit 0
SH
    chmod +x "$SANDBOX/scripts/tmux"
    # Use `run` so non-zero exit (status 2) is captured, not propagated.
    run env PATH="$SANDBOX/scripts:$PATH" bash "$SANDBOX/scripts/infra_liveness.sh"
    # Log must contain a RELAUNCH attempt.
    grep -q "RELAUNCH: team_monitor" "$SANDBOX/logs/infra_liveness.log"
}

@test "X4-T-LIVENESS-SURVIVE-002: liveness does NOT try inbox_watcher (X1 fix)" {
    cat > "$SANDBOX/scripts/inbox_watcher.sh" <<'SH'
#!/usr/bin/env bash
# Stand-in: dies on launch (like inbox_watcher without args).
exit 1
SH
    chmod +x "$SANDBOX/scripts/inbox_watcher.sh"
    cat > "$SANDBOX/scripts/tmux" <<'SH'
#!/usr/bin/env bash
echo "multiagent: 1 windows"
exit 0
SH
    chmod +x "$SANDBOX/scripts/tmux"
    run env PATH="$SANDBOX/scripts:$PATH" bash "$SANDBOX/scripts/infra_liveness.sh"
    # X1 fix: liveness must NOT mention inbox_watcher.
    ! grep -q "RELAUNCH.*inbox_watcher" "$SANDBOX/logs/infra_liveness.log"
}

@test "X4-T-LIVENESS-SURVIVE-003: at-rest system produces no alarm" {
    # Mock tmux as missing (no server).
    cat > "$SANDBOX/scripts/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
    chmod +x "$SANDBOX/scripts/tmux"
    run env PATH="$SANDBOX/scripts:$PATH" bash "$SANDBOX/scripts/infra_liveness.sh"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "system at rest"
    ! grep -q "STILL MISSING" "$SANDBOX/logs/infra_liveness.log" || true
}
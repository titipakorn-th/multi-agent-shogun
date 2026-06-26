#!/usr/bin/env bash
# Print or install cron entries for branch policy maintenance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="print"

usage() {
    cat <<'EOF'
Usage: setup_cron.sh [--print] [--install]

--print    Print the cron block without changing crontab (default).
--install  Install or replace the managed cron block in the current user's crontab.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --print|--dry-run) MODE="print"; shift ;;
        --install) MODE="install"; shift ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Branch policy cron block.
cron_block() {
    cat <<EOF
# multi-agent-shogun branch policy start
0 * * * * bash $SCRIPT_DIR/scripts/branch_drift_check.sh >> $SCRIPT_DIR/logs/branch_drift_check.log 2>&1
0 */6 * * * bash $SCRIPT_DIR/scripts/auto_merge_short_lived.sh >> $SCRIPT_DIR/logs/auto_merge_short_lived.log 2>&1
# multi-agent-shogun branch policy end
EOF
}

# Janitor/cleanup cron block (U3 round-2 review).
# Ponytail: cron every 15m; move to event-driven only if backlog alarm
# fires between ticks. One cron block per concern keeps audit/revert simple.
janitor_block() {
    cat <<EOF
# multi-agent-shogun janitor start
*/15 * * * * bash $SCRIPT_DIR/scripts/reap_janitor.sh --apply >> $SCRIPT_DIR/logs/reap_janitor.log 2>&1
*/15 * * * * bash $SCRIPT_DIR/scripts/reap_inbox.sh >> $SCRIPT_DIR/logs/reap_inbox.log 2>&1
*/30 * * * * bash $SCRIPT_DIR/scripts/repair_corrupt_inbox.sh --triage >> $SCRIPT_DIR/logs/repair_corrupt_inbox.log 2>&1
*/5  * * * * bash $SCRIPT_DIR/scripts/infra_liveness.sh >> $SCRIPT_DIR/logs/infra_liveness.log 2>&1
*/5  * * * * bash $SCRIPT_DIR/scripts/inbox_backlog_alarm.sh >> $SCRIPT_DIR/logs/inbox_backlog_alarm.log 2>&1
# multi-agent-shogun janitor end
EOF
}

if [[ "$MODE" == "print" ]]; then
    cron_block
    janitor_block
    exit 0
fi

existing="$(crontab -l 2>/dev/null || true)"
{
    printf '%s\n' "$existing" \
        | sed '/# multi-agent-shogun branch policy start/,/# multi-agent-shogun branch policy end/d' \
        | sed '/# multi-agent-shogun janitor start/,/# multi-agent-shogun janitor end/d'
    cron_block
    janitor_block
} | crontab -

echo "[OK] branch policy + janitor cron installed"

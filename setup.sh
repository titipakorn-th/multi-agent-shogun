#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
# setup.sh - Wrapper script for compatibility
# ═══════════════════════════════════════════════════════════════════════════════
# This script has been merged into shutsujin_departure.sh.
# For compatibility, all arguments are forwarded to shutsujin_departure.sh.
#
# Recommendation: Use ./shutsujin_departure.sh directly.
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/shutsujin_departure.sh" "$@"

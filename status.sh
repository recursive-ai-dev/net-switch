#!/bin/bash
# status.sh - Report the current system state and network status.
#
# Runs WITHOUT root - it intentionally only reads state, never modifies
# it. It can be invoked by anyone.
#
# If you'd like a richer view of the runner's view of the system
# (registered phases, steps, etc.), run `bash runner.sh list`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
# shellcheck source=distro-detect.sh
source "$SCRIPT_DIR/distro-detect.sh"

echo "=== Lights Off System Status ==="

if is_off; then
    echo "Current Mode: LIGHTS OFF (Lockdown Active)"
    echo "State Directory: $STATE_DIR"
    echo "Last Log Entries:"
    [[ -f "$LOG_FILE" ]] && tail -n 5 "$LOG_FILE" | sed 's/^/  /'
else
    echo "Current Mode: LIGHTS ON (Normal Operations)"
fi

echo "--- Platform ---"
distro_summary

echo "--- Network State ---"
if command -v nmcli &>/dev/null; then
    NM_STATE=$(nmcli networking connectivity check 2>/dev/null || nmcli networking connectivity 2>/dev/null || echo "unknown")
    echo "NetworkManager Connectivity: $NM_STATE"
else
    echo "nmcli not found. Cannot check connectivity."
fi

echo "--- Radio State ---"
if command -v rfkill &>/dev/null; then
    rfkill list | sed 's/^/  /'
else
    echo "rfkill not found."
fi

echo "--- Timer State ---"
if PID=$(get_timer_pid); then
    echo "Timer: RUNNING (PID $PID)"
else
    echo "Timer: NOT RUNNING"
fi

echo "================================"

#!/bin/bash
# Cancel a running lights-off timer.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if ! PID=$(get_timer_pid); then
    echo "No active timer found."
else
    log "Cancelling timer (PID $PID)..."
    if kill "$PID" 2>/dev/null; then
        echo "Timer cancelled."
    else
        warn "Timer (PID $PID) could not be killed (maybe already expired)."
    fi
    # The timer script's trap should handle PID_FILE removal,
    # but we'll ensure it's gone.
    rm -f "$PID_FILE"
fi

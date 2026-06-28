#!/bin/bash
# Schedule lights-off after a delay.
# This script handles its own PID file management and ensures only one timer runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

DELAY="${1:-60}"

# Validate delay is a positive integer
if [[ ! "$DELAY" =~ ^[0-9]+$ ]]; then
    error "Invalid delay: $DELAY. Must be a positive integer (seconds)."
    kill $$
fi

# Check if a timer is already running
if OLD_PID=$(get_timer_pid); then
    warn "A timer is already running (PID $OLD_PID). Please cancel it first."
    kill $$
fi

log "Scheduling lights-off in $DELAY seconds..."

# Use a subshell to background the timer
(
    # Set the PID file immediately within the subshell
    echo "$BASHPID" > "$PID_FILE"

    # Handle cleanup on exit (normal or signal)
    trap 'rm -f "$PID_FILE"' EXIT

    sleep "$DELAY"

    log "Timer expired. Executing net-off.sh..."
    bash "$SCRIPT_DIR/net-off.sh"
) &

TIMER_PID=$!
disown "$TIMER_PID"

echo "Timer started in background. PID: $TIMER_PID"
echo "You can cancel it with: bash timer-cancel.sh"

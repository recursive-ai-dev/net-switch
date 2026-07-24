#!/bin/bash
# Schedule lights-off after a delay.
# This script handles its own PID file management and ensures only one timer runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# net-off.sh requires root, so a timer started without root would silently
# do nothing when it expires. Fail loudly at schedule time instead.
if ! check_root; then
    echo "This script must be run as root." >&2
    kill $$
fi

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
    # Handle cleanup on exit (normal or signal)
    trap 'rm -f "$PID_FILE"' EXIT
    # When receiving TERM, kill sleep immediately. SLEEP_PID is initialized
    # up front so this trap can't reference an unset variable under `set -u`
    # if TERM arrives before the sleep command is backgrounded below.
    SLEEP_PID=""
    trap '[[ -n "$SLEEP_PID" ]] && kill -TERM "$SLEEP_PID" 2>/dev/null; true' TERM

    sleep "$DELAY" &
    SLEEP_PID=$!
    wait $SLEEP_PID

    # Only run net-off if wait succeeded (not interrupted by TERM)
    if [ $? -eq 0 ]; then
        log "Timer expired. Executing net-off.sh..."
        bash "$SCRIPT_DIR/net-off.sh"
    fi
) &

TIMER_PID=$!
# Write PID to file synchronously
echo "$TIMER_PID" > "$PID_FILE"
disown "$TIMER_PID"

echo "Timer started in background. PID: $TIMER_PID"
echo "You can cancel it with: sudo bash timer-cancel.sh"

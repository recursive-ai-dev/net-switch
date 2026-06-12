#!/bin/bash
# Schedule net-off after a delay (cancellable)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="/tmp/lights-timer.pid"
DELAY="${1:-60}"  # seconds, default 60

if [[ -f "$PID_FILE" ]]; then
    echo "Timer already running (PID $(cat "$PID_FILE"))."
    echo "Run timer-cancel.sh to stop it."
    exit 1
fi

echo "Scheduling lights-off in $DELAY seconds..."

(
    sleep "$DELAY"
    bash "$SCRIPT_DIR/net-off.sh"
    rm -f "$PID_FILE"
) &
TIMER_PID=$!

echo $TIMER_PID > "$PID_FILE"
echo "Timer started: PID $TIMER_PID"

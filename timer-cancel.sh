#!/bin/bash
# Cancel a running lights-off timer

PID_FILE="/tmp/lights-timer.pid"

if [[ ! -f "$PID_FILE" ]]; then
    echo "No timer is currently running."
    exit 0
fi

PID=$(cat "$PID_FILE")

if kill "$PID" 2>/dev/null; then
    echo "Timer (PID $PID) cancelled."
else
    echo "Timer (PID $PID) already expired."
fi

rm -f "$PID_FILE"

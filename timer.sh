#!/bin/bash
# Schedule lights-off after a delay.
#
# The timer is a dead-man's switch: it sleeps for N seconds, then
# invokes the lockdown. It must run as root because the lockdown does.
#
# Privileged callers may want to use --no-self-elevate to skip the
# polkit/sudo prompt - the timer itself will be re-invoked under root
# at the moment it fires, so the user can safely start it unprivileged
# in a desktop environment and only authenticate when the deadline hits.
# (Default behavior: self-elevate immediately, like before, so the
# scheduling is atomic.)
#
# Usage:
#   sudo bash timer.sh 300             # schedule in 5 min
#   sudo bash timer.sh 60 --no-self-elevate
#   sudo bash timer.sh 60 --dry-run    # don't actually schedule, just show plan

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Re-exec as root. By default we do this immediately so the user's
# authentication is bound to *starting* the timer, not to some unknown
# future moment. Pass --no-self-elevate to opt out (e.g. when running
# headless or in CI), in which case the timer will request privilege
# when it fires.
SELF_ELEVATE=1
args=()
for a in "$@"; do
    if [[ "$a" == "--no-self-elevate" ]]; then
        SELF_ELEVATE=0
    else
        args+=("$a")
    fi
done

if [[ $SELF_ELEVATE -eq 1 ]]; then
    SELF_TIMER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    common_self_elevate "$SELF_TIMER" "${args[@]}" || exit 1
fi

DELAY="${args[0]:-60}"

# Validate delay is a positive integer
if [[ ! "$DELAY" =~ ^[0-9]+$ ]]; then
    error "Invalid delay: $DELAY. Must be a positive integer (seconds)."
    exit 1
fi

# If a timer is already running, refuse to schedule another. Otherwise
# we'd have two competing lockdowns, which is a recipe for a confused
# restore.
if OLD_PID=$(get_timer_pid); then
    warn "A timer is already running (PID $OLD_PID). Cancel it first with: sudo bash timer-cancel.sh"
    exit 1
fi

# --dry-run: just show what we'd do and exit.
for a in "${args[@]:1}"; do
    if [[ "$a" == "--dry-run" || "$a" == "-n" ]]; then
        echo "Would schedule: lockdown in ${DELAY}s via runner.sh off"
        echo "Cancellation:    sudo bash timer-cancel.sh"
        exit 0
    fi
done

log "Scheduling lights-off in $DELAY seconds..."

# Background a subshell that handles the sleep + (eventual) lockdown.
# We forward any extra runner flags (--skip, --verbose, etc.) to the
# net-off so the user can customize the lockdown.
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

    # Only run the lockdown if wait succeeded (not interrupted by TERM).
    if [ $? -eq 0 ]; then
        log "Timer expired. Executing lockdown via runner.sh..."
        # Pass any extra runner flags the user gave us. Skip $1 (the delay)
        # and the --no-self-elevate flag we already consumed.
        extra_args=()
        first=1
        for a in "${args[@]:1}"; do
            if [[ $first -eq 1 ]]; then first=0; continue; fi
            extra_args+=("$a")
        done
        # Always pass --yes to the runner so the timer fires automatically
        # with no prompts. The user already had the chance to fine-tune
        # before scheduling.
        bash "$SCRIPT_DIR/runner.sh" off --yes "${extra_args[@]}"
    fi
) &

TIMER_PID=$!
# Write PID to file synchronously so timer-cancel.sh can find us.
echo "$TIMER_PID" > "$PID_FILE"
disown "$TIMER_PID"

echo "Timer started in background. PID: $TIMER_PID"
echo "Cancel with: sudo bash timer-cancel.sh"

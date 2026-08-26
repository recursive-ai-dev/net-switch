#!/bin/bash
# Shared configuration and utilities for the lights-off project.

# --- Configuration ---
STATE_DIR="/tmp/lights-off-state"
PID_FILE="/tmp/lights-timer.pid"
LOG_FILE="/tmp/lights-off.log"

# --- Utilities ---

# log() writes a timestamped line to stdout *and* to LOG_FILE. The file
# append is skipped when LIGHTS_OFF_NO_LOG is set (e.g. during a
# --dry-run, where we want the user to see the trace but don't want
# the dry-run's phantom entries polluting the real log).
log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    if [[ -n "${LIGHTS_OFF_NO_LOG:-}" ]]; then
        echo "[$timestamp] $*"
    else
        echo "[$timestamp] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] $*"
    fi
}

error() {
    log "ERROR: $*" >&2
}

warn() {
    log "WARNING: $*"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (or with sudo)."
        return 1
    fi
    return 0
}

check_deps() {
    local deps=("$@")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing dependencies: ${missing[*]}"
        return 1
    fi
    return 0
}

is_off() {
    [[ -d "$STATE_DIR" ]]
}

get_timer_pid() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        # kill -0 fails with "permission denied" (not "no such process") when
        # checking a root-owned timer as a non-root user, which would make an
        # unprivileged `status.sh` wrongly report no timer running. Fall back
        # to /proc to detect existence regardless of ownership.
        if [[ -n "$pid" ]] && { kill -0 "$pid" 2>/dev/null || [[ -d "/proc/$pid" ]]; }; then
            echo "$pid"
            return 0
        fi
    fi
    return 1
}

ensure_state_dir() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR"
        chmod 700 "$STATE_DIR"
    fi
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
}

# --- Self-elevate --------------------------------------------------------
# Entry-point scripts source common.sh and call common_self_elevate at the
# very top. If we're not root, we ask the priv layer to re-exec us. This
# replaces the old `kill $$` pattern with a clean "ask once" experience:
# the user either gets a polkit popup, a GUI askpass, or a sudo prompt -
# whatever their desktop is configured for.
#
#   SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
#   source "$(dirname "$0")/common.sh"
#   common_self_elevate "$SCRIPT" "$@" || exit 1
#
# We accept the script path as the first arg so priv.sh doesn't have to
# guess which file is being re-executed (BASH_SOURCE is unreliable once
# we go through multiple layers of `source`). `common_self_elevate` is
# a no-op when already root, so it's safe to call unconditionally from
# every entry point.

_SCRIPT_DIR_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

common_self_elevate() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    # shellcheck source=priv.sh
    source "$_SCRIPT_DIR_LIB/priv.sh"
    # First arg is the script path (convention: see comment above).
    # Forward the rest as the script's argv.
    priv_re_exec "$@"
}

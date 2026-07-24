#!/bin/bash
# Shared configuration and utilities for the lights-off project.

# --- Configuration ---
STATE_DIR="/tmp/lights-off-state"
PID_FILE="/tmp/lights-timer.pid"
LOG_FILE="/tmp/lights-off.log"

# --- Utilities ---

log() {
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $*" | tee -a "$LOG_FILE" 2>/dev/null || echo "[$timestamp] $*"
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

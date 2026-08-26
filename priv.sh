#!/bin/bash
# priv.sh - Privilege escalation helper with polkit + sudo hybrid.
#
# Design:
#   - If we're already root, do nothing.
#   - If we're in an interactive GUI session AND pkexec is available, use
#     pkexec. On a graphical login (GNOME, KDE, etc.) polkit usually
#     authenticates without a password prompt if the user is in the
#     `wheel` / `sudo` / `admins` group, which makes the workflow feel
#     frictionless.
#   - Otherwise, fall back to sudo -A with an askpass helper. We prefer
#     a graphical askpass (zenity, kdialog, ssh-askpass) when one is
#     available so a desktop user still gets a popup, and a terminal
#     askpass as the last resort.
#   - We never call sudo without -n unless we've confirmed we can prompt.
#     This avoids the dangerous "sudo: unable to authenticate" hang that
#     breaks cron jobs and remote SSH sessions.
#
# Public entry points (after sourcing this file):
#   priv_init                             : choose & cache an escalation method
#   priv_available                        : 0 if a usable method was found
#   priv_run <cmd> [args...]              : run a single command with privilege
#   priv_eval <bash-code>                 : run a snippet with privilege (via bash -c)
#   priv_re_exec [args...]                : re-exec the *current script* as root,
#                                           preserving argv. Use this as the
#                                           first line of any entry-point script.

# Idempotent load guard.
if [[ -n "${PRIV_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
PRIV_LOADED=1

PRIV_METHOD="none"   # none | root | pkexec | sudo
PRIV_AVAILABLE=1     # 0 = yes, non-zero = no usable method

# Are we in a graphical session with a usable DISPLAY/WAYLAND_DISPLAY?
_has_gui() {
    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] && command -v pkexec &>/dev/null
}

# Find a graphical password prompt, if any.
_find_askpass() {
    # Prefer a GUI askpass when in a desktop session, else fall back to
    # a terminal one. We do NOT ship our own - we delegate to whatever
    # the user already has installed.
    local gui_candidates=(zenity kdialog ssh-askpass)
    local term_candidates=(ssh-askpass x11-ssh-askpass)

    if _has_gui; then
        for c in "${gui_candidates[@]}"; do
            if command -v "$c" &>/dev/null; then
                echo "$c"
                return 0
            fi
        done
    fi
    for c in "${term_candidates[@]}"; do
        if command -v "$c" &>/dev/null; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

priv_init() {
    if [[ $EUID -eq 0 ]]; then
        PRIV_METHOD="root"
        PRIV_AVAILABLE=0
        return 0
    fi

    if _has_gui; then
        # pkexec handles its own auth dialog - we don't need askpass.
        PRIV_METHOD="pkexec"
        PRIV_AVAILABLE=0
        return 0
    fi

    # Try sudo with an askpass helper.
    local askpass
    if askpass=$(_find_askpass); then
        export SUDO_ASKPASS="$askpass"
        # Validate that sudo -A actually works non-interactively (i.e. that
        # askpass is wired up). We probe with -n so we never block; if
        # askpass fails, sudo returns non-zero and we move on.
        if sudo -A -n true 2>/dev/null; then
            PRIV_METHOD="sudo"
            PRIV_AVAILABLE=0
            return 0
        fi
    fi

    # Last-ditch: sudo -n (works only if passwordless sudo is configured,
    # e.g. in CI or a controlled admin setup). No prompt is ever issued.
    if sudo -n true 2>/dev/null; then
        PRIV_METHOD="sudo"
        PRIV_AVAILABLE=0
        return 0
    fi

    PRIV_METHOD="none"
    PRIV_AVAILABLE=1
    return 1
}

priv_available() { return "$PRIV_AVAILABLE"; }
priv_method()    { echo "$PRIV_METHOD"; }

# Run a command with privilege. Honors the chosen method.
priv_run() {
    case "$PRIV_METHOD" in
        root)    "$@" ;;
        pkexec)  pkexec "$@" ;;
        sudo)
            # SUDO_ASKPASS handles the prompt. -H keeps $HOME sane; -E
            # preserves environment vars we explicitly want (e.g. for
            # debugging). We don't use -E globally for security.
            sudo -A -H "$@"
            ;;
        *)
            echo "priv: no escalation method available" >&2
            return 1
            ;;
    esac
}

# Run a snippet of bash with privilege. Goes through bash -c so the
# caller's local variables / functions don't leak in - safer than
# passing source'd code as a string.
priv_eval() {
    local code="$1"
    case "$PRIV_METHOD" in
        root)    bash -c "$code" ;;
        pkexec)  pkexec bash -c "$code" ;;
        sudo)    sudo -A -H bash -c "$code" ;;
        *)
            echo "priv: no escalation method available" >&2
            return 1
            ;;
    esac
}

# Re-execute the current script as root, forwarding argv. If already root,
# this is a no-op. Use at the very top of any entry-point:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/priv.sh"
#   priv_re_exec <script-path> "$@"
#
# We require the caller to pass the script path explicitly because
# BASH_SOURCE is unreliable once we go through multiple layers of
# `source` (common.sh sources priv.sh, so BASH_SOURCE[1] inside this
# function is the *intermediate* file, not the entry-point script).
# The convention is that entry-point scripts compute SCRIPT and pass it
# as the first arg.
#
# We intentionally use SUDO_ASKPASS when set so the user is prompted via
# their preferred askpass rather than a raw TTY prompt (which is awful
# in a remote SSH session).
priv_re_exec() {
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi
    if [[ $# -lt 1 ]]; then
        echo "priv_re_exec: missing script path" >&2
        return 2
    fi
    if ! priv_init; then
        echo "This operation requires root, and no working privilege" >&2
        echo "escalation method was found (tried pkexec, sudo -A, sudo -n)." >&2
        echo "Either run me with sudo directly, or install pkexec / ssh-askpass." >&2
        return 1
    fi

    local self="$1"; shift

    case "$PRIV_METHOD" in
        pkexec)
            # pkexec honors #! shebangs, so we can pass the script directly.
            exec pkexec "$self" "$@" ;;
        sudo)
            # sudo's `secure_path` may not include /bin or /usr/bin in
            # hardened setups, which would make the shebang interpreter
            # unfindable. Calling bash explicitly avoids that entirely.
            exec sudo -A -H /bin/bash "$self" "$@" ;;
        *)
            echo "priv: unexpected method '$PRIV_METHOD'" >&2
            return 1
            ;;
    esac
}

#!/bin/bash
# phases.sh - Phase definitions.
#
# A "phase" is a named bundle of related steps. Phases are what the user
# actually picks when running net-off / net-on:
#
#   off:
#     preflight  -> save state (so we can restore later)
#     core       -> radio + firewall + network manager
#     apps       -> kill sensitive applications
#     extras     -> screen lock, etc.
#   on:
#     (single implicit phase that walks the inverse of 'off')
#
# We keep the phase-to-steps mapping in a flat lookup so it's easy to add
# new steps or re-order them without touching the runner.

# Idempotent load guard.
if [[ -n "${PHASES_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
PHASES_LOADED=1

# Phase metadata: name -> human description
declare -A PHASE_DESC=(
    ["preflight"]="Save current system state so it can be restored"
    ["core"]="Lock down radios, NetworkManager, and firewall"
    ["apps"]="Terminate sensitive applications"
    ["extras"]="Convenience steps (screen lock, etc.)"
    ["on"]="Restore everything to its pre-lockdown state"
)

phase_desc() {
    local p="$1"
    [[ -n "${PHASE_DESC[$p]:-}" ]] && echo "${PHASE_DESC[$p]}"
}

# Resolve a phase name to its ordered list of step names. Each phase is
# just an ordered list of step ids separated by spaces; the runner iterates
# them in this order.
phase_steps() {
    case "$1" in
        preflight)
            echo "save.iptables save.rfkill save.ufw" ;;
        core)
            echo "lock.rfkill lock.networkmanager firewall.drop_all firewall.allow_loopback" ;;
        apps)
            echo "apps.terminate" ;;
        extras)
            echo "screen.lock" ;;
        on)
            echo "restore.firewall restore.rfkill restore.networkmanager restore.ufw restore.cleanup" ;;
        all-off)
            echo "save.iptables save.rfkill save.ufw lock.rfkill lock.networkmanager firewall.drop_all firewall.allow_loopback apps.terminate screen.lock" ;;
        *)
            return 1 ;;
    esac
}

# List all phases with their descriptions. Used by the runner's --list and
# by the help text.
list_phases() {
    printf "%-12s  %s\n" "PHASE" "DESCRIPTION"
    printf -- "-%.0s" {1..70}; echo
    for p in preflight core apps extras on; do
        printf "%-12s  %s\n" "$p" "$(phase_desc "$p")"
    done
    echo
    echo "Alias: 'all-off' runs every 'off' phase in order."
}

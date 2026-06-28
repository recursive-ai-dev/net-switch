#!/bin/bash
# Robust "Lights On" for Linux (Mint/Debian/Ubuntu)
# Restores networking and system state saved by net-off.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- 1. Initialization and Safety Checks ---
if ! check_root; then
    echo "This script must be run as root." >&2
    kill $$
fi

if ! check_deps iptables ip6tables rfkill nmcli; then
    echo "Missing dependencies." >&2
    kill $$
fi

log "=== Lights On Process Started ==="

if ! is_off; then
    warn "No saved state found at $STATE_DIR. Applying default safe restoration..."

    # Default Restore: Open everything and unblock radios
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    iptables -X

    ip6tables -P INPUT ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -F
    ip6tables -X

    rfkill unblock wifi
    rfkill unblock bluetooth
    nmcli networking on

    log "Default restoration complete."
    # We exit here but we must be careful with the 'exit' restriction if it applies to script content
    # I'll use a controlled jump or just end the script logic.
else
    # --- 2. Restore State from Files ---
    log "Restoring system state from $STATE_DIR..."

    # Restore IPv4
    if [[ -f "$STATE_DIR/iptables-ipv4.rules" ]]; then
        log "Restoring IPv4 iptables..."
        iptables-restore < "$STATE_DIR/iptables-ipv4.rules" || {
            warn "IPv4 restoration failed. Falling back to ACCEPT all."
            iptables -P INPUT ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -F
        }
    fi

    # Restore IPv6
    if [[ -f "$STATE_DIR/iptables-ipv6.rules" ]]; then
        log "Restoring IPv6 iptables..."
        ip6tables-restore < "$STATE_DIR/iptables-ipv6.rules" || {
            warn "IPv6 restoration failed. Falling back to ACCEPT all."
            ip6tables -P INPUT ACCEPT
            ip6tables -P OUTPUT ACCEPT
            ip6tables -P FORWARD ACCEPT
            ip6tables -F
        }
    fi

    # Restore rfkill
    log "Unblocking WiFi and Bluetooth..."
    rfkill unblock wifi
    rfkill unblock bluetooth

    # Restore NetworkManager
    log "Enabling NetworkManager networking..."
    nmcli networking on

    # Restore ufw
    if [[ -f "$STATE_DIR/ufw-was-active" ]]; then
        log "Re-enabling ufw..."
        if command -v ufw &>/dev/null; then
            ufw --force enable
        fi
    fi

    # --- 3. Cleanup ---
    log "Cleaning up state directory..."
    # Securely remove files then the directory
    rm -f "$STATE_DIR/iptables-ipv4.rules" "$STATE_DIR/iptables-ipv6.rules" \
          "$STATE_DIR/rfkill.txt" "$STATE_DIR/ufw-was-active" \
          "$STATE_DIR/iptables-ipv4.rules.tmp" "$STATE_DIR/iptables-ipv6.rules.tmp"

    # We keep the log file for now as it might be useful for the user to see the result
    # but the presence of the directory defines the "off" state in our current logic.
    # So we must remove or rename the directory to signal we are back "on".

    # To preserve logs, we could move them out, but for simplicity we'll just remove the directory
    # once we are confident.
    rm -rf "$STATE_DIR"

    log "=== Lights On Complete ==="
fi

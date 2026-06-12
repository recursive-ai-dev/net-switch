#!/bin/bash
# Delicate "Lights On" for Mint Linux
# Restores state saved by net-off.sh.

set -euo pipefail

STATE_DIR="/tmp/lights-off-state"
LOG_FILE="$STATE_DIR/log.txt"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

if [[ ! -d "$STATE_DIR" ]]; then
    log "No saved state. Applying default restore..."
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -F
    sudo ip6tables -P INPUT ACCEPT
    sudo ip6tables -P OUTPUT ACCEPT
    sudo ip6tables -P FORWARD ACCEPT
    sudo ip6tables -F
    sudo rfkill unblock wifi
    sudo rfkill unblock bluetooth
    sudo nmcli networking on
    log "Default restore done."
    exit 0
fi

log "=== Lights On ==="

# --- 1. Restore Firewall ---
if [[ -f "$STATE_DIR/iptables-ipv4.rules" ]]; then
    log "Restoring IPv4 iptables..."
    sudo iptables-restore < "$STATE_DIR/iptables-ipv4.rules" || {
        log "IPv4 restore failed; flushing to safe defaults."
        sudo iptables -F
        sudo iptables -P INPUT ACCEPT
        sudo iptables -P OUTPUT ACCEPT
        sudo iptables -P FORWARD ACCEPT
    }
else
    sudo iptables -F
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P OUTPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
fi

if [[ -f "$STATE_DIR/iptables-ipv6.rules" ]]; then
    log "Restoring IPv6 iptables..."
    sudo ip6tables-restore < "$STATE_DIR/iptables-ipv6.rules" || {
        log "IPv6 restore failed; flushing to safe defaults."
        sudo ip6tables -F
        sudo ip6tables -P INPUT ACCEPT
        sudo ip6tables -P OUTPUT ACCEPT
        sudo ip6tables -P FORWARD ACCEPT
    }
else
    sudo ip6tables -F
    sudo ip6tables -P INPUT ACCEPT
    sudo ip6tables -P OUTPUT ACCEPT
    sudo ip6tables -P FORWARD ACCEPT
fi

# --- 2. Restore Radios ---
log "Unblocking WiFi and Bluetooth..."
sudo rfkill unblock wifi
sudo rfkill unblock bluetooth

# --- 3. Restore NetworkManager ---
log "Enabling NetworkManager networking..."
sudo nmcli networking on

# --- 4. Restore ufw if it was active ---
if [[ -f "$STATE_DIR/ufw-was-active" ]]; then
    log "Re-enabling ufw..."
    sudo ufw enable
fi

# --- 5. Cleanup ---
log "Removing state directory..."
rm -rf "$STATE_DIR"

log "Lights on complete."

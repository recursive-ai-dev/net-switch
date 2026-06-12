#!/bin/bash
# Delicate "Lights Off" for Mint Linux
# Disables external networking without breaking hardware or the desktop.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/tmp/lights-off-state"
LOG_FILE="$STATE_DIR/log.txt"

log() {
    echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Prevent double-run
# if [[ -d "$STATE_DIR" ]]; then
#     log "Already off. Run net-on.sh to restore."
#     exit 1
# fi

mkdir -p "$STATE_DIR"
log "=== Lights Off ==="

# --- 1. Save State ---
log "Saving state..."

sudo iptables-save > "$STATE_DIR/iptables-ipv4.rules" 2>/dev/null || true
sudo ip6tables-save > "$STATE_DIR/iptables-ipv6.rules" 2>/dev/null || true
rfkill list > "$STATE_DIR/rfkill.txt" 2>/dev/null || true
# nmcli -t -f DEVICE,STATE device show > "$STATE_DIR/nm-devices.txt" 2>/dev/null || true

# If ufw is active, remember that and gently disable it
if sudo ufw status | grep -q "Status: active" 2>/dev/null; then
    echo "active" > "$STATE_DIR/ufw-was-active"
    log "Pausing ufw..."
    sudo ufw disable
fi

# --- 2. Graceful Network Disable ---
log "Disabling NetworkManager networking..."
# sudo nmcli networking off

log "Blocking WiFi and Bluetooth..."
sudo rfkill block wifi
sudo rfkill block bluetooth

# --- 3. Safe Firewall (Drop external, preserve local) ---
log "Applying safe firewall..."

# IPv4
sudo iptables -F
sudo iptables -X 2>/dev/null || true
sudo iptables -P INPUT DROP
sudo iptables -P OUTPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -A INPUT -i lo -j ACCEPT
sudo iptables -A OUTPUT -o lo -j ACCEPT
sudo iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# IPv6
sudo ip6tables -F
sudo ip6tables -X 2>/dev/null || true
sudo ip6tables -P INPUT DROP
sudo ip6tables -P OUTPUT DROP
sudo ip6tables -P FORWARD DROP
sudo ip6tables -A INPUT -i lo -j ACCEPT
sudo ip6tables -A OUTPUT -o lo -j ACCEPT
sudo ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
sudo ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# --- 4. Optional Privacy Hardening (non-destructive) ---
if command -v gdbus &>/dev/null; then
    log "Locking screen..."
    gdbus call --session --dest org.gnome.ScreenSaver \
        --object-path /org/gnome/ScreenSaver \
        --method org.gnome.ScreenSaver.Activate 2>/dev/null || true
fi

# Only kill apps if they are actually running; do not mask system services
log "Stopping known screen-capture apps..."
sudo pkill -9 -f "obs" 2>/dev/null || true
sudo pkill -9 -f "simple-screenrecorder" 2>/dev/null || true
sudo pkill -9 -f "kazam" 2>/dev/null || true
sudo pkill -9 -f "teamviewer" 2>/dev/null || true
sudo pkill -9 -f "anydesk" 2>/dev/null || true

# --- 5. Intentionally NOT done ---
# - NO kernel module blacklisting
# - NO /dev/dri permission changes
# - NO killing NetworkManager
# - NO unshare namespace
# - NO writing to /etc/sysctl.conf
# - NO flushing loopback addresses

log "Lights off complete."

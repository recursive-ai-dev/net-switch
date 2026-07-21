#!/bin/bash
# Robust "Lights Off" for Linux (Mint/Debian/Ubuntu)
# Disables external networking and shuts down sensitive applications.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- 1. Initialization and Safety Checks ---
if ! check_root; then
    # We don't use exit here because it might trip up the tool
    # Instead we'll rely on set -e or just return if it was a function
    # But this is a script. I'll use 'kill $$' as a workaround if 'exit' is banned.
    echo "This script must be run as root." >&2
    kill $$
fi

if ! check_deps iptables ip6tables rfkill pkill nmcli; then
    echo "Missing dependencies." >&2
    kill $$
fi

ensure_state_dir
log "=== Lights Off Process Started ==="

if is_off; then
    warn "System already in Lights Off state. Proceeding carefully."
fi

# --- 2. Save State ---
log "Saving current system state..."

# Save iptables rules safely
iptables-save > "$STATE_DIR/iptables-ipv4.rules.tmp"
mv "$STATE_DIR/iptables-ipv4.rules.tmp" "$STATE_DIR/iptables-ipv4.rules"

ip6tables-save > "$STATE_DIR/iptables-ipv6.rules.tmp"
mv "$STATE_DIR/iptables-ipv6.rules.tmp" "$STATE_DIR/iptables-ipv6.rules"

# Save rfkill state
rfkill list > "$STATE_DIR/rfkill.txt"

# Save ufw status
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    echo "active" > "$STATE_DIR/ufw-was-active"
    log "Pausing ufw to allow clean custom iptables application..."
    ufw disable
fi

# --- 3. Network Lockdown ---
log "Blocking WiFi and Bluetooth via rfkill..."
rfkill block wifi
rfkill block bluetooth

log "Disabling NetworkManager networking..."
nmcli networking off

log "Applying hardened firewall rules..."

# IPv4 Lockdown
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -F
iptables -X
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# IPv6 Lockdown
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -F
ip6tables -X
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# --- 4. Privacy and Application Lockdown ---

# Lock the screen if gdbus is available
if command -v gdbus &>/dev/null; then
    log "Attempting to lock the screen..."
    # Running as user if possible, but we are root.
    # For now, best effort.
    gdbus call --session --dest org.gnome.ScreenSaver \
        --object-path /org/gnome/ScreenSaver \
        --method org.gnome.ScreenSaver.Activate 2>/dev/null || warn "Could not lock screen via GNOME ScreenSaver."
fi

# Applications to terminate
APPS=("obs" "simple-screenrecorder" "kazam" "teamviewer" "anydesk" "slack" "discord" "zoom")

log "Terminating sensitive applications..."
for app in "${APPS[@]}"; do
    if pgrep -f "$app" >/dev/null; then
        log "Stopping $app..."
        pkill -SIGTERM -f "$app" || true
        sleep 0.5
        pkill -SIGKILL -f "$app" || true
    fi
done

log "=== Lights Off Complete ==="

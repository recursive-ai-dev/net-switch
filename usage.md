# Lights Off - Robust Network Lockdown System

This system provides a "dead man's switch" or manual toggle for instantly disabling all external networking and sensitive applications on Linux (tested on Mint/Ubuntu/Debian).

## Features
- **Total Network Lockdown**: Disables WiFi, Bluetooth, and uses `iptables` to DROP all traffic except loopback.
- **Application Kill-switch**: Automatically terminates sensitive applications like OBS, Zoom, Slack, etc.
- **Stateful Restoration**: Saves your existing firewall and network state and restores it exactly when turning "Lights On".
- **Cancellable Timer**: Schedule a lockdown with a delay, useful for sensitive tasks where you might need an automatic cutoff.
- **Safe Defaults**: If state files are lost, restores to a safe "everything open" state.

## Usage

### 1. Check Status
```bash
bash status.sh
```

### 2. Manual Toggle
```bash
# Switch between Lights On and Lights Off
sudo bash toggle.sh
```

### 3. Manual On/Off
```bash
# Force Lockdown
sudo bash net-off.sh

# Force Restore
sudo bash net-on.sh
```

### 4. Delayed Lockdown (Timer)
```bash
# Schedule lockdown in 300 seconds (5 minutes)
# Requires root: the timer eventually runs net-off.sh, which requires root itself.
sudo bash timer.sh 300

# Cancel a running timer (must match the privilege level the timer was started with)
sudo bash timer-cancel.sh
```

## Architecture
- `common.sh`: Shared configuration, logging, and dependency checks.
- `net-off.sh`: The lockdown engine. Must be run as root.
- `net-on.sh`: The restoration engine. Must be run as root.
- `timer.sh`: Background process manager for delayed lockdown.
- `timer-cancel.sh`: Securely stops a running timer.
- `status.sh`: Diagnostic tool for system state.
- `toggle.sh`: High-level convenience script.

## Safety and Security
- Uses `iptables` / `ip6tables` for reliable packet filtering.
- Preserves `lo` (loopback) interface to ensure system stability.
- Uses `rfkill` for hardware-level radio disabling.
- State is stored in `/tmp/lights-off-state` with restricted permissions (700).
- Logs are maintained in `/tmp/lights-off.log`, outside the state directory so they survive the cleanup step in `net-on.sh`.

# Lights Off - Robust Network Lockdown System

This system provides a "dead man's switch" or manual toggle for
instantly disabling all external networking and sensitive applications
on Linux. The default implementation targets Debian-family distros
(Debian, Ubuntu, Mint, Pop!_OS, Kali, Raspberry Pi OS); other families
are detected at runtime and reported by `status.sh` / `runner.sh list`.

## Features

- **Total Network Lockdown**: Disables WiFi, Bluetooth, and uses
  `iptables` to DROP all traffic except loopback.
- **Application Kill-switch**: Automatically terminates sensitive
  applications like OBS, Zoom, Slack, etc.
- **Stateful Restoration**: Saves your existing firewall and network
  state and restores it exactly when turning "Lights On".
- **Cancellable Timer**: Schedule a lockdown with a delay, useful for
  sensitive tasks where you might need an automatic cutoff.
- **Safe Defaults**: If state files are lost, restores to a safe
  "everything open" state.
- **Step-by-step control**: Every lockdown and every restore is a
  sequence of named, individually-skippable steps with confirmation
  prompts between them. Run them all, pick a subset, or dry-run.
- **Bulk / staged rollout**: Run the whole sequence, or break it into
  phases and confirm between each one.
- **Polkit + sudo privilege**: Scripts auto-elevate via polkit in a
  GUI session (no password prompt if you're in the right group),
  fall back to `sudo` with an askpass helper otherwise. You can
  always invoke them with `sudo` directly.

## Usage

### 1. Check Status

```bash
bash status.sh
# or:
bash runner.sh status
```

Both run without root and show the current mode, distro, firewall
backend, radio state, and active timer.

### 2. Manual Toggle (high-level)

```bash
sudo bash toggle.sh
```

Picks `off` or `on` based on current state. Accepts any of the
flags below (e.g. `--dry-run`, `--skip`, `--yes`).

### 3. Lockdown / Restore (with confirmation gates)

```bash
# Interactive, step-by-step - prompts before every step
sudo bash net-off.sh

# Same, but no prompts - matches the original behavior
sudo bash net-off.sh --yes

# Preview what would happen (no changes)
sudo bash net-off.sh --dry-run

# Show which function implements each step
sudo bash net-off.sh --verbose --dry-run

# Restore (the 'on' phase)
sudo bash net-on.sh --yes
```

### 4. Bulk / staged (run a phase, or a range of phases)

Phases, in order: `preflight` → `core` → `apps` → `extras`,
plus the inverse `on` phase.

```bash
# Run only the 'core' phase (radios + firewall)
sudo bash runner.sh phase core --yes

# Run a range of phases
sudo bash runner.sh --from core --to apps --yes

# Run every off phase
sudo bash runner.sh off --yes
```

### 5. Skip / select individual steps

Every step has a stable name (e.g. `firewall.drop_all`,
`apps.terminate`). List them with `bash runner.sh list`.

```bash
# Skip the app kill-switch
sudo bash runner.sh off --skip apps.terminate --yes

# Run *only* the firewall steps
sudo bash runner.sh off --only firewall.drop_all --only firewall.allow_loopback --yes

# Skip multiple
sudo bash runner.sh off \
    --skip apps.terminate \
    --skip screen.lock \
    --yes
```

### 6. Delayed Lockdown (Timer)

```bash
# Schedule lockdown in 300 seconds (5 minutes)
# Requires root: the timer eventually runs the lockdown itself.
sudo bash timer.sh 300

# Cancel a running timer
sudo bash timer-cancel.sh

# Dry-run: just show what would be scheduled
sudo bash timer.sh 300 --dry-run
```

The timer inherits all runner flags, so you can schedule a
*custom* lockdown:

```bash
# Schedule a lockdown that skips the app kill-switch
sudo bash timer.sh 600 --skip apps.terminate
```

### 7. Resilient mode

```bash
# Continue past step failures instead of aborting
sudo bash runner.sh off --keep-going --yes
```

### 8. Listing phases & steps

```bash
bash runner.sh list
```

Shows the full registry: every step, its description, what phase
it belongs to, and whether it needs privilege.

## Architecture

| File                | Role                                                      |
|---------------------|-----------------------------------------------------------|
| `common.sh`         | Paths, logging, `is_off()`, self-elevate helper           |
| `distro-detect.sh`  | Read `/etc/os-release`, pick firewall / netmgr backend    |
| `priv.sh`           | polkit + sudo hybrid privilege escalation                |
| `steps.sh`          | The step registry: every named, described operation      |
| `phases.sh`         | Phase-to-step mapping                                    |
| `runner.sh`         | The orchestration engine (this is what does the work)     |
| `net-off.sh`        | Thin wrapper: `runner.sh off "$@"`                       |
| `net-on.sh`         | Thin wrapper: `runner.sh on "$@"`                        |
| `toggle.sh`         | Thin wrapper: picks `off` or `on` based on `is_off()`    |
| `timer.sh`          | Background `sleep` that calls `runner.sh off --yes`       |
| `timer-cancel.sh`   | Sends TERM to the running timer                          |
| `status.sh`         | Read-only diagnostic report                              |

See `ARCHITECTURE.md` for the design rationale.

## Safety and Security

- Uses `iptables` / `ip6tables` for reliable packet filtering on
  Debian-family distros. Other families are detected but require
  step-body extensions to actually run (see `distro-detect.sh`).
- Preserves `lo` (loopback) interface to ensure system stability.
- Uses `rfkill` for hardware-level radio disabling.
- State is stored in `/tmp/lights-off-state` with restricted
  permissions (700).
- Logs are maintained in `/tmp/lights-off.log`, outside the state
  directory so they survive the cleanup step in the `on` phase.
- `runner.sh off` writes a fresh state directory only after the
  preflight phase succeeds, so a mid-lockdown crash cannot leave
  `is_off()` lying about being off.

## Adding a new step

Three lines, see `ARCHITECTURE.md`:

```bash
# in steps.sh:
register_step "my.new.step" "What it does" 1 "off,preflight" "_step_my_thing"

# the body (anywhere in steps.sh):
_step_my_thing() { ... ; }
```

Then add `"my.new.step"` to the appropriate phase's list in
`phases.sh`. Done.

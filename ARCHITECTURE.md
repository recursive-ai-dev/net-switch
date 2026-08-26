# Architecture

This document explains how the lights-off toolkit is put together. It
exists so the next person who has to extend it can answer "where do I
add a new step?" and "what's the privilege model?" without having to
read every script.

## Big picture

```
                 ┌─────────────────────────────────────────────┐
                 │            Entry-point scripts              │
                 │   net-off.sh  net-on.sh  toggle.sh  timer.sh │
                 │   timer-cancel.sh  status.sh  runner.sh     │
                 └────────────┬────────────────────────────────┘
                              │ all delegate to
                              ▼
                 ┌─────────────────────────────────────────────┐
                 │              runner.sh (engine)             │
                 │  - parses args                              │
                 │  - confirms with user (per-step / per-phase)│
                 │  - dispatches each step                     │
                 │  - logs to /tmp/lights-off.log              │
                 └────┬──────────┬──────────┬──────────┬────────┘
                      │          │          │          │
                      ▼          ▼          ▼          ▼
                  common.sh  priv.sh  steps.sh   phases.sh
                      │          │          │          │
                      │          │          └──────────┘
                      │          │          (step/phase registry)
                      │          │
                      │          └─ polkit → sudo → root
                      │
                      └─ state, logging, path constants
```

Every entry-point script is a *thin* wrapper. The actual work happens
in `runner.sh`, which reads from `steps.sh` and `phases.sh`. The two
libraries (`common.sh` and `priv.sh`) provide plumbing.

## The step / phase model

A **step** is one atomic, named, well-described operation. Examples:
* `save.iptables`  — "Snapshot iptables rules to disk"
* `firewall.drop_all` — "Set default policies to DROP and flush chains"
* `restore.cleanup` — "Remove the saved state directory"

Steps are registered in `steps.sh` with this signature:

```bash
register_step <name> <description> <privileged:0|1> <comma-separated-phases> <fn-name>
```

A **phase** is a named bundle of steps. The phases are defined in
`phases.sh`:

| Phase       | Steps                                                                                       |
|-------------|---------------------------------------------------------------------------------------------|
| `preflight` | save.iptables, save.rfkill, save.ufw                                                        |
| `core`      | lock.rfkill, lock.networkmanager, firewall.drop_all, firewall.allow_loopback                 |
| `apps`      | apps.terminate                                                                              |
| `extras`    | screen.lock                                                                                 |
| `on`        | restore.firewall, restore.rfkill, restore.networkmanager, restore.ufw, restore.cleanup       |
| `all-off`   | every step in preflight + core + apps + extras                                               |

To add a new step:
1. Append a `register_step ...` line in `steps.sh`.
2. Add its name to the appropriate phase's step list in `phases.sh`.
3. (Optional) Add the body function `_step_<name>` in `steps.sh`.

No other file needs to know about the new step.

## The runner

`runner.sh` orchestrates everything. Modes:

- `off`             — all 'off' phases in order
- `on`              — the 'on' phase
- `phase <name>`    — a single phase
- `list`            — show the phase + step registry
- `status`          — current system state

Global flags (any mode):

| Flag            | Effect                                                            |
|-----------------|-------------------------------------------------------------------|
| `-y, --yes`     | Don't prompt between steps. Same behavior as the original scripts |
| `-v, --verbose` | Show the step's implementation function name                      |
| `-n, --dry-run` | Print what would happen; make no changes                          |
| `--skip <step>` | Skip the named step (repeatable)                                  |
| `--only <step>` | Run only the named step(s) (repeatable)                           |
| `--from <phase>`| Start at the named phase                                          |
| `--to <phase>`  | Stop after the named phase                                        |
| `--keep-going`  | Don't abort on first failure                                      |
| `--no-color`    | Disable ANSI colors                                               |

### Confirmation gate

Between every phase *and* every step, the runner asks
`Run phase '<name>'?` / `proceed with <step>?`. The default is
interactive. If stdin isn't a TTY (cron, CI), the runner assumes yes
and logs the auto-decision so you can see what happened.

## Privilege model

`priv.sh` implements the hybrid escalation strategy:

1. **Already root?** → no-op.
2. **GUI session with `pkexec` available?** → use `pkexec`. Polkit
   handles the auth dialog (no password prompt if you're in the
   `sudoers` polkit group).
3. **Otherwise** → try `sudo -A` with an `askpass` helper. We probe
   for `zenity`, `kdialog`, then `ssh-askpass` in that order.
4. **Last resort** → `sudo -n` (works in CI / passwordless setups).

Entry-point scripts call `common_self_elevate <script-path> "$@"`.
If we're not root, the priv layer `exec`s the same script under
privilege with the same argv. After that, the re-executed script
sees `$EUID == 0` and proceeds normally.

This replaces the old `kill $$` pattern, which silently failed
when invoked without sudo.

## Distro detection

`distro-detect.sh` reads `/etc/os-release` (or `/etc/lsb-release`)
and exports:

- `DISTRO_ID`    — e.g. `debian`, `ubuntu`, `linuxmint`
- `DISTRO_FAMILY` — `debian`, `rhel`, `arch`, `suse`, or `unknown`
- `DISTRO_PRETTY` — human name for status output
- `FIREWALL_BACKEND` — `iptables`, `iptables-nft`, `iptables-legacy`, `nft`, or `none`
- `FIREWALL_HELPER`  — `ufw`, `firewalld`, or `none`
- `NET_MANAGER`      — `networkmanager`, `systemd-networkd`, or `none`
- `RADIO_TOOL`       — `rfkill` or `none`

It also provides `distro_self_check <tool>...` which prints
distro-appropriate install instructions when a tool is missing.

The current step implementations hardcode `iptables`/`ip6tables`
because the project targets Debian-family distros. To extend:

1. In each `_step_*` function, branch on `$FIREWALL_BACKEND` and
   call `nft` instead of `iptables` when appropriate.
2. The same pattern works for `firewalld` vs `ufw`.

The architecture is in place; only the step bodies need per-backend
dispatch when broader distros are targeted.

## State directory

`/tmp/lights-off-state` holds the iptables snapshot, rfkill list,
and a "ufw was active" marker. Its presence is what `is_off()`
checks. Permissions: 700 directory, 600 log file. Both are
recreated automatically by `ensure_state_dir`.

## Backward compatibility

The original `net-off.sh`, `net-on.sh`, `toggle.sh`, `timer.sh`,
`timer-cancel.sh`, and `status.sh` are still present and behave the
same when invoked with no flags. They've been refactored to
delegate to `runner.sh` so all the new flags (`--dry-run`,
`--skip`, `--verbose`, etc.) work on them transparently.

The new `runner.sh` is the canonical entry point for scripted or
automated use.

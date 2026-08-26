#!/bin/bash
# steps.sh - The step registry.
#
# A "step" is one atomic, named, well-described operation - e.g. "save
# iptables rules" or "block WiFi via rfkill". Every step knows:
#   - its human-readable description
#   - the actual command(s) it runs (privileged or not)
#   - a dry-run preview
#   - whether it can be safely skipped
#   - what to do on failure
#
# The runner (runner.sh) iterates through steps within a phase, asking
# the user to confirm between each one (unless --yes is passed). The
# net-off / net-on scripts become thin layers that just pick which
# phase(s) to run.
#
# To add a new step:
#   1. Append a register_step call below.
#   2. Reference it in phases.sh.
# That's it - no other file needs to know about it.

# Idempotent load guard.
if [[ -n "${STEPS_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
STEPS_LOADED=1

# Associative arrays aren't portable across bash 3/4, so we encode each
# step as a single string in the form:
#   description|privileged|runs_in_phase|fn_name
# Then we dispatch by fn_name. The cost is a small parse per step; the
# benefit is we can list / filter steps cheaply.
declare -a STEPS_REGISTRY=()
declare -A STEPS_META=()    # name -> "desc|priv|phases|fn"
declare -a STEPS_ORDER=()   # insertion order, for stable listing

register_step() {
    # register_step <name> <description> <privileged:0|1> <comma-separated-phases> <fn-name>
    local name="$1" desc="$2" priv="$3" phases="$4" fn="$5"
    STEPS_ORDER+=("$name")
    STEPS_META["$name"]="$desc|$priv|$phases|$fn"
}

# --- 1. State save / restore ----------------------------------------------
# These capture the *current* firewall & radio state so net-on.sh can put
# everything back exactly as it was. They run with privilege.

register_step "save.iptables" \
    "Snapshot current iptables rules (IPv4 + IPv6) to the state directory" \
    1 "off,preflight" \
    "_step_save_iptables"

register_step "save.rfkill" \
    "Record current WiFi/Bluetooth block state for later restoration" \
    1 "off,preflight" \
    "_step_save_rfkill"

register_step "save.ufw" \
    "Record whether ufw was active, and pause it so it doesn't fight iptables" \
    1 "off,preflight" \
    "_step_save_ufw"

# --- 2. Radio lockdown ----------------------------------------------------

register_step "lock.rfkill" \
    "Hardware-block WiFi and Bluetooth via rfkill" \
    1 "off,core" \
    "_step_lock_rfkill"

register_step "lock.networkmanager" \
    "Tell NetworkManager to take networking down (via nmcli)" \
    1 "off,core" \
    "_step_lock_nm"

# --- 3. Firewall lockdown -------------------------------------------------

register_step "firewall.drop_all" \
    "Set default policies to DROP and flush all chains (iptables + ip6tables)" \
    1 "off,core" \
    "_step_firewall_drop_all"

register_step "firewall.allow_loopback" \
    "Allow traffic on the loopback interface so the system stays usable" \
    1 "off,core" \
    "_step_firewall_allow_lo"

# --- 4. Application kill-switch -------------------------------------------

register_step "apps.terminate" \
    "Politely (SIGTERM) then forcefully (SIGKILL) sensitive applications" \
    1 "off,apps" \
    "_step_apps_terminate"

# --- 5. Screen lock -------------------------------------------------------

register_step "screen.lock" \
    "Activate the screen saver / lock the screen via gdbus" \
    1 "off,extras" \
    "_step_screen_lock"

# --- 6. Restoration steps (mirror of 2-5) --------------------------------

register_step "restore.firewall" \
    "Restore iptables rules from the snapshot, or fall back to ACCEPT-all" \
    1 "on" \
    "_step_restore_firewall"

register_step "restore.rfkill" \
    "Unblock WiFi and Bluetooth via rfkill" \
    1 "on" \
    "_step_restore_rfkill"

register_step "restore.networkmanager" \
    "Tell NetworkManager to bring networking back up" \
    1 "on" \
    "_step_restore_nm"

register_step "restore.ufw" \
    "Re-enable ufw if it was active before the lockdown" \
    1 "on" \
    "_step_restore_ufw"

register_step "restore.cleanup" \
    "Securely remove saved state files now that the system is restored" \
    1 "on" \
    "_step_restore_cleanup"

# --- Step implementations ------------------------------------------------
# Each function prints what it's about to do (already echoed by the runner),
# then executes the action. On error, the function returns non-zero and the
# runner decides whether to abort or continue based on step metadata.

_step_save_iptables() {
    iptables-save > "$STATE_DIR/iptables-ipv4.rules.tmp" || return 1
    mv "$STATE_DIR/iptables-ipv4.rules.tmp" "$STATE_DIR/iptables-ipv4.rules" || return 1
    ip6tables-save > "$STATE_DIR/iptables-ipv6.rules.tmp" || return 1
    mv "$STATE_DIR/iptables-ipv6.rules.tmp" "$STATE_DIR/iptables-ipv6.rules" || return 1
    log "Saved iptables + ip6tables rules to $STATE_DIR"
}

_step_save_rfkill() {
    rfkill list > "$STATE_DIR/rfkill.txt" || return 1
    log "Saved rfkill list to $STATE_DIR/rfkill.txt"
}

_step_save_ufw() {
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "active" > "$STATE_DIR/ufw-was-active"
        log "ufw is active - pausing it so our iptables rules take precedence"
        ufw disable
    else
        log "ufw not active - nothing to save"
    fi
}

_step_lock_rfkill() {
    rfkill block wifi
    rfkill block bluetooth
    log "WiFi and Bluetooth blocked via rfkill"
}

_step_lock_nm() {
    if command -v nmcli &>/dev/null; then
        nmcli networking off
        log "NetworkManager networking: OFF"
    else
        warn "nmcli not present - skipping NetworkManager step (may be harmless)"
        return 0
    fi
}

_step_firewall_drop_all() {
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP
    iptables -F
    iptables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -F
    ip6tables -X
    log "All chains flushed; default policy = DROP"
}

_step_firewall_allow_lo() {
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    log "Loopback allowed"
}

_step_apps_terminate() {
    local APPS=("obs" "simple-screenrecorder" "kazam" "teamviewer" "anydesk" "slack" "discord" "zoom")
    for app in "${APPS[@]}"; do
        if pgrep -f "$app" >/dev/null; then
            log "Stopping $app..."
            pkill -SIGTERM -f "$app" || true
            sleep 0.5
            pkill -SIGKILL -f "$app" || true
        fi
    done
}

_step_screen_lock() {
    if command -v gdbus &>/dev/null; then
        # Only meaningful in a graphical session. If there's no DBus session
        # bus, gdbus will fail and we just log it - the rest of the lockdown
        # still works.
        if gdbus call --session --dest org.gnome.ScreenSaver \
                --object-path /org/gnome/ScreenSaver \
                --method org.gnome.ScreenSaver.Activate 2>/dev/null; then
            log "Screen locked via GNOME ScreenSaver"
        else
            warn "Could not lock screen (no DBus session?)"
        fi
    else
        log "gdbus not installed - skipping screen lock"
    fi
}

_step_restore_firewall() {
    if [[ -f "$STATE_DIR/iptables-ipv4.rules" ]]; then
        iptables-restore < "$STATE_DIR/iptables-ipv4.rules" || {
            warn "IPv4 restore failed - falling back to ACCEPT-all"
            iptables -P INPUT ACCEPT
            iptables -P OUTPUT ACCEPT
            iptables -P FORWARD ACCEPT
            iptables -F
        }
    else
        warn "No saved IPv4 rules - applying default ACCEPT-all"
        iptables -P INPUT ACCEPT
        iptables -P OUTPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -F
    fi
    if [[ -f "$STATE_DIR/iptables-ipv6.rules" ]]; then
        ip6tables-restore < "$STATE_DIR/iptables-ipv6.rules" || {
            warn "IPv6 restore failed - falling back to ACCEPT-all"
            ip6tables -P INPUT ACCEPT
            ip6tables -P OUTPUT ACCEPT
            ip6tables -P FORWARD ACCEPT
            ip6tables -F
        }
    else
        warn "No saved IPv6 rules - applying default ACCEPT-all"
        ip6tables -P INPUT ACCEPT
        ip6tables -P OUTPUT ACCEPT
        ip6tables -P FORWARD ACCEPT
        ip6tables -F
    fi
    log "Firewall restored"
}

_step_restore_rfkill() {
    rfkill unblock wifi
    rfkill unblock bluetooth
    log "WiFi and Bluetooth unblocked"
}

_step_restore_nm() {
    if command -v nmcli &>/dev/null; then
        nmcli networking on
        log "NetworkManager networking: ON"
    else
        warn "nmcli not present - skipping"
    fi
}

_step_restore_ufw() {
    if [[ -f "$STATE_DIR/ufw-was-active" ]] && command -v ufw &>/dev/null; then
        log "Re-enabling ufw"
        ufw --force enable
    fi
}

_step_restore_cleanup() {
    rm -f "$STATE_DIR/iptables-ipv4.rules" "$STATE_DIR/iptables-ipv6.rules" \
          "$STATE_DIR/rfkill.txt" "$STATE_DIR/ufw-was-active" \
          "$STATE_DIR/iptables-ipv4.rules.tmp" "$STATE_DIR/iptables-ipv6.rules.tmp"
    rm -rf "$STATE_DIR"
    log "State directory removed"
}

# --- Lookup helpers -------------------------------------------------------

step_meta() {
    # step_meta <name> -> prints "desc|priv|phases|fn" or empty if unknown
    local name="$1"
    [[ -n "${STEPS_META[$name]:-}" ]] && echo "${STEPS_META[$name]}"
}

step_in_phase() {
    # step_in_phase <name> <phase> -> 0 if step belongs to phase
    local name="$1" phase="$2" phases
    phases=$(step_meta "$name" | awk -F'|' '{print $3}')
    [[ ",$phases," == *",$phase,"* ]]
}

step_is_privileged() {
    # Returns 0 if the step requires privilege.
    local priv
    priv=$(step_meta "$name" | awk -F'|' '{print $2}')
    [[ "$priv" == "1" ]]
}

steps_in_phase() {
    # Prints the names of all steps that belong to a given phase, in
    # insertion order.
    local phase="$1" name phases
    for name in "${STEPS_ORDER[@]}"; do
        phases=$(step_meta "$name" | awk -F'|' '{print $3}')
        [[ ",$phases," == *",$phase,"* ]] && echo "$name"
    done
}

list_steps() {
    # Pretty-print all registered steps.
    local name meta desc priv phases fn
    printf "%-26s  %-8s  %-22s  %s\n" "STEP" "PRIV" "PHASE" "DESCRIPTION"
    printf -- "-%.0s" {1..80}; echo
    for name in "${STEPS_ORDER[@]}"; do
        meta="${STEPS_META[$name]}"
        desc="${meta%%|*}"
        rest="${meta#*|}"
        priv="${rest%%|*}"
        rest="${rest#*|}"
        phases="${rest%%|*}"
        fn="${rest#*|}"
        printf "%-26s  %-8s  %-22s  %s\n" "$name" "$([[ $priv == 1 ]] && echo yes || echo no)" "$phases" "$desc"
    done
}

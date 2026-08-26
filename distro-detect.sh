#!/bin/bash
# distro-detect.sh - Detect Linux distribution family and available tooling.
#
# Goal: let the rest of the project adapt at runtime to whatever flavor of
# Linux it is actually running on. The original codebase hard-coded
# iptables/iptables-save/nmcli/ufw which is fine on Debian/Ubuntu/Mint but
# quietly breaks on, say, a Debian-derivative that ships nftables by default
# or a fresh install where ufw isn't installed.
#
# We don't refuse to run on a new family - we degrade gracefully: if the
# preferred tool isn't present we fall back to a known alternative, and if
# we can't find anything we report exactly which dependency is missing so the
# user can install it.
#
# Public entry points (after sourcing this file):
#   DISTRO_ID                : e.g. "debian", "ubuntu", "linuxmint", "pop"
#   DISTRO_FAMILY            : one of: debian, rhel, arch, suse, unknown
#   DISTRO_PRETTY            : human-readable name for status output
#   FIREWALL_BACKEND         : iptables | iptables-legacy | nft | none
#   FIREWALL_HELPER          : ufw | firewalld | none  (high-level wrapper)
#   NET_MANAGER              : networkmanager | systemd-networkd | none
#   RADIO_TOOL               : rfkill | none
#   distro_self_check [reqs...] : verify required commands exist; non-zero if not

# Avoid running detection twice if sourced repeatedly.
if [[ -n "${DISTRO_DETECT_LOADED:-}" ]]; then
    return 0 2>/dev/null || true
fi
DISTRO_DETECT_LOADED=1

# --- 1. Distribution identity ---------------------------------------------

DISTRO_ID="unknown"
DISTRO_FAMILY="unknown"
DISTRO_PRETTY="Unknown Linux"

_detect_from_os_release() {
    # /etc/os-release is the modern, cross-distro source of truth. Some
    # stripped containers only have /etc/lsb-release, so we fall back to that.
    local id like pretty
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"
        like="${ID_LIKE:-}"
        pretty="${PRETTY_NAME:-Linux}"
    elif [[ -r /etc/lsb-release ]]; then
        # shellcheck disable=SC1091
        . /etc/lsb-release
        id="${DISTRIB_ID:-unknown}"
        pretty="${DISTRIB_DESCRIPTION:-Linux}"
        like=""
    else
        return 1
    fi

    DISTRO_ID="$id"
    DISTRO_PRETTY="$pretty"

    # Map to a family. ID_LIKE is the canonical hint - e.g. Ubuntu sets
    # ID_LIKE=debian, Mint sets ID_LIKE="ubuntu debian". If ID_LIKE is empty
    # we infer from ID directly so a stripped /etc/os-release still works.
    case " $like " in
        *" debian "*)
            DISTRO_FAMILY="debian" ;;
        *" rhel "*|*" fedora "*|*" centos "*)
            DISTRO_FAMILY="rhel" ;;
        *" arch "*)
            DISTRO_FAMILY="arch" ;;
        *" suse "*)
            DISTRO_FAMILY="suse" ;;
        *)
            case "$id" in
                debian|ubuntu|linuxmint|pop|kali|raspbian|elementary|zorin)
                    DISTRO_FAMILY="debian" ;;
                rhel|centos|fedora|rocky|alma|ol)
                    DISTRO_FAMILY="rhel" ;;
                arch|manjaro|endeavouros|garuda)
                    DISTRO_FAMILY="arch" ;;
                suse|opensuse|sles)
                    DISTRO_FAMILY="suse" ;;
                *)
                    DISTRO_FAMILY="unknown" ;;
            esac
            ;;
    esac
    return 0
}

_detect_from_os_release || DISTRO_PRETTY="Linux (no os-release)"

# --- 2. Firewall backend --------------------------------------------------
#
# Order of preference: nft > iptables-nft > iptables-legacy > ufw > firewalld > none
# We pick the first one that is actually usable, so on a fresh Debian box
# with only ufw installed we still function (using ufw as a wrapper).
FIREWALL_BACKEND="none"
FIREWALL_HELPER="none"

if command -v nft &>/dev/null && nft list ruleset &>/dev/null; then
    FIREWALL_BACKEND="nft"
elif command -v iptables-nft &>/dev/null; then
    FIREWALL_BACKEND="iptables-nft"
elif command -v iptables-legacy &>/dev/null; then
    FIREWALL_BACKEND="iptables-legacy"
elif command -v iptables &>/dev/null; then
    FIREWALL_BACKEND="iptables"
fi

# High-level helpers (only one is expected to be active at a time).
if command -v ufw &>/dev/null; then
    FIREWALL_HELPER="ufw"
elif command -v firewall-cmd &>/dev/null; then
    FIREWALL_HELPER="firewalld"
fi

# --- 3. Network manager ---------------------------------------------------

NET_MANAGER="none"
if command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null \
   || pgrep -x NetworkManager &>/dev/null; then
    NET_MANAGER="networkmanager"
elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    NET_MANAGER="systemd-networkd"
fi

# --- 4. Radio (WiFi / Bluetooth) ------------------------------------------

RADIO_TOOL="none"
if command -v rfkill &>/dev/null; then
    RADIO_TOOL="rfkill"
fi

# --- 5. Self-check ---------------------------------------------------------

distro_self_check() {
    # Pass a list of tool names; prints which are missing and returns
    # non-zero if any are absent. Used by net-off.sh / runner.sh to fail
    # loudly with a useful message instead of barfing on the first missing
    # binary mid-run.
    local missing=()
    for tool in "$@"; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Missing required tools: ${missing[*]}" >&2
        echo "Install them with your distro's package manager, e.g.:" >&2
        case "$DISTRO_FAMILY" in
            debian)
                echo "  sudo apt install ${missing[*]}" >&2 ;;
            rhel)
                echo "  sudo dnf install ${missing[*]}" >&2 ;;
            arch)
                echo "  sudo pacman -S ${missing[*]}" >&2 ;;
            suse)
                echo "  sudo zypper install ${missing[*]}" >&2 ;;
            *)
                echo "  (unknown family - install ${missing[*]} manually)" >&2 ;;
        esac
        return 1
    fi
    return 0
}

distro_summary() {
    cat <<EOF
Distro:        $DISTRO_PRETTY (id=$DISTRO_ID, family=$DISTRO_FAMILY)
Firewall:      backend=$FIREWALL_BACKEND  helper=$FIREWALL_HELPER
Network Mgr:   $NET_MANAGER
Radio Tool:    $RADIO_TOOL
EOF
}

#!/bin/bash
# net-on.sh - Restore the system to its pre-lockdown state.
#
# Backward-compatible entry point that delegates to runner.sh.
#
#   sudo bash net-on.sh              # interactive, step-by-step
#   sudo bash net-on.sh --yes        # old behavior: no prompts
#   sudo bash net-on.sh --dry-run    # preview what restore would do
#   sudo bash net-on.sh --skip restore.ufw

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Decide whether to self-elevate. --help and --dry-run are read-only.
needs_root=1
for a in "$@"; do
    case "$a" in
        -h|--help|-n|--dry-run) needs_root=0 ;;
    esac
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ $needs_root -eq 1 ]]; then
    common_self_elevate "$SELF" "$@" || exit 1
fi

forwarded=("$@")
exec bash "$SCRIPT_DIR/runner.sh" on "${forwarded[@]}"

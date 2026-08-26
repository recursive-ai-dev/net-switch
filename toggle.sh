#!/bin/bash
# toggle.sh - Toggle between lights-on and lights-off states.
#
# Backward-compatible entry point. Picks the right mode and forwards any
# flags (--yes, --dry-run, --verbose, etc.) to the runner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --help and --dry-run don't need root.
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

if is_off; then
    echo "Switching to LIGHTS ON..."
    exec bash "$SCRIPT_DIR/runner.sh" on "$@"
else
    echo "Switching to LIGHTS OFF..."
    exec bash "$SCRIPT_DIR/runner.sh" off "$@"
fi

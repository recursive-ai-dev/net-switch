#!/bin/bash
# net-off.sh - Engage the network lockdown.
#
# Backward-compatible entry point. In the original design this script
# did the whole job inline; now it delegates to runner.sh, which gives
# us step-by-step confirmation, --dry-run, --verbose, --skip, etc. for
# free. The previous behavior is preserved when --yes is passed.
#
#   sudo bash net-off.sh              # interactive, step-by-step
#   sudo bash net-off.sh --yes        # old behavior: no prompts
#   sudo bash net-off.sh --dry-run    # preview the lockdown
#   sudo bash net-off.sh --verbose    # show every step + function name
#   sudo bash net-off.sh --skip apps.terminate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Decide whether we need to self-elevate. Read-only invocations
# (--help, --dry-run as a "see what would happen" preview) shouldn't
# trigger a polkit/sudo prompt, because the user just wants to look
# at the plan. -y/--yes is the canonical "do it for real" signal.
needs_root=1
for a in "$@"; do
    case "$a" in
        -h|--help|-n|--dry-run)
            needs_root=0 ;;
    esac
done

# Re-exec as root via polkit/sudo. The priv layer handles the prompt.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
if [[ $needs_root -eq 1 ]]; then
    common_self_elevate "$SELF" "$@" || exit 1
fi

# Forward to the runner.
forwarded=()
for a in "$@"; do
    forwarded+=("$a")
done
if [[ $needs_root -eq 1 && ${#forwarded[@]} -eq 0 ]]; then
    # No args at all -> show a brief one-liner then drop into the runner
    # interactively. The runner itself will prompt per step.
    echo "net-off.sh: starting staged lockdown (use --yes to skip prompts)"
fi

exec bash "$SCRIPT_DIR/runner.sh" off "${forwarded[@]}"

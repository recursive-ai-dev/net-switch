#!/bin/bash
# Toggle between lights-on and lights-off states.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

if is_off; then
    echo "Switching to LIGHTS ON..."
    bash "$SCRIPT_DIR/net-on.sh"
else
    echo "Switching to LIGHTS OFF..."
    bash "$SCRIPT_DIR/net-off.sh"
fi

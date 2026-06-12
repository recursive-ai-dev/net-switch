#!/bin/bash
# Toggle between lights-on and lights-off instantly

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -d "/tmp/lights-off-state" ]]; then
    bash "$SCRIPT_DIR/net-on.sh"
else
    bash "$SCRIPT_DIR/net-off.sh"
fi

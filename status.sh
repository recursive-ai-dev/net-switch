#!/bin/bash
if [[ -d "/tmp/lights-off-state" ]]; then
    echo "Status: LIGHTS OFF"
    [[ -f /tmp/lights-off-state/log.txt ]] && cat /tmp/lights-off-state/log.txt
else
    echo "Status: LIGHTS ON"
fi

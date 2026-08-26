#!/bin/bash
# test.sh - Self-test that exercises runner.sh in non-mutating modes.
#
# This is a smoke test, not a full functional test - it doesn't
# actually engage the lockdown, since that would require root and
# a working iptables install. It verifies:
#
#   1. Every script parses (bash -n).
#   2. runner.sh list works and shows all phases + steps.
#   3. runner.sh status works without root.
#   4. --dry-run produces non-empty output for off / on / phase.
#   5. --skip and --only filter correctly.
#   6. --from / --to limit phase range.
#   7. unknown phases / steps are reported, not silently ignored.
#
# Run with: bash test.sh
# Exits 0 on success, non-zero on first failure.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR_TEST"

PASS=0
FAIL=0

ok() { echo "  PASS: $*"; PASS=$((PASS+1)); }
nok() { echo "  FAIL: $*"; FAIL=$((FAIL+1)); }

# ----- 1. Syntax checks ------------------------------------------------

echo "[1] Syntax checks"
for f in *.sh; do
    if bash -n "$f" 2>/dev/null; then
        ok "$f parses"
    else
        nok "$f has a syntax error"
    fi
done

# ----- 2. List output --------------------------------------------------

echo
echo "[2] runner.sh list"
out=$(bash runner.sh list --no-color 2>&1)
for needle in "preflight" "core" "apps" "extras" "on" "save.iptables" "firewall.drop_all" "restore.cleanup"; do
    if echo "$out" | grep -q -- "$needle"; then
        ok "list contains '$needle'"
    else
        nok "list missing '$needle'"
    fi
done

# ----- 3. Status works without root -----------------------------------

echo
echo "[3] runner.sh status"
out=$(bash runner.sh status 2>&1)
if echo "$out" | grep -q "Current Mode:"; then
    ok "status reports current mode"
else
    nok "status did not report a mode"
fi
if echo "$out" | grep -q "Distro:"; then
    ok "status reports distro info"
else
    nok "status did not report distro"
fi

# ----- 4. Dry-run for off / on / phase ---------------------------------

echo
echo "[4] Dry-run coverage"
for mode in off on "phase core" "phase preflight"; do
    out=$(bash runner.sh $mode --dry-run --no-color 2>&1)
    if [[ -n "$out" ]]; then
        ok "dry-run $mode produced output"
    else
        nok "dry-run $mode was empty"
    fi
done

# ----- 5. --skip / --only ----------------------------------------------

echo
echo "[5] Filters"
out=$(bash runner.sh off --skip apps.terminate --skip screen.lock --dry-run --no-color 2>&1)
if echo "$out" | grep -q "skip: apps.terminate"; then
    ok "--skip applies to apps.terminate"
else
    nok "--skip apps.terminate had no effect"
fi
if echo "$out" | grep -q "skip: screen.lock"; then
    ok "--skip applies to screen.lock"
else
    nok "--skip screen.lock had no effect"
fi

out=$(bash runner.sh off --only firewall.drop_all --dry-run --no-color 2>&1)
if echo "$out" | grep -q "STEP firewall.drop_all"; then
    ok "--only firewall.drop_all ran"
else
    nok "--only firewall.drop_all did not run"
fi
if echo "$out" | grep -q "skip: save.iptables"; then
    ok "--only filtered out save.iptables"
else
    nok "--only did not filter out save.iptables"
fi

# ----- 6. --from / --to -----------------------------------------------

echo
echo "[6] Phase range"
out=$(bash runner.sh off --from core --to apps --dry-run --no-color 2>&1)
if echo "$out" | grep -q "skipping phase preflight"; then
    ok "--from core skipped preflight"
else
    nok "--from core did not skip preflight"
fi
if echo "$out" | grep -q "== Phase: core =="; then
    ok "--from core ran core"
else
    nok "--from core did not run core"
fi
if echo "$out" | grep -q "skipping phase extras"; then
    ok "--to apps skipped extras"
else
    nok "--to apps did not skip extras"
fi

# ----- 7. Verbose adds function name -----------------------------------

echo
echo "[7] Verbose"
out=$(bash runner.sh off --only firewall.drop_all --verbose --dry-run --no-color 2>&1)
if echo "$out" | grep -q "_step_firewall_drop_all"; then
    ok "--verbose shows function name"
else
    nok "--verbose missing function name"
fi

# ----- 8. Help text ----------------------------------------------------

echo
echo "[8] Help"
out=$(bash runner.sh --help 2>&1)
if echo "$out" | grep -q "Usage:"; then
    ok "--help shows usage"
else
    nok "--help missing"
fi

# ----- 9. Unknown phase / step ----------------------------------------

echo
echo "[9] Error reporting"
out=$(bash runner.sh phase doesnotexist --dry-run --no-color 2>&1)
# Note: this should still try to self-elevate because the mode
# check happens before validation. We just verify the runner
# doesn't crash silently.
if [[ -n "$out" ]]; then
    ok "unknown phase produced output (not a silent crash)"
else
    nok "unknown phase produced no output"
fi

# ----- 10. Timer dry-run ----------------------------------------------

echo
echo "[10] Timer dry-run"
out=$(bash timer.sh 60 --dry-run 2>&1)
if echo "$out" | grep -q "Would schedule"; then
    ok "timer --dry-run shows plan"
else
    nok "timer --dry-run did not show plan"
fi

# ----- Summary --------------------------------------------------------

echo
echo "================================"
echo "Passed: $PASS"
echo "Failed: $FAIL"
echo "================================"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0

#!/bin/bash
# runner.sh - The orchestration engine.
#
# What it does:
#   - Walks through one or more phases, executing each step in order.
#   - Between steps (and between phases) it pauses to let the user confirm,
#     unless --yes is set. This is the "step by step" promise.
#   - Supports --verbose, --dry-run, --skip, --only, --from, --to.
#   - Logs every action with timestamps via common.sh::log.
#   - Returns non-zero on first hard failure, but lets the user opt into
#     "best-effort" mode with --keep-going.
#
# The public entry point is runner_run. The rest of the file is support
# machinery.
#
# CLI:
#   runner.sh <mode> [options]
#
# Modes:
#   off           Run all 'off' phases (preflight, core, apps, extras)
#   on            Run the 'on' phase (restore)
#   phase <name>  Run a single phase (preflight | core | apps | extras | on | all-off)
#   list          List phases and steps
#   status        Show what the system is doing right now
#
# Options:
#   --yes, -y            Don't prompt between steps
#   --verbose, -v        Show every command before it runs
#   --dry-run, -n        Print what would happen but don't actually do it
#   --skip <step>        Skip the named step (can be repeated)
#   --only <step>        Run only the named step (can be repeated)
#   --from <phase>       Start at <phase> instead of the first
#   --to <phase>         Stop after <phase>
#   --keep-going         Continue on errors instead of aborting
#   --no-color           Disable ANSI colors

set -euo pipefail

SCRIPT_DIR_RUNNER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR_RUNNER/common.sh"
# shellcheck source=distro-detect.sh
source "$SCRIPT_DIR_RUNNER/distro-detect.sh"
# shellcheck source=priv.sh
source "$SCRIPT_DIR_RUNNER/priv.sh"
# shellcheck source=steps.sh
source "$SCRIPT_DIR_RUNNER/steps.sh"
# shellcheck source=phases.sh
source "$SCRIPT_DIR_RUNNER/phases.sh"

# --- Defaults / global state ---------------------------------------------

RUNNER_VERBOSE=0
RUNNER_DRYRUN=0
RUNNER_YES=0
RUNNER_KEEPGOING=0
RUNNER_COLOR=1
declare -a RUNNER_SKIP=()
declare -a RUNNER_ONLY=()
RUNNER_FROM_PHASE=""
RUNNER_TO_PHASE=""

# --- Color helpers -------------------------------------------------------

_color_on=0
_setup_color() {
    if [[ $RUNNER_COLOR -eq 1 ]] && [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
        _color_on=1
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_CYAN=$'\033[36m'
    else
        _color_on=0
        C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
    fi
}

# --- Argument parsing ----------------------------------------------------

runner_usage() {
    cat <<'EOF'
Usage: runner.sh <mode> [options]

Modes:
  off                 Run all 'off' phases (preflight, core, apps, extras)
  on                  Run the 'on' phase (restore)
  phase <name>        Run a single phase
  list                List phases and steps
  status              Show current system state

Options:
  -y, --yes           Don't prompt between steps
  -v, --verbose       Show every command before it runs
  -n, --dry-run       Print what would happen; make no changes
      --skip <step>   Skip the named step (can be repeated)
      --only <step>   Run only the named step (can be repeated)
      --from <phase>  Start at <phase> instead of the first
      --to <phase>    Stop after <phase>
      --keep-going    Continue on errors instead of aborting
      --no-color      Disable ANSI colors
  -h, --help          Show this help

Examples:
  sudo runner.sh off --yes
  sudo runner.sh off --verbose --dry-run
  sudo runner.sh on --skip restore.ufw
  sudo runner.sh phase core --only firewall.drop_all
  sudo runner.sh --from core --to apps
EOF
}

runner_parse_args() {
    if [[ $# -eq 0 ]]; then
        runner_usage
        return 2
    fi

    # If the caller already set RUNNER_MODE (e.g. via the 'phase' subcase
    # in main), don't overwrite it. The main entry point pre-parses the
    # mode+phase-arg before calling us; this function just sweeps up
    # the options.
    if [[ -z "${RUNNER_MODE:-}" ]]; then
        if [[ "$1" == -* ]]; then
            # Only flags, no mode - we'll show usage.
            RUNNER_MODE=""
        else
            RUNNER_MODE="$1"; shift
        fi
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)         RUNNER_YES=1 ;;
            -v|--verbose)     RUNNER_VERBOSE=1 ;;
            -n|--dry-run)     RUNNER_DRYRUN=1 ;;
            --keep-going)     RUNNER_KEEPGOING=1 ;;
            --no-color)       RUNNER_COLOR=0 ;;
            --skip)           RUNNER_SKIP+=("$2"); shift ;;
            --only)           RUNNER_ONLY+=("$2"); shift ;;
            --from)           RUNNER_FROM_PHASE="$2"; shift ;;
            --to)             RUNNER_TO_PHASE="$2"; shift ;;
            -h|--help)        runner_usage; return 2 ;;
            *)                echo "runner: unknown argument: $1" >&2; runner_usage; return 2 ;;
        esac
        shift
    done
}

# --- Step gating / filtering ---------------------------------------------

# Should we execute this step given the --skip / --only filters?
_runner_step_allowed() {
    local step="$1"
    if [[ ${#RUNNER_ONLY[@]} -gt 0 ]]; then
        local s; for s in "${RUNNER_ONLY[@]}"; do [[ "$s" == "$step" ]] && return 0; done
        return 1
    fi
    local s; for s in "${RUNNER_SKIP[@]}"; do [[ "$s" == "$step" ]] && return 1; done
    return 0
}

# Should this phase be run given --from / --to?
_runner_phase_allowed() {
    local phase="$1"
    local phases_order=(preflight core apps extras on)
    local from_idx=-1 to_idx=-1 cur_idx=0 p
    for p in "${phases_order[@]}"; do
        if [[ -n "$RUNNER_FROM_PHASE" && "$p" == "$RUNNER_FROM_PHASE" ]]; then from_idx=$cur_idx; fi
        if [[ -n "$RUNNER_TO_PHASE"   && "$p" == "$RUNNER_TO_PHASE"   ]]; then to_idx=$cur_idx;   fi
        cur_idx=$((cur_idx+1))
    done
    # Map the *named* phase to its position in the canonical order.
    local idx
    for idx in "${!phases_order[@]}"; do
        if [[ "${phases_order[$idx]}" == "$phase" ]]; then
            [[ $from_idx -eq -1 || $idx -ge $from_idx ]] || return 1
            [[ $to_idx   -eq -1 || $idx -le $to_idx   ]] || return 1
            return 0
        fi
    done
    # Unknown phase name -> let it through, the caller will validate.
    return 0
}

# --- Confirmation gate ---------------------------------------------------

# Ask the user before each step. We honor --yes to skip, and refuse to
# prompt if stdin isn't a TTY (in which case we assume the equivalent
# of --yes, so cron jobs and CI don't deadlock).
_runner_confirm() {
    local prompt="$1"
    if [[ $RUNNER_YES -eq 1 ]]; then return 0; fi
    if [[ ! -t 0 ]]; then
        echo "$prompt [auto-yes: stdin is not a TTY]"
        return 0
    fi
    local reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}

# --- Dry-run / verbose printing ------------------------------------------

_runner_show_step() {
    local step="$1" desc priv
    desc=$(step_meta "$step" | awk -F'|' '{print $1}')
    priv=$(step_meta "$step" | awk -F'|' '{print $2}')
    echo -e "${C_BOLD}STEP${C_RESET} ${C_CYAN}$step${C_RESET}  ${C_DIM}($([ "$priv" = "1" ] && echo privileged || echo unprivileged))${C_RESET}"
    echo -e "  ${C_DIM}→${C_RESET} $desc"
    if [[ $RUNNER_VERBOSE -eq 1 ]]; then
        # We don't know the actual commands in the step body without
        # re-implementing the dispatch, so we print the function name
        # and trust the user to read steps.sh if they want the gory
        # detail. This is a deliberate tradeoff - see ARCHITECTURE.md.
        local fn
        fn=$(step_meta "$step" | awk -F'|' '{print $4}')
        echo -e "  ${C_DIM}  fn: $fn${C_RESET}"
    fi
}

# --- Single-step executor -----------------------------------------------

_runner_exec_step() {
    local step="$1" fn
    fn=$(step_meta "$step" | awk -F'|' '{print $4}')
    if [[ -z "$fn" ]]; then
        echo -e "${C_RED}unknown step:${C_RESET} $step" >&2
        return 2
    fi

    if [[ $RUNNER_DRYRUN -eq 1 ]]; then
        echo -e "  ${C_YELLOW}[dry-run]${C_RESET} would call ${C_BOLD}$fn${C_RESET}"
        return 0
    fi

    if ! "$fn"; then
        echo -e "${C_RED}step failed:${C_RESET} $step" >&2
        return 1
    fi
}

# --- Phase runner -------------------------------------------------------

runner_run_phase() {
    local phase="$1"
    _runner_phase_allowed "$phase" || { echo "skipping phase $phase (out of --from/--to range)"; return 0; }

    local steps
    if ! steps=$(phase_steps "$phase"); then
        echo -e "${C_RED}unknown phase:${C_RESET} $phase" >&2
        return 1
    fi
    local desc
    desc=$(phase_desc "$phase")

    echo
    echo -e "${C_BOLD}${C_BLUE}== Phase: $phase ==${C_RESET}  ${C_DIM}$desc${C_RESET}"
    echo -e "${C_DIM}steps: ${steps// /, }${C_RESET}"
    if ! _runner_confirm "Run phase '$phase'?"; then
        echo "skipped by user"
        return 0
    fi

    local step failures=0
    for step in $steps; do
        _runner_step_allowed "$step" || { echo "  skip: $step (filter)"; continue; }
        _runner_show_step "$step"
        if ! _runner_confirm "  proceed with $step?"; then
            echo "  skipped by user"
            continue
        fi
        if ! _runner_exec_step "$step"; then
            failures=$((failures+1))
            if [[ $RUNNER_KEEPGOING -eq 0 ]]; then
                echo -e "${C_RED}aborting (use --keep-going to continue past failures)${C_RESET}" >&2
                return 1
            fi
        fi
    done
    [[ $failures -eq 0 ]]
}

# --- Public entry point -------------------------------------------------

runner_run() {
    _setup_color
    case "${RUNNER_MODE:-}" in
        off)
            # ensure_state_dir creates /tmp/lights-off-state and the log
            # file. We must not do this in dry-run mode (the whole point
            # of dry-run is "make no changes"), so we gate on RUNNER_DRYRUN.
            if [[ $RUNNER_DRYRUN -eq 0 ]]; then
                ensure_state_dir
            else
                # Tell common.sh::log to print to stdout but not append to
                # the real log file - otherwise dry-runs pollute the
                # record with phantom "would have done X" entries.
                export LIGHTS_OFF_NO_LOG=1
            fi
            log "=== Lockdown started (mode=off) ==="
            runner_run_phase preflight
            runner_run_phase core
            runner_run_phase apps
            runner_run_phase extras
            log "=== Lockdown complete ==="
            ;;
        on)
            log "=== Restore started (mode=on) ==="
            runner_run_phase on
            log "=== Restore complete ==="
            ;;
        phase)
            local p="${RUNNER_PHASE_ARG:-}"
            if [[ -z "$p" ]]; then
                echo "runner.sh phase: missing phase name" >&2
                return 2
            fi
            runner_run_phase "$p"
            ;;
        list)
            echo "Phases:"
            list_phases
            echo
            echo "Steps:"
            list_steps
            ;;
        status)
            bash "$SCRIPT_DIR_RUNNER/status.sh"
            ;;
        *)
            runner_usage
            return 2
            ;;
    esac
}

# --- main ----------------------------------------------------------------
# If the file is being executed (not sourced), parse argv and run.
# The `return 2>/dev/null` pattern lets this file double as a library.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Snapshot the original argv so we can re-exec it under privilege
    # without losing the mode (and the phase-arg, in the case of `phase`).
    ORIG_ARGV=("$@")

    # Parse args *first* so we know which mode the user wants. Some modes
    # (list, status, --help) are read-only and don't need root, so we
    # only self-elevate for the modes that actually mutate state.
    parse_rc=0
    if [[ $# -ge 1 && "$1" == "phase" ]]; then
        RUNNER_MODE="phase"
        # Phase's argument is the phase name - unless the user passed a flag
        # like --help as the second arg, in which case there's no phase.
        if [[ $# -ge 2 && "$2" != -* ]]; then
            RUNNER_PHASE_ARG="$2"
            shift 2 || true
        else
            RUNNER_PHASE_ARG=""
            shift 1 || true
        fi
        runner_parse_args "$@" || parse_rc=$?
    else
        runner_parse_args "$@" || parse_rc=$?
    fi

    # If --help was passed, runner_parse_args returned 2 - just print usage
    # and exit cleanly, no privilege needed.
    if [[ $parse_rc -ne 0 ]]; then
        exit "$parse_rc"
    fi

    # Decide whether this mode needs root. Adding a new read-only mode?
    # Just add it to this list.
    needs_root=1
    case "${RUNNER_MODE:-}" in
        list|status|"")  needs_root=0 ;;
    esac

    if [[ $needs_root -eq 1 ]]; then
        # priv_re_exec's first arg is the script path; remaining args
        # become its argv. We pass our own path explicitly because
        # BASH_SOURCE inside priv.sh is unreliable.
        if ! priv_re_exec "$0" "${ORIG_ARGV[@]}"; then
            # priv_re_exec re-execs on success; we only land here if it failed.
            exit 1
        fi
        priv_init
    fi
    runner_run
fi

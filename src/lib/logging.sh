#====================================================================
# MODULE: Central Logging, IO Controls, & Installation Core
#====================================================================
# MODULE_VERSION: 2.6
#--------------------------------------------------------------------
# Evaluates and spins up system logging destinations, exports
# shell terminal coloring parameters, and defines crash controls.
#====================================================================
 
# Fail loudly on unset variables and on any failing stage of a pipeline.
# NOTE: we deliberately do NOT use `set -e`. This script relies on
# commands that return non-zero as normal signalling (informant returns
# non-zero when news is unread, `yay -Qua` returns 1 when updates exist,
# grep returns 1 on no match). `set -e` would abort on all of those.
set -uo pipefail
 
VERSION="1.9.0-beta"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-update"
LOGFILE="$STATE_DIR/system-update.log"
INSTALLED_PATH="/usr/local/bin/system-update"
INSTALL_FLAG="$STATE_DIR/.install_prompt_shown"
 
# Rotate the log once it grows past ~2 MB; keep one previous generation.
LOG_MAX_BYTES=2097152
 
# Terminal ANSI Color Escape Mapping Parameters.
# Suppress colors when NO_COLOR is set (https://no-color.org/) or when
# stdout isn't a terminal (piped, redirected, or run from a timer) so
# downstream output never gets littered with raw escape sequences. The
# log file is filtered separately, so this only affects on-screen output.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
    RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
else
    RED="\e[31m"
    GREEN="\e[32m"
    YELLOW="\e[33m"
    BLUE="\e[34m"
    RESET="\e[0m"
fi
 
# Ensure runtime directories exist seamlessly
mkdir -p "$STATE_DIR"
 
# Rotate before opening, so a single run never balloons the active log.
if [[ -f "$LOGFILE" ]]; then
    log_size=$(stat -c '%s' "$LOGFILE" 2>/dev/null || echo 0)
    if [[ "$log_size" -gt "$LOG_MAX_BYTES" ]]; then
        mv -f "$LOGFILE" "$LOGFILE.1" 2>/dev/null || true
    fi
fi
 
if [[ ! -f "$LOGFILE" ]]; then
    touch "$LOGFILE"
    FIRST_RUN=1
else
    FIRST_RUN=0
fi
 
#--------------------------------------------------------------------
# CLEANUP / TRAP HANDLING
#--------------------------------------------------------------------
# A single EXIT trap that restores the terminal AND removes any temp
# paths (files or directories) registered by other code. Append to
# TEMP_PATHS rather than installing another EXIT trap (a second
# `trap ... EXIT` would silently replace this one).
 
TEMP_PATHS=()
SUDO_KEEPALIVE_PID=""
 
cleanup() {
    stty sane 2>/dev/null || true
    # Stop the sudo keep-alive loop, if one was started.
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
    local p
    for p in "${TEMP_PATHS[@]:-}"; do
        [[ -n "$p" && -e "$p" ]] && rm -rf "$p"
    done
}
trap cleanup EXIT
 
#--------------------------------------------------------------------
# LOGGING INTERFACES
#--------------------------------------------------------------------
 
log() {
    echo -e "$1"
    # Strip any ANSI escape sequence before filing the timestamped copy.
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $(echo -e "$1" | sed -E 's|\x1b\[[0-?]*[ -/]*[@-~]||g')" >> "$LOGFILE"
}
 
fail() {
    log "${RED}ERROR: $1${RESET}"
    if command -v notify-send &>/dev/null; then
        notify-send "System Update Failed" "$1"
    fi
    exit 1
}
 
# Clean a raw terminal stream for the log file. Reads stdin, writes a
# readable copy to stdout. Stages (all in one sed, then cat -s):
#   1. Strip every ANSI/CSI escape sequence — colors (incl. 256-color and
#      truecolor with 3+ params), cursor moves (\e[3F, \e[2E …), cursor
#      hide/show (\e[?25l/h), and erases. The general CSI form is
#      ESC '[' <param 0x30-0x3F> <intermediate 0x20-0x2F> <final 0x40-0x7E>;
#      the regex matches all of it. The `|` delimiter avoids escaping '/'.
#   2. `s/\r+$//` — drop the trailing carriage return on each line. A pty
#      (which `script` uses) ends every line with \r\n, so without this
#      the next step would treat normal lines as redraws and erase them.
#   3. `s/.*\r//` — collapse an in-line progress redraw (frames separated
#      by bare \r, no newline) to its final frame.
#   4. Drop the trailing "[####] NN%" progress-bar segment (but never a
#      "[Y/n]"-style prompt, which has no trailing percentage).
# `cat -s` then squeezes runs of blank lines.
filter_log() {
    sed -E 's|\x1b\[[0-?]*[ -/]*[@-~]||g; s/\r+$//; s/.*\r//; s/[[:space:]]*\[[^]]*\][[:space:]]*[0-9]+%?[[:space:]]*$//' \
        | cat -s
}
 
# Non-interactive logged command. Use for tools that don't need a TTY
# (e.g. paccache). Shows full output on screen; a cleaned copy is written
# to the log AFTER the command finishes (a synchronous temp file, not an
# async `tee >(...)` process substitution, which bash does not wait for
# and which can drop output from fast commands). Aborts on a non-zero
# exit from the command itself.
run_logged() {
    stty sane 2>/dev/null || true
    local tmp; tmp=$(mktemp); TEMP_PATHS+=("$tmp")
    bash -c "$1" 2>&1 | tee "$tmp"
    local status=${PIPESTATUS[0]}
    filter_log < "$tmp" >> "$LOGFILE"
    rm -f "$tmp"
    if [[ $status -ne 0 ]]; then
        fail "Command failed: $1 (exit $status)"
    fi
    return 0
}
 
# Interactive logged command. Runs the command inside a pseudo-terminal
# via `script` so colors, progress bars and [Y/n] prompts survive on
# screen. script's clean stdout is captured to a temp file (with `tee`,
# synchronously) and a cleaned copy is appended to the log after the
# command returns. Using /dev/null as script's typescript target keeps
# its "Script started/done" banners out of the capture.
#
# This consolidates the previously copy-pasted `script -eqc ...` blocks
# and actually checks the exit status, so a failed pacman/flatpak run is
# no longer reported as success.
run_interactive_logged() {
    stty sane 2>/dev/null || true
    local tmp; tmp=$(mktemp); TEMP_PATHS+=("$tmp")
    script -eqc "$1" /dev/null | tee "$tmp"
    local status=${PIPESTATUS[0]}
    filter_log < "$tmp" >> "$LOGFILE"
    rm -f "$tmp"
    if [[ $status -ne 0 ]]; then
        fail "Command failed: $1 (exit $status)"
    fi
    return 0
}

# Cache sudo credentials ONCE, up front, and keep them warm for the rest
# of the run. Without this each privileged step prompts separately:
# sudo's default `tty_tickets` scopes a cached password to the terminal
# it was entered on, and `run_interactive_logged` runs commands inside a
# fresh `script` pty (a different terminal), so a credential cached on
# the real terminal wouldn't apply there. Pairing this with
# `run_root_interactive_logged` (which keeps sudo on the real terminal)
# means the whole run needs only a single prompt.
prime_sudo() {
    sudo -v || fail "sudo authentication failed."
    # Refresh the timestamp periodically so a long upgrade can't let it
    # expire and trigger a mid-run prompt. Killed by cleanup() on exit.
    ( while true; do sudo -n true 2>/dev/null; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
}
 
# Like run_interactive_logged, but for commands that need root. The
# command is run WITHOUT a leading sudo; instead `script` itself is run
# under sudo, so the sudo authentication happens on the real terminal
# (reusing prime_sudo's cached credential) rather than inside the pty
# (which would prompt again). The pty still preserves color/progress,
# and the cleaned output is still appended to the log.
#
# Pass "nonfatal" as the second argument to return the command's exit
# status instead of aborting via fail() — used by callers that want to
# handle a failure themselves (e.g. the snapshot step, which prompts to
# continue rather than killing the whole run).
run_root_interactive_logged() {
    stty sane 2>/dev/null || true
    local tmp; tmp=$(mktemp); TEMP_PATHS+=("$tmp")
    sudo script -eqc "$1" /dev/null | tee "$tmp"
    local status=${PIPESTATUS[0]}
    filter_log < "$tmp" >> "$LOGFILE"
    rm -f "$tmp"
    if [[ $status -ne 0 ]]; then
        if [[ "${2:-}" == "nonfatal" ]]; then
            return "$status"
        fi
        fail "Command failed (root): $1 (exit $status)"
    fi
    return 0
}

 
#--------------------------------------------------------------------
# SYSTEM INSTALLATION TASK INTERFACES
#--------------------------------------------------------------------
 
install_script() {
    # Resolve absolute link tracing destination of execution parent
    SCRIPT_SRC=$(realpath "$0")
 
    echo -e "${YELLOW}Installing system-update to $INSTALLED_PATH...${RESET}"
 
    if [[ ! -f $SCRIPT_SRC ]]; then
        echo -e "${RED}Unable to determine script source at $SCRIPT_SRC.${RESET}"
        exit 1
    fi
 
    sudo cp "$SCRIPT_SRC" "$INSTALLED_PATH" || {
        echo -e "${RED}Install failed. Check sudo permissions.${RESET}"
        exit 1
    }
 
    sudo chmod +x "$INSTALLED_PATH"
 
    echo -e "${GREEN}Installed successfully!${RESET}"
    echo "You can now run 'system-update' system-wide."
}

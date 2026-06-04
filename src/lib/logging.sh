#====================================================================
# MODULE: Central Logging, IO Controls, & Installation Core
#====================================================================
# MODULE_VERSION: 1.7
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

VERSION="1.6.0-beta"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-update"
LOGFILE="$STATE_DIR/system-update.log"
INSTALLED_PATH="/usr/local/bin/system-update"
INSTALL_FLAG="$STATE_DIR/.install_prompt_shown"

# Rotate the log once it grows past ~2 MB; keep one previous generation.
LOG_MAX_BYTES=2097152

# Terminal ANSI Color Escape Mapping Parameters
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

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
# directories registered by other modules. Modules must append to
# TEMP_DIRS rather than installing their own EXIT trap (a second
# `trap ... EXIT` would silently replace this one).

TEMP_DIRS=()

cleanup() {
    stty sane 2>/dev/null || true
    local d
    for d in "${TEMP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d"
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
# readable copy to stdout. Three stages:
#   1. Strip every ANSI/CSI escape sequence — colors (incl. 256-color and
#      truecolor with 3+ params), cursor moves (\e[3F, \e[2E …), cursor
#      hide/show (\e[?25l/h), and erases. The general CSI form is
#      ESC '[' <param bytes 0x30-0x3F> <intermediate bytes 0x20-0x2F>
#      <final byte 0x40-0x7E>; the regex below matches all of it. The `|`
#      delimiter avoids escaping the '/' inside the intermediate class.
#   2. Collapse carriage-return redraws to the final frame of each line,
#      so a progress bar that repaints in place becomes one line, not
#      dozens of partial frames.
#   3. Drop the trailing "[####] NN%" progress-bar segment (but never a
#      "[Y/n]"-style prompt, which has no trailing percentage).
# Finally `cat -s` squeezes runs of blank lines.
filter_log() {
    sed -E 's|\x1b\[[0-?]*[ -/]*[@-~]||g' \
        | sed -E 's/.*\r//' \
        | sed -E 's/[[:space:]]*\[[^]]*\][[:space:]]*[0-9]+%?[[:space:]]*$//' \
        | cat -s
}

# Non-interactive logged command. Use for tools that don't need a TTY
# (e.g. paccache). Shows full output on screen; the log copy is cleaned.
# Aborts on a non-zero exit from the command itself (not from tee).
run_logged() {
    stty sane 2>/dev/null || true
    bash -c "$1" 2>&1 | tee >( filter_log >> "$LOGFILE" )
    local status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        fail "Command failed: $1 (exit $status)"
    fi
}

# Interactive logged command. Runs the command inside a pseudo-terminal
# via `script` so colors, progress bars and [Y/n] prompts survive on
# screen, while a cleaned copy is appended to the log. Aborts on a
# non-zero exit from the wrapped command.
#
# This consolidates the previously copy-pasted `script -eqc ... | tee >(...)`
# blocks and — importantly — actually checks the exit status, so a failed
# pacman/flatpak run is no longer reported as success.
run_interactive_logged() {
    stty sane 2>/dev/null || true
    script -eqc "$1" /dev/null | tee >( filter_log >> "$LOGFILE" )
    local status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        fail "Command failed: $1 (exit $status)"
    fi
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

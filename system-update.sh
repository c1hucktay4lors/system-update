#!/bin/bash

########################################
# Arch Linux System Update Script
#
# Created with assistance from AI (ChatGPT & Gemini)
# Maintained and customized by Max
# for personal system automation and learning purposes.
#
# Version: v1.5.2
#
# Changelog:
# v0.1   - Initial release:
#          - Basic pacman + flatpak update functionality
# v0.2   - Simplification:
#          - Removed AUR helper logic
# v0.3   - Cache management:
#          - Replaced pacman -Sc with paccache -rk2
# v0.4   - Output improvements:
#          - Improved verbosity and logging
# v0.5   - Flatpak fixes:
#          - Fixed Flatpak interactivity issues
# v0.6   - Logging overhaul:
#          - Added TTY-safe logging via script
# v0.7   - System snapshot:
#          - Added optional fastfetch system snapshot
# v0.8   - Feature flags:
#          - Added --fetch flag
# v0.9   - Simulation mode:
#          - Added --dry-run mode
# v1.0   - Stable release:
#          - Finalized interactive + logged script
# v1.1   - CLI interface:
#          - Introduced CLI flags (-d, -f, -p, -F, -c, -h)
# v1.2   - CLI improvements:
#          - Added combinable flags (e.g. -pFf)
#          - Improved overall CLI behavior
# v1.3   - Major polish:
#          - Fixed paccache duplication (rk2 only)
#          - Improved dry-run UX with yellow banners
#          - Renamed script to system-update
#          - Moved completion banner before snapshot
#          - Added personalized attribution (Max)
# v1.3.1 - Help menu polish:
#          - Centered header text in help output
#          - Added personal humor line in help banner
# v1.3.2 - Kernel module overhaul:
#          - Added robust kernel comparison module
#          - Fixed false "reboot required" detection
#          - Normalized pacman vs uname kernel formats
#          - Added support for arch/zen/lts kernel variants
#          - Resolved trailing "-zen" uname mismatch issue
#          - Improved edge-case handling for missing kernel packages
# v1.3.3 - Optional AUR support:
#          - Added -a flag for AUR updates (yay)
#          - Excluded AUR updates from default runs
#          - Integrated AUR support with dry-run and logging
# v1.3.4 - Filesystem improvements:
#          - Moved logs to XDG state directory
#          - Added first-run log initialization
#          - Improved log file handling and persistence
# v1.3.5 - Install workflow improvements:
#          - Added optional system-wide install support
#          - Added first-run install prompt workflow
#          - Added install state tracking to prevent repeat prompts
#          - Improved overall script portability
# v1.3.6 - Kernel module simplification:
#          - Removed reboot-required detection logic
#          - Simplified kernel comparison workflow
#          - Replaced normalization-based checks with direct reporting
#          - Fixed regression causing non-kernel linux packages
#            to appear in installed kernel output
#          - Improved installed kernel output formatting
#
#
# v1.4.0   - spit through Gemini for a second pair of AI "eyes".
#(Gemini)  - Switched to 'script' for Flatpak and Pacman to maintain
#            interactivity and progress bars while logging.
#          - Implemented 'sudo -v' to prevent password prompt confusion.
#          - Updated to modern Bash [[ ]] testing and realpath resolution.
########################################
VERSION="1.5.2"

########################################
# Paths/Logging setup
########################################

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-update"
LOGFILE="$STATE_DIR/system-update.log"
INSTALLED_PATH="/usr/local/bin/system-update"
INSTALL_FLAG="$STATE_DIR/.install_prompt_shown"

# --- ADD THESE FOR GITHUB UPDATES ---
GITHUB_USER="c1hucktay4lors"       # Change to your GitHub username
GITHUB_REPO="system-update"     # Change to your repository name
ASSET_NAME="system-update.sh"   # The exact file name in your repo

mkdir -p "$STATE_DIR"

if [[ ! -f $LOGFILE ]]; then
    touch "$LOGFILE"
    FIRST_RUN=1
else
    FIRST_RUN=0
fi

trap 'stty sane 2>/dev/null' EXIT

########################################
# Colors
########################################

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
RESET="\e[0m"

########################################
# Flags
########################################

RUN_PACMAN=0
RUN_FLATPAK=0
RUN_CACHE=0
RUN_AUR=0
SHOW_FETCH=0
DRY_RUN=0
RUN_INSTALL=0
RUN_SCRIPT_UPDATE=0 

########################################
# Help Menu
########################################

show_help() {
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

    center_text() {
        local text="$1"
        local padding=$(( (TERM_WIDTH - ${#text}) / 2 ))
        printf "%*s%s\n" "$padding" "" "$text"
    }

    echo
    center_text "System Update Script (v$VERSION)"
    center_text "Created by Max"
    center_text "(and ChatGPT/Gemini, because I didn't want to manually type out 3-4 commands to update my system)"
    echo
    echo
    echo "Log file: ~/.local/state/system-update/system-update.log"
    echo
    echo "Usage: system-update [options]"
    echo
    echo "Selection flags (combinable):"
    echo "  -p        Updates just pacman packages using 'pacman' command"
    echo "            pre-configured to do full system upgrade"
    echo
    echo "  -F        Updates just flatpak packages using 'flatpak' command"
    echo "            pre-configured to update all packages"
    echo
    echo "  -c        Runs cache cleanup using 'paccache' command"
    echo "            pre-configured to keep the last 2 versions of installed packages"
    echo
    echo "  -a        Updates AUR packages using 'yay' (optional)"
    echo "            pre-configured to update AUR packages only (does not by default)"
    echo
    echo "  -d        Dry-run"
    echo "            Shows what packages would be updated"
    echo
    echo "  -f        Shows system snapshot at the end of updates using 'fastfetch' (if installed)"
    echo
    echo
    echo "  -i        Installs/updates script in /usr/local/bin so it can be called system-wide"
    echo
    echo
    echo "  -u        Manually checks for and installs script updates"
    echo
    echo
    echo "  -h        Shows this help menu"
    echo
    echo
    echo "Examples:"
    echo "  system-update           # run standard (equivalent to -pFc)"
    echo "  system-update -pF       # pacman + flatpak"
    echo "  system-update -pFf      # pacman + flatpak + fetch"
    echo "  system-update -pFca     # pacman + flatpak + cache + AUR"
    echo "  system-update -d        # dry-run"
    echo "  system-update -u        # manual update"
}

########################################
# Argument parsing
########################################

while getopts ":dfpFachiu" opt; do
    case $opt in
        d) DRY_RUN=1 ;;
        f) SHOW_FETCH=1 ;;
        p) RUN_PACMAN=1 ;;
        F) RUN_FLATPAK=1 ;;
        c) RUN_CACHE=1 ;;
        a) RUN_AUR=1 ;;
        i) RUN_INSTALL=1 ;;
        u) RUN_SCRIPT_UPDATE=1 ;;  # Captures the manual update flag
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

# Default behavior if no specific modules are selected
if [[ $RUN_PACMAN -eq 0 && $RUN_FLATPAK -eq 0 && $RUN_CACHE -eq 0 && $RUN_INSTALL -eq 0 ]]; then
    RUN_PACMAN=1
    RUN_FLATPAK=1
    RUN_CACHE=1
fi

########################################
# Logging & Utility functions
########################################

log() {
    echo -e "$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOGFILE"
}

fail() {
    log "${RED}ERROR: $1${RESET}"
    if command -v notify-send &>/dev/null; then
        notify-send "System Update Failed" "$1"
    fi
    exit 1
}

run_logged() {
    stty sane 2>/dev/null
    bash -c "$1" 2>&1 | tee -a "$LOGFILE"

    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        fail "Command failed: $1"
    fi
}

install_script() {
    # Resolve absolute path of the current file
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

check_for_script_updates() {
    local force_check=$1  # 1 if triggered manually via -u, 0 otherwise

    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        if [[ $force_check -eq 1 ]]; then
            fail "Missing dependencies! Manual script updates require both 'curl' and 'jq'."
        fi
        return
    fi

    if [[ -z "$GITHUB_UPDATE_TOKEN" ]]; then
        if [[ $force_check -eq 1 ]]; then
            fail "\$GITHUB_UPDATE_TOKEN environment variable is not set. Cannot authenticate."
        fi
        log "${YELLOW}Skipping update check: \$GITHUB_UPDATE_TOKEN not found.${RESET}"
        return
    fi

    log "${BLUE}Querying GitHub API for latest release assets...${RESET}"

    # Target the API endpoint for the latest release metadata
    local API_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/releases/latest"
    
    # Fetch release JSON securely using token
    local RELEASE_JSON
    RELEASE_JSON=$(curl -sL -H "Authorization: token $GITHUB_UPDATE_TOKEN" \
                           -H "Accept: application/vnd.github+json" "$API_URL")

    # Parse the release version tag (e.g., "v1.5.0") and clean up any preceding 'v'
    local REMOTE_TAG
    REMOTE_TAG=$(echo "$RELEASE_JSON" | jq -r '.tag_name' 2>/dev/null)
    local REMOTE_VERSION="${REMOTE_TAG#v}" # strips 'v' if present

    if [[ -z "$REMOTE_VERSION" || "$REMOTE_VERSION" == "null" ]]; then
        log "${YELLOW}Could not resolve latest release via API. (Is a release published?).${RESET}"
        return
    fi

    # Compare versions using natural version sort layout
    if [[ "$VERSION" != "$REMOTE_VERSION" ]] && [[ "$(printf '%s\n%s' "$VERSION" "$REMOTE_VERSION" | sort -V | head -n 1)" == "$VERSION" ]]; then
        echo
        echo -e "${YELLOW}[!] A new official release is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        read -r -p "Would you like to upgrade the script system-wide? (y/N): " update_confirm < /dev/tty
        
        if [[ "$update_confirm" =~ ^[Yy]$ ]]; then
            # Use jq to sift through assets and find the one matching our target file name
            local ASSET_ID
            ASSET_ID=$(echo "$RELEASE_JSON" | jq -r ".assets[] | select(.name==\"$ASSET_NAME\") | .id" 2>/dev/null)

            if [[ -z "$ASSET_ID" || "$ASSET_ID" == "null" ]]; then
                fail "Found release v$REMOTE_VERSION, but couldn't find an attached asset named '$ASSET_NAME'."
            fi

            log "${YELLOW}Downloading release asset ID: $ASSET_ID securely...${RESET}"
            
            local TARGET_PATH="$INSTALLED_PATH"
            if [[ ! -f $INSTALLED_PATH ]]; then
                TARGET_PATH=$(realpath "$0")
            fi

            # Note: Downloading a raw private asset requires hitting the /assets endpoint 
            # with an 'Accept: application/octet-stream' header
            local ASSET_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/releases/assets/$ASSET_ID"
            
            if sudo curl -sL -H "Authorization: token $GITHUB_UPDATE_TOKEN" \
                            -H "Accept: application/octet-stream" \
                            "$ASSET_URL" -o "$TARGET_PATH"; then
                sudo chmod +x "$TARGET_PATH"
                log "${GREEN}Script successfully updated to release v$REMOTE_VERSION! Please rerun your command.${RESET}"
                exit 0
            else
                fail "Failed to deploy release asset payload to $TARGET_PATH"
            fi
        fi
    else
        if [[ $force_check -eq 1 ]]; then
            log "${GREEN}You are already on the absolute latest official release (v$VERSION).${RESET}"
        fi
    fi
}
}

#########################################
# Execution Start
########################################

# Route 1: Handle Manual Updater Flag (-u) exclusively
if [[ $RUN_SCRIPT_UPDATE -eq 1 ]]; then
    log "${BLUE}===== Manual Script Updater Module =====${RESET}"
    check_for_script_updates 1  # Passed 1 to signal a manual forced request
    exit 0
fi

# Route 2: Handle Routine System Diagnostics & Sweeps
if [[ $DRY_RUN -eq 1 ]]; then
    log "${YELLOW}  ===== Starting DRY RUN (v$VERSION) =====${RESET}"
else
    log "${BLUE}    ===== System Update (v$VERSION) =====${RESET}"
    
    # Run the update check silently in the background of standard update tasks
    check_for_script_updates 0  # Passed 0 to keep checks subtle and non-blocking
fi

if [[ $FIRST_RUN -eq 1 ]]; then
    log "${BLUE}First run detected — log initialized${RESET}"
fi

if [[ $RUN_INSTALL -eq 1 ]]; then
    install_script
    exit 0
fi

########################################
# Install check (First run prompt)
########################################

if [[ ! -f $INSTALLED_PATH && ! -f $INSTALL_FLAG ]]; then
    log "${YELLOW}system-update is not installed system-wide.${RESET}"
    echo
    read -r -p "Would you like to install it to $INSTALLED_PATH? (y/N): " install_confirm < /dev/tty

    if [[ "$install_confirm" =~ ^[Yy]$ ]]; then
        install_script
        touch "$INSTALL_FLAG"
        echo
        exit 0
    else
        log "${BLUE}Skipping install. You can run with -i later.${RESET}"
        touch "$INSTALL_FLAG"
    fi
fi

########################################
# Pacman Module
########################################

if [[ $RUN_PACMAN -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Pacman changes...${RESET}"
        # We use --color=always so the dry-run log looks nice too
        sudo pacman -Syu --print --color=always | tee -a "$LOGFILE"
    else
        log "${YELLOW}Updating system packages...${RESET}"

        # 1. We call sudo -v (validate) first to ensure the password
        # is handled by your real terminal before 'script' starts.
        sudo -v

        # 2. We use script to trick pacman into showing progress bars.
        # 3. We pass --color=always to ensure the bars and text are colored.
        script -eqc "sudo pacman -Syu --color=always" /dev/null | tee -a "$LOGFILE"

        log "${GREEN}System packages updated${RESET}"
    fi
fi

########################################
# AUR Module (yay)
########################################

if [[ $RUN_AUR -eq 1 ]] && command -v yay &>/dev/null; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: AUR updates available...${RESET}"
        run_logged "yay -Qua"
    else
        log "${YELLOW}Updating AUR packages...${RESET}"
        run_logged "yay -Sua"
        log "${GREEN}AUR packages updated${RESET}"
    fi
fi

########################################
# Flatpak Module
########################################

if [[ $RUN_FLATPAK -eq 1 ]] && command -v flatpak &>/dev/null; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Flatpak available updates...${RESET}"
        flatpak remote-ls --updates | tee -a "$LOGFILE"
    else
        log "${YELLOW}Updating Flatpak apps...${RESET}"

        # -e: Returns the exit code of the child process
        # -q: Quiet mode (don't log the 'Script started' messages)
        # -c: The command to run
        # /dev/null: We send the 'timing' data to null,
        # while 'tee' handles the actual log file.
        script -eqc "flatpak update" /dev/null | tee -a "$LOGFILE"

        log "${YELLOW}Removing unused Flatpak runtimes...${RESET}"
        script -eqc "flatpak uninstall --unused" /dev/null | tee -a "$LOGFILE"
    fi
fi

########################################
# Cache Cleanup Module
########################################

if [[ $RUN_CACHE -eq 1 ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Skipping cache cleanup${RESET}"
    else
        log "${YELLOW}Cleaning package cache (keeping 2 versions)...${RESET}"
        run_logged "sudo paccache -rk2"
    fi
fi

########################################
# Kernel Status Module
########################################

check_kernel_status() {
    echo
    log "${BLUE}    ===== Kernel Status =====${RESET}"

    RUNNING_KERNEL="$(uname -r)"
    log "  Running Kernel : $RUNNING_KERNEL"

    # Filter for core kernel packages
    INSTALLED_KERNELS="$(pacman -Qq | grep -E '^linux(-(zen|lts|hardened|rt))?$')"

    if [[ -z $INSTALLED_KERNELS ]]; then
        log "  Installed Kernels : ${YELLOW}None detected via pacman${RESET}"
        return
    fi

    log "  Installed Kernel Packages:"
    while read -r kernel_pkg; do
        kernel_version=$(pacman -Q "$kernel_pkg" | awk '{print $2}')
        log "$(printf '    %-12s : %s' "$kernel_pkg" "$kernel_version")"
    done <<< "$INSTALLED_KERNELS"
}

check_kernel_status

########################################
# Finalize
########################################

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    log "${GREEN}Dry-run complete${RESET}"
    echo
    log "${YELLOW}  ===== Dry Run Finished =====${RESET}"
else
    echo
    log "${GREEN}System update complete${RESET}"
    echo
    log "${BLUE}    ===== System Update Finished =====${RESET}"
fi

########################################
# Fastfetch Module
########################################

if [[ $SHOW_FETCH -eq 1 ]]; then
    command -v fastfetch &>/dev/null && fastfetch
fi

########################################
# Exit Sequence
########################################

stty sane 2>/dev/null

printf "\nPress any key to exit..."

stty -echo
IFS= read -r -n 1 _
stty echo

printf "\n"

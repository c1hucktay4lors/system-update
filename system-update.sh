#!/bin/bash

########################################
# Arch Linux System Update Script
#
# Created with assistance from AI (ChatGPT & Gemini)
# Maintained and customized by Max
# for personal system automation and learning purposes.
########################################

VERSION="1.5.5-exp"

########################################
# Paths/Logging setup
########################################

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-update"
LOGFILE="$STATE_DIR/system-update.log"
INSTALLED_PATH="/usr/local/bin/system-update"
INSTALL_FLAG="$STATE_DIR/.install_prompt_shown"
GITHUB_USER="c1hucktay4lors"
GITHUB_REPO="system-update" 
ASSET_NAME="system-update.sh"

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

    log "${BLUE}Querying GitHub API for latest release or pre-release assets...${RESET}"

    # Target the general releases endpoint (returns a chronological list of ALL releases)
    local API_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/releases"
    
    # Fetch the full releases array JSON securely using token
    local RELEASES_JSON
    RELEASES_JSON=$(curl -sL -H "Authorization: token $GITHUB_UPDATE_TOKEN" \
                             -H "Accept: application/vnd.github+json" "$API_URL")

    # Use jq to extract the tag_name from the absolute freshest release at index [0]
    local REMOTE_TAG
    REMOTE_TAG=$(echo "$RELEASES_JSON" | jq -r '.[0].tag_name' 2>/dev/null)
    local REMOTE_VERSION="${REMOTE_TAG#v}" # strips 'v' if present

    if [[ -z "$REMOTE_VERSION" || "$REMOTE_VERSION" == "null" ]]; then
        log "${YELLOW}Could not resolve any releases via API. (Is a release published?).${RESET}"
        return
    fi

    # Check if that freshest release happens to be flagged as a pre-release (for visual feedback)
    local IS_PRERELEASE
    IS_PRERELEASE=$(echo "$RELEASES_JSON" | jq -r '.[0].prerelease' 2>/dev/null)

    # Compare versions using natural version sort layout
    if [[ "$VERSION" != "$REMOTE_VERSION" ]] && [[ "$(printf '%s\n%s' "$VERSION" "$REMOTE_VERSION" | sort -V | head -n 1)" == "$VERSION" ]]; then
        echo
        if [[ "$IS_PRERELEASE" == "true" ]]; then
            echo -e "${YELLOW}[!] A new PRE-RELEASE is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        else
            echo -e "${YELLOW}[!] A new official release is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        fi
        
        read -r -p "Would you like to upgrade the script system-wide? (y/N): " update_confirm < /dev/tty
        
        if [[ "$update_confirm" =~ ^[Yy]$ ]]; then
            # Extract the asset ID matching our target name from that top release index [0]
            local ASSET_ID
            ASSET_ID=$(echo "$RELEASES_JSON" | jq -r ".[0].assets[] | select(.name==\"$ASSET_NAME\") | .id" 2>/dev/null)

            if [[ -z "$ASSET_ID" || "$ASSET_ID" == "null" ]]; then
                fail "Found release v$REMOTE_VERSION, but couldn't find an attached asset named '$ASSET_NAME'."
            fi

            log "${YELLOW}Downloading release asset ID: $ASSET_ID securely...${RESET}"
            
            local TARGET_PATH="$INSTALLED_PATH"
            if [[ ! -f $INSTALLED_PATH ]]; then
                TARGET_PATH=$(realpath "$0")
            fi

            local ASSET_URL="https://api.github.com/repos/$GITHUB_USER/$GITHUB_REPO/releases/assets/$ASSET_ID"
            
            if sudo curl -sL -H "Authorization: token $GITHUB_UPDATE_TOKEN" \
                            -H "Accept: application/octet-stream" \
                            "$ASSET_URL" -o "$TARGET_PATH"; then
                sudo chmod +x "$TARGET_PATH"
                log "${GREEN}Script successfully updated to v$REMOTE_VERSION! Please rerun your command.${RESET}"
                exit 0
            else
                fail "Failed to deploy release asset payload to $TARGET_PATH"
            fi
        fi
    else
        if [[ $force_check -eq 1 ]]; then
            log "${GREEN}You are already on the absolute latest release/pre-release (v$VERSION).${RESET}"
        fi
    fi
}

check_arch_news() {
    # If informant isn't installed, skip cleanly
    if ! command -v informant &>/dev/null; then
        log "${YELLOW}Note: 'informant' is not installed. Skipping Arch Linux news validation.${RESET}"
        return
     fi

    log "${BLUE}Checking official Arch Linux news feed for urgent interventions...${RESET}"
    
    # 'informant check' returns a non-zero exit code if there is unread news
    if ! informant check &>/dev/null; then
        echo
        log "${RED}[!] CRITICAL ARCH NEWS DETECTED [!]${RESET}"
        log "${YELLOW}Arch Linux has published mandatory manual intervention notices.${RESET}"
        echo -e "--------------------------------------------------------"
        
        # Output the unread news headlines directly to the terminal
        informant list --unread
        
        echo -e "--------------------------------------------------------"
        echo -e "${YELLOW}It is highly recommended to read these before updating.${RESET}"
        read -r -p "Have you reviewed the news requirements and want to proceed? (y/N): " news_confirm < /dev/tty
        
        if [[ ! "$news_confirm" =~ ^[Yy]$ ]]; then
            log "${RED}Update aborted by user to review Arch News instructions.${RESET}"
            exit 1
        else
            log "${YELLOW}News acknowledged. Proceeding with update sequence...${RESET}"
            # Mark news as read so it doesn't prompt again next time
            sudo informant read --all &>/dev/null
        fi
    else
        log "${GREEN}No unread critical Arch news found.${RESET}"
    fi
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
    
    # 1. First, check if the updater utility itself needs a release sync
    check_for_script_updates 0
    
    # 2. Next, check the Arch News Feed before touching system packages
    check_arch_news
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

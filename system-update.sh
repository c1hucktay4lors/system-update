#!/bin/bash

# --- MODULE: logging.sh ---
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
    # Strip raw terminal colors via sed before filing out to logs
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $(echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOGFILE"
}

fail() {
    log "${RED}ERROR: $1${RESET}"
    if command -v notify-send &>/dev/null; then
        notify-send "System Update Failed" "$1"
    fi
    exit 1
}

# Non-interactive logged command. Use for tools that don't need a TTY
# (e.g. paccache). Captures combined output to the log and aborts on
# a non-zero exit from the command itself (not from tee).
run_logged() {
    stty sane 2>/dev/null || true
    bash -c "$1" 2>&1 | tee -a "$LOGFILE"
    local status=${PIPESTATUS[0]}
    if [[ $status -ne 0 ]]; then
        fail "Command failed: $1 (exit $status)"
    fi
}

# Interactive logged command. Runs the command inside a pseudo-terminal
# via `script` so colors, progress bars and [Y/n] prompts survive, while
# a color-stripped copy is appended to the log. Aborts on a non-zero
# exit from the wrapped command.
#
# This consolidates the previously copy-pasted `script -eqc ... | tee >(...)`
# blocks and — importantly — actually checks the exit status, so a failed
# pacman/flatpak run is no longer reported as success.
run_interactive_logged() {
    stty sane 2>/dev/null || true
    script -eqc "$1" /dev/null | tee >(
        sed -E 's/\r+/\n/g' | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" >> "$LOGFILE"
    )
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

# --- MODULE: archnews.sh ---
#====================================================================
# MODULE: Arch Linux News Validation Feed
#====================================================================
# MODULE_VERSION: 1.0
#--------------------------------------------------------------------
# Intercepts unread news items that require manual intervention
# before package transaction frameworks are executed.
#====================================================================

check_arch_news() {
    log "${BLUE}Checking official Arch Linux news feed for urgent interventions...${RESET}"

    # Informant returns a non-zero exit code if unread articles exist
    if ! informant check &>/dev/null; then
        echo
        log "${RED}[!] CRITICAL ARCH NEWS DETECTED [!]${RESET}"
        log "${YELLOW}Arch Linux has published mandatory manual intervention notices.${RESET}"
        echo -e "--------------------------------------------------------"

        # Query and pipe the raw headlines out to the active terminal
        informant list --unread

        echo -e "--------------------------------------------------------"
        echo -e "${YELLOW}It is highly recommended to read these before updating.${RESET}"
        read -r -p "Have you reviewed the news requirements and want to proceed? (y/N): " news_confirm < /dev/tty

        # Halt entire system execution loop if user chooses to abort
        if [[ ! "$news_confirm" =~ ^[Yy]$ ]]; then
            log "${RED}Update aborted by user to review Arch News instructions.${RESET}"
            exit 1
        else
            log "${YELLOW}News acknowledged. Proceeding with update sequence...${RESET}"
            
            # Acknowledge all active postings to unlock future execution
            sudo informant read --all &>/dev/null
        fi
    else
        log "${GREEN}No unread critical Arch news found.${RESET}"
    fi
}

# --- MODULE: aur.sh ---
#====================================================================
# MODULE: Arch User Repository (AUR) Packaging Engine
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Tracks and updates AUR builds via 'yay'. The update path now runs
# inside a PTY (like pacman/flatpak) so yay's interactive diff/build
# prompts and colours survive, and its exit status is checked.
#====================================================================

run_aur_module() {
    if [[ $RUN_AUR -ne 1 ]]; then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: AUR updates available...${RESET}"

        # yay -Qua returns 0 when no updates exist and 1 when updates
        # ARE found; both are success. Only >1 is a real error, so this
        # path is handled manually rather than via run_interactive_logged.
        stty sane 2>/dev/null || true
        yay -Qua 2>&1 | tee -a "$LOGFILE"
        local yay_status=${PIPESTATUS[0]}
        if [[ $yay_status -gt 1 ]]; then
            fail "Command failed: yay -Qua (exit $yay_status)"
        fi
        return 0
    fi

    log "${YELLOW}Updating AUR packages...${RESET}"
    run_interactive_logged "yay -Sua"
    log "${GREEN}AUR packages updated${RESET}"
}

# --- MODULE: dependencies.sh ---
#====================================================================
# MODULE: Environment Dependency Gate
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Audits the host for every required binary on EVERY run. Because the
# rest of the script deliberately omits per-command `command -v` guards,
# this gate is what guarantees those binaries exist. Caching the result
# (the old behaviour) broke that guarantee: a dependency removed after
# the first run would slip past the gate and crash an unguarded module.
# A `command -v` sweep is microseconds, so it runs every time.
#====================================================================

check_and_install_dependencies() {
    # 1. Define standard official repository dependencies
    local NATIVE_DEPS=(
        "bash" "sudo" "curl" "jq" "flatpak" "fastfetch"
        "paccache" "realpath" "script" "tput" "git"
    )

    local MISSING_DEPS=()
    local need_yay=0
    local need_informant=0

    log "${BLUE}Auditing system environment for required dependencies...${RESET}"

    get_package_name() {
        case "$1" in
            "paccache")  echo "pacman-contrib" ;;
            "realpath")  echo "coreutils" ;;
            "script")    echo "util-linux" ;;
            "tput")      echo "ncurses" ;;
            *)           echo "$1" ;;
        esac
    }

    # Inventory missing native applications (dedup via associative array)
    local -A seen=()
    local cmd pkg
    for cmd in "${NATIVE_DEPS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg=$(get_package_name "$cmd")
            if [[ -z "${seen[$pkg]:-}" ]]; then
                seen[$pkg]=1
                MISSING_DEPS+=("$pkg")
            fi
        fi
    done

    # Check specialized AUR dependencies
    command -v yay &>/dev/null       || need_yay=1
    command -v informant &>/dev/null || need_informant=1

    # Nothing missing: clean pass.
    if [[ ${#MISSING_DEPS[@]} -eq 0 && $need_yay -eq 0 && $need_informant -eq 0 ]]; then
        return 0
    fi

    # Report what's missing.
    clear
    echo -e "\n${YELLOW}[!] Unresolved core binaries discovered in environment:${RESET}"
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        echo -e "    -> Official Repos: ${MISSING_DEPS[*]}"
    fi
    local aur_list=()
    [[ $need_yay -eq 1 ]] && aur_list+=("yay")
    [[ $need_informant -eq 1 ]] && aur_list+=("informant")
    if [[ ${#aur_list[@]} -gt 0 ]]; then
        echo -e "    -> Arch User Repo: ${aur_list[*]}"
    fi
    echo

    # A dry-run must never mutate the system. Report and continue;
    # the read-only dry-run commands will simply note if a tool is absent.
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: dependencies are missing. A real run would offer to install them. Continuing without changes.${RESET}"
        return 0
    fi

    # Halt execution and prompt user for patching
    read -r -p "Would you like to automatically install these dependencies? (yes/No): " dep_confirm < /dev/tty
    if [[ "$dep_confirm" != "yes" ]]; then
        fail "Environment validation rejected. Please manually install the missing dependencies and try again."
    fi

    # Bootstrap missing native packages
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        log "${YELLOW}Installing missing official system packages...${RESET}"
        if command -v sudo &>/dev/null; then
            sudo pacman -Sy --needed --noconfirm "${MISSING_DEPS[@]}" || fail "Failed to install official dependencies."
        else
            pacman -Sy --needed --noconfirm "${MISSING_DEPS[@]}" || fail "Failed to install official dependencies as root."
        fi
    fi

    # Handle AUR builds
    if [[ $need_yay -eq 1 || $need_informant -eq 1 ]]; then
        if ! pacman -Qi base-devel &>/dev/null; then
            log "${YELLOW}Installing base-devel toolchain...${RESET}"
            sudo pacman -S --needed --noconfirm base-devel || fail "Failed to install base-devel."
        fi

        local temp_dir; temp_dir=$(mktemp -d)
        # Register for cleanup via the shared EXIT trap instead of
        # installing our own (which would clobber the terminal-restore trap).
        TEMP_DIRS+=("$temp_dir")

        if [[ $need_yay -eq 1 ]]; then
            log "${YELLOW}Bootstrapping 'yay' from the AUR...${RESET}"
            git clone https://aur.archlinux.org/yay.git "$temp_dir/yay" || fail "Failed to clone yay."
            ( cd "$temp_dir/yay" && makepkg -si --noconfirm ) || fail "Build failure during 'yay' installation."
        fi

        if [[ $need_informant -eq 1 ]]; then
            log "${YELLOW}Installing 'informant' via yay...${RESET}"
            yay -S --noconfirm informant || fail "Failed to install 'informant' via yay."
        fi
    fi

    log "${GREEN}Dependencies successfully installed! Resuming standard operations...${RESET}\n"
    sleep 2
}

# --- MODULE: flatpak.sh ---
#====================================================================
# MODULE: Flatpak Sandboxed Application Updater
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Updates Flatpak applications and prunes unused runtimes. Update steps
# run through the shared PTY-logging helper so failures are caught and
# reported instead of being masked as success.
#====================================================================

run_flatpak_module() {
    if [[ $RUN_FLATPAK -ne 1 ]]; then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Flatpak available updates...${RESET}"
        flatpak remote-ls --updates | tee -a "$LOGFILE"
        return 0
    fi

    log "${YELLOW}Updating Flatpak apps...${RESET}"
    run_interactive_logged "flatpak update"

    log "${YELLOW}Removing unused Flatpak runtimes...${RESET}"
    run_interactive_logged "flatpak uninstall --unused"
}

# --- MODULE: github.sh ---
#====================================================================
# MODULE: Secure Private GitHub Repository Production Asset Sync Engine
#====================================================================
# MODULE_VERSION: 1.2
#--------------------------------------------------------------------
# Pings the private GitHub REST API endpoint to determine release state.
# Features automated time-throttling to limit updates to a weekly cadence.
#====================================================================

check_for_script_updates() {
    local mode="$1"
    local TIME_MARKER="$STATE_DIR/.github_last_check"
    local CURRENT_TIME; CURRENT_TIME=$(date +%s)
    local WEEK_IN_SECONDS=604800
    local force_check=0

    if [[ "$mode" == "1" || "$mode" == "--force" ]]; then
        force_check=1
    fi

    # Weekly Mode Throttling Logic
    if [[ "$mode" == "--weekly" ]]; then
        if [[ -f "$TIME_MARKER" ]]; then
            local LAST_CHECK; LAST_CHECK=$(cat "$TIME_MARKER" 2>/dev/null || echo 0)
            local TIME_DELTA=$((CURRENT_TIME - LAST_CHECK))

            if [[ $TIME_DELTA -lt $WEEK_IN_SECONDS ]]; then
                return 0
            fi
        fi
    fi

    log "${BLUE}Checking GitHub for script repository updates...${RESET}"

    # Standardize on your exported variable name
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        log "${YELLOW}Skipping update check: GITHUB_TOKEN environment variable is not exported.${RESET}"
        echo "$CURRENT_TIME" > "$TIME_MARKER"
        return 0
    fi

    # Automatically identify your user and repo configurations via Git metadata
    local REPO_URL; REPO_URL=$(git config --get remote.origin.url 2>/dev/null)
    local REPO_USER; REPO_USER=$(echo "$REPO_URL" | sed -E 's/.*github.com[:\/]([^/]+).*/\1/')
    local REPO_NAME; REPO_NAME=$(echo "$REPO_URL" | sed -E 's/.*\/([^/]+)(\.git)?$/\1/' | sed 's/\.git//')

    # Define a clean asset fallback name matching your compiled build output binary name
    local ASSET_NAME="system-update"

    # Fallback default configurations if running outside of a tracked git repository context
    local TARGET_USER="${REPO_USER:-your_github_username}"
    local TARGET_REPO="${REPO_NAME:-your_repository_name}"

    local API_URL="https://api.github.com/repos/$TARGET_USER/$TARGET_REPO/releases"

    # Pull down raw repository data utilizing standard GITHUB_TOKEN mapping identifiers
    local RELEASES_JSON
    RELEASES_JSON=$(curl -sL -H "Authorization: token ${GITHUB_TOKEN:-}" \
                             -H "Accept: application/vnd.github+json" "$API_URL")

    local REMOTE_TAG
    REMOTE_TAG=$(echo "$RELEASES_JSON" | jq -r '.[0].tag_name' 2>/dev/null)
    local REMOTE_VERSION="${REMOTE_TAG#v}"

    if [[ -z "$REMOTE_VERSION" || "$REMOTE_VERSION" == "null" ]]; then
        log "${YELLOW}Could not resolve any releases via API. (Is a release published?).${RESET}"
        # Save timestamp anyway to protect network endpoints from infinite failure spamming
        echo "$CURRENT_TIME" > "$TIME_MARKER"
        return
    fi

    local IS_PRERELEASE
    IS_PRERELEASE=$(echo "$RELEASES_JSON" | jq -r '.[0].prerelease' 2>/dev/null)

    if [[ "$VERSION" != "$REMOTE_VERSION" ]] && [[ "$(printf '%s\n%s' "$VERSION" "$REMOTE_VERSION" | sort -V | head -n 1)" == "$VERSION" ]]; then
        echo
        if [[ "$IS_PRERELEASE" == "true" ]]; then
            echo -e "${YELLOW}[!] A new PRE-RELEASE is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        else
            echo -e "${YELLOW}[!] A new official release is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        fi

        read -r -p "Would you like to upgrade the script system-wide? (y/N): " update_confirm < /dev/tty

        if [[ "$update_confirm" =~ ^[Yy]$ ]]; then
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

            local ASSET_URL="https://api.github.com/repos/$TARGET_USER/$TARGET_REPO/releases/assets/$ASSET_ID"

            if sudo curl -sL -H "Authorization: token ${GITHUB_TOKEN:-}" \
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

    echo "$CURRENT_TIME" > "$TIME_MARKER"  
}

# --- MODULE: kernel.sh ---
#====================================================================
# MODULE: Active Linux Kernel Audit & Reboot Advisory
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Reports running vs installed kernel packages and warns when the
# running kernel no longer matches what's on disk (reboot needed).
#====================================================================

check_kernel_status() {
    echo
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}    ===== Kernel Status (Simulation) =====${RESET}"
    else
        log "${BLUE}    ===== Kernel Status =====${RESET}"
    fi

    RUNNING_KERNEL="$(uname -r)"
    log "  Running Kernel : $RUNNING_KERNEL"

    # Filter pacman output for mainline kernel package targets
    # (|| true: grep exits 1 when nothing matches).
    INSTALLED_KERNELS="$(pacman -Qq | grep -E '^linux(-(zen|lts|hardened|rt))?$' || true)"

    if [[ -z "$INSTALLED_KERNELS" ]]; then
        log "  Installed Kernels : ${YELLOW}None detected via pacman${RESET}"
    else
        log "  Installed Kernel Packages:"
        while read -r kernel_pkg; do
            kernel_version=$(pacman -Q "$kernel_pkg" | awk '{print $2}')
            log "$(printf '    %-12s : %s' "$kernel_pkg" "$kernel_version")"
        done <<< "$INSTALLED_KERNELS"
    fi

    # Reboot advisory: after a kernel upgrade the running kernel's module
    # tree is removed/replaced. If the directory for the running release
    # is gone, the kernel on disk differs from the one in memory.
    if [[ ! -d "/usr/lib/modules/$RUNNING_KERNEL" ]]; then
        echo
        log "${YELLOW}  [!] The running kernel ($RUNNING_KERNEL) no longer has a matching module tree."
        log "${YELLOW}      A reboot is recommended to load the updated kernel.${RESET}"
    fi
}

# --- MODULE: updates.sh ---
#====================================================================
# MODULE: Pacman Core, Cache Cleaner, Orphans & .pacnew Review
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Interfaces with pacman, cleans old cached packages, removes orphans,
# and surfaces .pacnew/.pacsave config files that need merging.
#====================================================================

run_pacman_module() {
    if [[ $RUN_PACMAN -ne 1 ]]; then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Pacman changes...${RESET}"
        sudo pacman -Syu --print --color=always | tee -a "$LOGFILE"
        return 0
    fi

    # Detect a leftover database lock before we try to upgrade.
    local LCK="/var/lib/pacman/db.lck"
    if [[ -e "$LCK" ]]; then
        if command -v pgrep &>/dev/null && pgrep -x pacman &>/dev/null; then
            fail "pacman is already running ($LCK present). Aborting."
        fi
        log "${YELLOW}[!] Stale pacman lock found at $LCK (no pacman process running).${RESET}"
        read -r -p "Remove stale lock and continue? (y/N): " lck_confirm < /dev/tty
        if [[ "$lck_confirm" =~ ^[Yy]$ ]]; then
            sudo rm -f "$LCK" || fail "Could not remove $LCK"
        else
            fail "Aborted: pacman database is locked."
        fi
    fi

    log "${YELLOW}Updating system packages...${RESET}"
    sudo -v
    run_interactive_logged "sudo pacman -Syu --color=always"
    log "${GREEN}System packages updated${RESET}"
}

run_cache_cleanup_module() {
    if [[ $RUN_CACHE -ne 1 ]]; then
        return 0
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: Skipping cache cleanup${RESET}"
        return 0
    fi
    log "${YELLOW}Cleaning package cache (keeping 2 versions)...${RESET}"
    run_logged "sudo paccache -rk2"
}

run_orphan_module() {
    if [[ $RUN_ORPHANS -ne 1 ]]; then
        return 0
    fi

    log "${YELLOW}Checking for orphaned packages...${RESET}"
    # `|| true` because pacman -Qtdq exits 1 when there are no orphans.
    local orphans
    orphans=$(pacman -Qtdq 2>/dev/null || true)

    if [[ -z "$orphans" ]]; then
        log "${GREEN}No orphaned packages found.${RESET}"
        return 0
    fi

    log "${YELLOW}Orphaned packages detected:${RESET}"
    log "$orphans"

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: would remove the orphans listed above.${RESET}"
        return 0
    fi

    local orphan_args; orphan_args=$(echo "$orphans" | tr '\n' ' ')
    run_interactive_logged "sudo pacman -Rns $orphan_args"
    log "${GREEN}Orphaned packages removed${RESET}"
}

# Surface .pacnew / .pacsave files left behind by a pacman upgrade.
# pacdiff ships with pacman-contrib (already required for paccache).
check_pacdiff() {
    if [[ $RUN_PACMAN -ne 1 || $DRY_RUN -eq 1 ]]; then
        return 0
    fi
    log "${BLUE}Checking for .pacnew / .pacsave config files...${RESET}"
    local files
    files=$(sudo pacdiff -o 2>/dev/null || true)
    if [[ -n "$files" ]]; then
        log "${YELLOW}[!] Config files need review/merge:${RESET}"
        log "$files"
        log "${YELLOW}    Run 'sudo pacdiff' to merge them.${RESET}"
    else
        log "${GREEN}No pending .pacnew/.pacsave files.${RESET}"
    fi
}

# --- CORE: main.sh ---
#====================================================================
# MODULE: Master System Runtime Orchestrator
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Parses runtime flags, validates the environment, and routes control
# sequentially through the operational modules.
#====================================================================

show_help() {
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

    center_text() {
        local text="$1"
        local padding=$(( (TERM_WIDTH - ${#text}) / 2 ))
        [[ $padding -lt 0 ]] && padding=0
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
    echo "  -p        Update pacman packages (full system upgrade, -Syu)"
    echo
    echo "  -F        Update flatpak packages (all apps + prune unused runtimes)"
    echo
    echo "  -c        Cache cleanup via paccache (keeps last 2 versions)"
    echo
    echo "  -a        Update AUR packages via yay (off by default)"
    echo
    echo "  -o        Remove orphaned packages (pacman -Rns, off by default)"
    echo
    echo "  -d        Dry-run: show what would change, modify nothing"
    echo
    echo "  -f        Show a fastfetch system snapshot at the end"
    echo
    echo "  -i        Install/update this script to /usr/local/bin (system-wide)"
    echo
    echo "  -u        Manually check for and install script updates"
    echo
    echo "  -h        Show this help menu"
    echo
    echo "Examples:"
    echo "  system-update           # run standard (equivalent to -pFc)"
    echo "  system-update -pF       # pacman + flatpak"
    echo "  system-update -pFf      # pacman + flatpak + fetch"
    echo "  system-update -pFcao    # pacman + flatpak + cache + AUR + orphans"
    echo "  system-update -d        # dry-run"
    echo "  system-update -u        # manual script update"
}

# --- Initialize Flag Options ---
RUN_PACMAN=0; RUN_FLATPAK=0; RUN_CACHE=0; RUN_AUR=0; RUN_ORPHANS=0
SHOW_FETCH=0; DRY_RUN=0; RUN_INSTALL=0; RUN_SCRIPT_UPDATE=0

# --- Parse Arguments ---
while getopts ":dfpFacohiu" opt; do
    case $opt in
        d) DRY_RUN=1 ;;
        f) SHOW_FETCH=1 ;;
        p) RUN_PACMAN=1 ;;
        F) RUN_FLATPAK=1 ;;
        c) RUN_CACHE=1 ;;
        a) RUN_AUR=1 ;;
        o) RUN_ORPHANS=1 ;;
        i) RUN_INSTALL=1 ;;
        u) RUN_SCRIPT_UPDATE=1 ;;
        h) show_help; exit 0 ;;
        *) show_help; exit 1 ;;
    esac
done

#====================================================================
# MASTER RUNTIME ROUTING
#====================================================================

# 1. Handle manual script update requests instantly
if [[ $RUN_SCRIPT_UPDATE -eq 1 ]]; then
    log "${BLUE}===== Manual Script Updater Module =====${RESET}"
    check_for_script_updates 1
    exit 0
fi

# 2. Environment validation gate (runs for any operational invocation).
if [[ $RUN_INSTALL -eq 1 || $# -eq 0 || $DRY_RUN -eq 1 || $RUN_PACMAN -eq 1 \
      || $RUN_AUR -eq 1 || $RUN_FLATPAK -eq 1 || $RUN_CACHE -eq 1 || $RUN_ORPHANS -eq 1 ]]; then
    check_and_install_dependencies
fi

# 3. First-time run / deployment short circuit (smart installer)
if [[ $# -eq 0 && ! -f "/usr/local/bin/system-update" ]]; then
    clear
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

    center_alert() {
        local text; text=$(echo "$1" | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//')
        local padding=$(( (TERM_WIDTH - ${#text}) / 2 ))
        [[ $padding -lt 0 ]] && padding=0
        printf "%*s%s\n" "$padding" "" "$text"
    }

    echo
    center_alert "$(log "${BLUE}===== Potential First-Time Run Alert =====${RESET}")"
    center_alert "It looks like system-update isn't installed system-wide yet. This could be because"
    center_alert "you are running it for the first time or testing a newly compiled version."
    echo

    read -r -p "Would you like to install v$VERSION system-wide to /usr/local/bin now? (y/N): " local_inst < /dev/tty
    if [[ "$local_inst" =~ ^[Yy]$ ]]; then
        install_script
        exit 0
    else
        log "${YELLOW}Proceeding with local directory execution fallback...${RESET}"
    fi
fi

# 4. Global installation flag (-i)
if [[ $RUN_INSTALL -eq 1 ]]; then
    install_script
    exit 0
fi

# 5. Fallback: default to standard layout (-pFc) if no module flags matched
if [[ $RUN_PACMAN -eq 0 && $RUN_FLATPAK -eq 0 && $RUN_CACHE -eq 0 && $RUN_AUR -eq 0 \
      && $RUN_ORPHANS -eq 0 && $RUN_INSTALL -eq 0 && $RUN_SCRIPT_UPDATE -eq 0 ]]; then
    RUN_PACMAN=1
    RUN_FLATPAK=1
    RUN_CACHE=1
fi

# 6. Header + pre-update checks
if [[ $DRY_RUN -eq 1 ]]; then
    log "${YELLOW}  ===== Starting DRY RUN (v$VERSION) =====${RESET}"
else
    log "${BLUE}    ===== System Update (v$VERSION) =====${RESET}"
    # Self-update check (self-throttled to weekly).
    check_for_script_updates --weekly
    # Arch news only matters when we're about to run a pacman transaction.
    if [[ $RUN_PACMAN -eq 1 ]]; then
        check_arch_news
    fi
fi

#====================================================================
# SEQUENCE MODULE RUNNERS
#====================================================================

run_pacman_module          # pacman -Syu (+ db.lck guard)
run_aur_module             # yay -Sua
run_flatpak_module         # flatpak update + prune
run_cache_cleanup_module   # paccache -rk2
run_orphan_module          # pacman -Rns orphans (opt-in)
check_pacdiff              # .pacnew/.pacsave review (pacman runs only)

# Kernel audit + reboot advisory only when pacman was part of the run.
if [[ $RUN_PACMAN -eq 1 ]]; then
    check_kernel_status
fi

# Optional final system snapshot
if [[ $SHOW_FETCH -eq 1 ]]; then
    fastfetch
fi

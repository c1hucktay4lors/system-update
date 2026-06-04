#====================================================================
# MODULE: Master System Runtime Orchestrator
#====================================================================
# MODULE_VERSION: 1.7
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
    echo "  -e        Everything: pacman + flatpak + cache + AUR + orphans + fastfetch"
    echo "            (equivalent to -pFcaof)"
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
    echo "  system-update -e        # everything (-pFcaof)"
    echo "  system-update -pF       # pacman + flatpak"
    echo "  system-update -pFf      # pacman + flatpak + fetch"
    echo "  system-update -pFcao    # pacman + flatpak + cache + AUR + orphans"
    echo "  system-update -ed       # dry-run across everything"
    echo "  system-update -u        # manual script update"
}

# --- Initialize Flag Options ---
RUN_PACMAN=0; RUN_FLATPAK=0; RUN_CACHE=0; RUN_AUR=0; RUN_ORPHANS=0
SHOW_FETCH=0; DRY_RUN=0; RUN_INSTALL=0; RUN_SCRIPT_UPDATE=0

# --- Parse Arguments ---
while getopts ":defpFacohiu" opt; do
    case $opt in
        d) DRY_RUN=1 ;;
        e) RUN_PACMAN=1; RUN_FLATPAK=1; RUN_CACHE=1; RUN_AUR=1; RUN_ORPHANS=1; SHOW_FETCH=1 ;;
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

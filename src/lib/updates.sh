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

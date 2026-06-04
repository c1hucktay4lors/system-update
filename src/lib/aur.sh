#====================================================================
# MODULE: Arch User Repository (AUR) Packaging Engine
#====================================================================
# MODULE_VERSION: 1.2
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

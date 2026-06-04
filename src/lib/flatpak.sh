#====================================================================
# MODULE: Flatpak Sandboxed Application Updater
#====================================================================
# MODULE_VERSION: 1.2
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

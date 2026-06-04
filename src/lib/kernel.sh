#====================================================================
# MODULE: Active Linux Kernel Audit & Reboot Advisory
#====================================================================
# MODULE_VERSION: 2.1
#--------------------------------------------------------------------
# Reports running vs installed kernel packages and flags when the
# running kernel no longer matches what's on disk. The reboot notice
# itself is emitted at the very end of the run (see print_reboot_notice)
# so it's the last thing on screen, ahead of any fastfetch snapshot.
#====================================================================
 
# Set by check_kernel_status; consumed by print_reboot_notice at the end.
KERNEL_REBOOT_NEEDED=0
 
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
    # is gone, the kernel on disk differs from the one in memory. Only
    # flag it here; the actual notice is printed last (print_reboot_notice).
    if [[ ! -d "/usr/lib/modules/$RUNNING_KERNEL" ]]; then
        KERNEL_REBOOT_NEEDED=1
    fi
}
 
# Prominent reboot reminder, printed as the final output of a run so it
# isn't scrolled off the top by a fastfetch snapshot.
print_reboot_notice() {
    echo
    log "${YELLOW}========================================================${RESET}"
    log "${YELLOW}  [!] REBOOT RECOMMENDED${RESET}"
    log "${YELLOW}      The running kernel (${RUNNING_KERNEL:-current}) no longer has a"
    log "${YELLOW}      matching module tree. Reboot to load the updated kernel.${RESET}"
    log "${YELLOW}========================================================${RESET}"
}
 

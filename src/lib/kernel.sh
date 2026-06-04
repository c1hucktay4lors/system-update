#====================================================================
# MODULE: Active Linux Kernel Audit & Reboot Advisory
#====================================================================
# MODULE_VERSION: 1.1
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

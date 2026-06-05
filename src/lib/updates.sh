#====================================================================
# MODULE: Pacman Core, Cache Cleaner, Orphans & .pacnew Review
#====================================================================
# MODULE_VERSION: 2.3
#--------------------------------------------------------------------
# Interfaces with pacman, cleans old cached packages, removes orphans,
# and surfaces .pacnew/.pacsave config files that need merging.
#====================================================================

# Pre-upgrade disk-space guard. A `pacman -Syu` that runs out of room
# mid-transaction (in / for installed files, or in the package cache for
# downloads) is painful to recover from, so warn before we start. Checks
# the filesystem holding / and the one holding the pacman cache, skipping
# the second if it's the same device. Threshold overridable via env.
preflight_disk_space() {
    local min_mb="${MIN_FREE_MB:-2048}"
    local -A seen=()
    local p line dev avail_kb avail_mb mnt low=0
    for p in "/" "/var/cache/pacman/pkg"; do
        [[ -d "$p" ]] || continue
        line=$(df -Pk "$p" 2>/dev/null | awk 'NR==2') || continue
        [[ -z "$line" ]] && continue
        dev=$(awk '{print $1}' <<< "$line")
        [[ -n "${seen[$dev]:-}" ]] && continue   # same filesystem, skip dupe
        seen[$dev]=1
        avail_kb=$(awk '{print $4}' <<< "$line")
        mnt=$(awk '{print $6}' <<< "$line")
        avail_mb=$(( avail_kb / 1024 ))
        if [[ $avail_mb -lt $min_mb ]]; then
            log "${YELLOW}[!] Low disk space on ${mnt}: ${avail_mb} MiB free (threshold ${min_mb} MiB).${RESET}"
            low=1
        fi
    done
    if [[ $low -eq 1 ]]; then
        read -r -p "Continue with the upgrade anyway? (y/N): " sp_confirm < /dev/tty
        [[ "$sp_confirm" =~ ^[Yy]$ ]] || fail "Aborted: insufficient free disk space."
    fi
}

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

    preflight_disk_space

    # Check pending updates ONCE; the result drives both the count preview
    # and the keyring decision below. Safe to run pre-upgrade: checkupdates
    # syncs to its own temporary database and never touches the live one.
    # It ships with pacman-contrib (already required for paccache), so it's
    # not a new dependency.
    local pending="" keyring_pending=0 keyring_known=0
    if command -v checkupdates &>/dev/null; then
        pending=$(checkupdates 2>/dev/null); local cu_status=$?
        if [[ $cu_status -eq 0 ]]; then
            log "${BLUE}$(printf '%s\n' "$pending" | grep -c .) official update(s) pending.${RESET}"
            keyring_known=1
            printf '%s\n' "$pending" | grep -q '^archlinux-keyring ' && keyring_pending=1
        elif [[ $cu_status -eq 2 ]]; then
            log "${GREEN}No official updates pending.${RESET}"
            keyring_known=1
        else
            log "${YELLOW}Could not check pending updates (checkupdates exit $cu_status).${RESET}"
        fi
    fi

    # Keyring handling BEFORE the full upgrade. A stale archlinux-keyring is
    # the most common cause of "invalid or corrupted package (PGP signature)"
    # failures during -Syu on infrequently-updated systems. We only do the
    # (noisy) refresh when a newer keyring is actually available; otherwise
    # we just confirm it's current. When the check above was inconclusive
    # (checkupdates missing or errored) we refresh anyway, to be safe.
    # `-Sy <pkg>` alone is the partial-upgrade footgun, but it's immediately
    # followed by the full -Syu below, the pattern the Arch wiki recommends.
    log "${YELLOW}Checking for an up-to-date archlinux-keyring...${RESET}"
    if [[ $keyring_known -eq 1 && $keyring_pending -eq 0 ]]; then
        log "${GREEN}Keyring already up to date.${RESET}"
    else
        log "${YELLOW}Updating archlinux-keyring...${RESET}"
        run_root_interactive_logged "pacman -Sy --needed --noconfirm archlinux-keyring"
    fi

    log "${YELLOW}Updating system packages...${RESET}"
    run_root_interactive_logged "pacman -Syu --color=always"
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
    run_root_interactive_logged "pacman -Rns $orphan_args"
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

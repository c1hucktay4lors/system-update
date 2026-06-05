#====================================================================
# MODULE: Pre-Update System Snapshot (Timeshift)
#====================================================================
# MODULE_VERSION: 1.1
#--------------------------------------------------------------------
# Takes a Timeshift snapshot before any package changes so a bad
# upgrade can be rolled back. Timeshift is filesystem-agnostic: on
# Btrfs it uses native CoW snapshots, and on ext4 (or anything else)
# it falls back to incremental rsync, so this works regardless of the
# underlying filesystem.
#
# Opt-in via -s (and folded into nothing else by default, so a snapshot
# is only ever taken when explicitly requested). Best-effort: if
# timeshift isn't installed we warn and continue; if the snapshot
# command fails we ask whether to proceed without one rather than
# silently upgrading unprotected.
#====================================================================

run_snapshot_module() {
    if [[ $RUN_SNAPSHOT -ne 1 ]]; then
        return 0
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: would create a Timeshift snapshot before updating.${RESET}"
        return 0
    fi

    if ! command -v timeshift &>/dev/null; then
        log "${YELLOW}[!] Timeshift not installed; skipping pre-update snapshot.${RESET}"
        log "${YELLOW}    Install it to enable rollback snapshots (works on ext4 via rsync):${RESET}"
        log "${BLUE}      sudo pacman -S timeshift${RESET}"
        return 0
    fi

    log "${YELLOW}Creating pre-update Timeshift snapshot...${RESET}"
    local comment; comment="system-update $(date '+%Y-%m-%d %H:%M:%S')"

    # --tags O marks this as an on-demand snapshot. Run non-fatally so a
    # failure (e.g. Timeshift not yet configured with a target device)
    # lets us prompt instead of aborting the whole run.
    if run_root_interactive_logged "timeshift --create --comments \"$comment\" --tags O" nonfatal; then
        SNAPSHOT_TAKEN=1
        log "${GREEN}Snapshot created.${RESET}"
    else
        log "${RED}[!] Snapshot creation failed.${RESET}"
        log "${YELLOW}    Timeshift may not be configured yet (run 'sudo timeshift-gtk' once to pick a target).${RESET}"
        read -r -p "Continue with the update WITHOUT a snapshot? (y/N): " snap_confirm < /dev/tty
        if [[ ! "$snap_confirm" =~ ^[Yy]$ ]]; then
            fail "Aborted: pre-update snapshot failed."
        fi
        log "${YELLOW}Proceeding without a snapshot.${RESET}"
    fi
}

#====================================================================
# MODULE: Public GitHub Release Self-Updater
#====================================================================
# MODULE_VERSION: 1.4
#--------------------------------------------------------------------
# Queries the public GitHub REST API for the latest release and, if a
# newer version exists, downloads the attached asset. No auth token is
# required (the repository is public). Automatic checks are throttled
# to a weekly cadence.
#====================================================================

# Repository to check for releases, as "owner/repo".
# The installed copy in /usr/local/bin has no .git directory, so git
# auto-detection can't work there — set this (or export SYSUPDATE_REPO)
# so self-update works everywhere. When run from a clone, the git remote
# is used automatically if present.
SCRIPT_REPO="${SYSUPDATE_REPO:-c1hucktay4lors/system-update}"

check_for_script_updates() {
    local mode="$1"
    local TIME_MARKER="$STATE_DIR/.github_last_check"
    local CURRENT_TIME; CURRENT_TIME=$(date +%s)
    local WEEK_IN_SECONDS=604800
    local force_check=0

    if [[ "$mode" == "1" || "$mode" == "--force" ]]; then
        force_check=1
    fi

    # Weekly throttle
    if [[ "$mode" == "--weekly" && -f "$TIME_MARKER" ]]; then
        local LAST_CHECK; LAST_CHECK=$(cat "$TIME_MARKER" 2>/dev/null || echo 0)
        if [[ $((CURRENT_TIME - LAST_CHECK)) -lt $WEEK_IN_SECONDS ]]; then
            return 0
        fi
    fi

    log "${BLUE}Checking GitHub for script updates...${RESET}"

    # Resolve owner/repo: prefer the git remote (when run from a clone),
    # otherwise fall back to the configured SCRIPT_REPO.
    local REPO_SLUG="$SCRIPT_REPO"
    local REPO_URL; REPO_URL=$(git config --get remote.origin.url 2>/dev/null || true)
    if [[ -n "$REPO_URL" ]]; then
        REPO_SLUG=$(echo "$REPO_URL" \
            | sed -E -e 's#^git@github\.com:##' -e 's#^https://github\.com/##' \
                     -e 's#\.git$##' -e 's#/$##')
    fi

    if [[ -z "$REPO_SLUG" || "$REPO_SLUG" == "OWNER/REPO" ]]; then
        log "${YELLOW}Skipping update check: repository not configured (set SYSUPDATE_REPO or SCRIPT_REPO).${RESET}"
        echo "$CURRENT_TIME" > "$TIME_MARKER"
        return 0
    fi

    local ASSET_NAME="system-update"
    local API_URL="https://api.github.com/repos/$REPO_SLUG/releases"

    # Public repo: no Authorization header needed.
    local RELEASES_JSON
    RELEASES_JSON=$(curl -fsSL -H "Accept: application/vnd.github+json" "$API_URL" 2>/dev/null)

    local REMOTE_TAG; REMOTE_TAG=$(echo "$RELEASES_JSON" | jq -r '.[0].tag_name' 2>/dev/null)
    local REMOTE_VERSION="${REMOTE_TAG#v}"

    if [[ -z "$REMOTE_VERSION" || "$REMOTE_VERSION" == "null" ]]; then
        log "${YELLOW}Could not resolve any releases via the API. (Is a release published? Rate limited?)${RESET}"
        echo "$CURRENT_TIME" > "$TIME_MARKER"
        return 0
    fi

    local IS_PRERELEASE; IS_PRERELEASE=$(echo "$RELEASES_JSON" | jq -r '.[0].prerelease' 2>/dev/null)

    # Update only when the remote version is strictly newer (sort -V).
    if [[ "$VERSION" != "$REMOTE_VERSION" ]] && \
       [[ "$(printf '%s\n%s' "$VERSION" "$REMOTE_VERSION" | sort -V | head -n 1)" == "$VERSION" ]]; then
        echo
        if [[ "$IS_PRERELEASE" == "true" ]]; then
            echo -e "${YELLOW}[!] A new PRE-RELEASE is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        else
            echo -e "${YELLOW}[!] A new release is available: v$REMOTE_VERSION (Local: v$VERSION)${RESET}"
        fi

        read -r -p "Would you like to upgrade the script system-wide? (y/N): " update_confirm < /dev/tty

        if [[ "$update_confirm" =~ ^[Yy]$ ]]; then
            # Public download URL for the named asset — no auth required.
            local DL_URL
            DL_URL=$(echo "$RELEASES_JSON" \
                | jq -r ".[0].assets[] | select(.name==\"$ASSET_NAME\") | .browser_download_url" 2>/dev/null)

            if [[ -z "$DL_URL" || "$DL_URL" == "null" ]]; then
                fail "Found release v$REMOTE_VERSION, but no attached asset named '$ASSET_NAME'."
            fi

            local TARGET_PATH="$INSTALLED_PATH"
            [[ ! -f "$INSTALLED_PATH" ]] && TARGET_PATH=$(realpath "$0")

            log "${YELLOW}Downloading v$REMOTE_VERSION...${RESET}"
            if sudo curl -fsSL "$DL_URL" -o "$TARGET_PATH"; then
                sudo chmod +x "$TARGET_PATH"
                log "${GREEN}Script updated to v$REMOTE_VERSION! Please rerun your command.${RESET}"
                exit 0
            else
                fail "Failed to download release asset to $TARGET_PATH"
            fi
        fi
    else
        if [[ $force_check -eq 1 ]]; then
            log "${GREEN}You are already on the latest release (v$VERSION).${RESET}"
        fi
    fi

    echo "$CURRENT_TIME" > "$TIME_MARKER"
}

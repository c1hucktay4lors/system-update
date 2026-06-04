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

#====================================================================
# MODULE: Environment Dependency Gate
#====================================================================
# MODULE_VERSION: 2.0
#--------------------------------------------------------------------
# Audits the host for every required binary on EVERY run. Because the
# rest of the script deliberately omits per-command `command -v` guards,
# this gate is what guarantees those binaries exist. Caching the result
# (the old behaviour) broke that guarantee: a dependency removed after
# the first run would slip past the gate and crash an unguarded module.
# A `command -v` sweep is microseconds, so it runs every time.
#====================================================================

check_and_install_dependencies() {
    # 1. Define standard official repository dependencies
    local NATIVE_DEPS=(
        "bash" "sudo" "curl" "jq" "flatpak" "fastfetch"
        "paccache" "realpath" "script" "tput" "git"
    )

    local MISSING_DEPS=()
    local need_yay=0
    local need_informant=0

    log "${BLUE}Auditing system environment for required dependencies...${RESET}"

    get_package_name() {
        case "$1" in
            "paccache")  echo "pacman-contrib" ;;
            "realpath")  echo "coreutils" ;;
            "script")    echo "util-linux" ;;
            "tput")      echo "ncurses" ;;
            *)           echo "$1" ;;
        esac
    }

    # Inventory missing native applications (dedup via associative array)
    local -A seen=()
    local cmd pkg
    for cmd in "${NATIVE_DEPS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg=$(get_package_name "$cmd")
            if [[ -z "${seen[$pkg]:-}" ]]; then
                seen[$pkg]=1
                MISSING_DEPS+=("$pkg")
            fi
        fi
    done

    # Check specialized AUR dependencies
    command -v yay &>/dev/null       || need_yay=1
    command -v informant &>/dev/null || need_informant=1

    # Nothing missing: clean pass.
    if [[ ${#MISSING_DEPS[@]} -eq 0 && $need_yay -eq 0 && $need_informant -eq 0 ]]; then
        return 0
    fi

    # Report what's missing.
    clear
    echo -e "\n${YELLOW}[!] Unresolved core binaries discovered in environment:${RESET}"
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        echo -e "    -> Official Repos: ${MISSING_DEPS[*]}"
    fi
    local aur_list=()
    [[ $need_yay -eq 1 ]] && aur_list+=("yay")
    [[ $need_informant -eq 1 ]] && aur_list+=("informant")
    if [[ ${#aur_list[@]} -gt 0 ]]; then
        echo -e "    -> Arch User Repo: ${aur_list[*]}"
    fi
    echo

    # A dry-run must never mutate the system. Report and continue;
    # the read-only dry-run commands will simply note if a tool is absent.
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log "${YELLOW}DRY-RUN: dependencies are missing. A real run would offer to install them. Continuing without changes.${RESET}"
        return 0
    fi

    # Halt execution and prompt user for patching
    read -r -p "Would you like to automatically install these dependencies? (yes/No): " dep_confirm < /dev/tty
    if [[ "$dep_confirm" != "yes" ]]; then
        fail "Environment validation rejected. Please manually install the missing dependencies and try again."
    fi

    # Bootstrap missing native packages
    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        log "${YELLOW}Installing missing official system packages...${RESET}"
        if command -v sudo &>/dev/null; then
            sudo pacman -Sy --needed --noconfirm "${MISSING_DEPS[@]}" || fail "Failed to install official dependencies."
        else
            pacman -Sy --needed --noconfirm "${MISSING_DEPS[@]}" || fail "Failed to install official dependencies as root."
        fi
    fi

    # Handle AUR builds
    if [[ $need_yay -eq 1 || $need_informant -eq 1 ]]; then
        if ! pacman -Qi base-devel &>/dev/null; then
            log "${YELLOW}Installing base-devel toolchain...${RESET}"
            sudo pacman -S --needed --noconfirm base-devel || fail "Failed to install base-devel."
        fi

        local temp_dir; temp_dir=$(mktemp -d)
        # Register for cleanup via the shared EXIT trap instead of
        # installing our own (which would clobber the terminal-restore trap).
        TEMP_DIRS+=("$temp_dir")

        if [[ $need_yay -eq 1 ]]; then
            log "${YELLOW}Bootstrapping 'yay' from the AUR...${RESET}"
            git clone https://aur.archlinux.org/yay.git "$temp_dir/yay" || fail "Failed to clone yay."
            ( cd "$temp_dir/yay" && makepkg -si --noconfirm ) || fail "Build failure during 'yay' installation."
        fi

        if [[ $need_informant -eq 1 ]]; then
            log "${YELLOW}Installing 'informant' via yay...${RESET}"
            yay -S --noconfirm informant || fail "Failed to install 'informant' via yay."
        fi
    fi

    log "${GREEN}Dependencies successfully installed! Resuming standard operations...${RESET}\n"
    sleep 2
}

#====================================================================
# MODULE: Arch Linux News Validation Feed
#====================================================================
# MODULE_VERSION: 1.0
#--------------------------------------------------------------------
# Intercepts unread news items that require manual intervention
# before package transaction frameworks are executed.
#====================================================================

check_arch_news() {
    log "${BLUE}Checking official Arch Linux news feed for urgent interventions...${RESET}"

    # Informant returns a non-zero exit code if unread articles exist
    if ! informant check &>/dev/null; then
        echo
        log "${RED}[!] CRITICAL ARCH NEWS DETECTED [!]${RESET}"
        log "${YELLOW}Arch Linux has published mandatory manual intervention notices.${RESET}"
        echo -e "--------------------------------------------------------"

        # Query and pipe the raw headlines out to the active terminal
        informant list --unread

        echo -e "--------------------------------------------------------"
        echo -e "${YELLOW}It is highly recommended to read these before updating.${RESET}"
        read -r -p "Have you reviewed the news requirements and want to proceed? (y/N): " news_confirm < /dev/tty

        # Halt entire system execution loop if user chooses to abort
        if [[ ! "$news_confirm" =~ ^[Yy]$ ]]; then
            log "${RED}Update aborted by user to review Arch News instructions.${RESET}"
            exit 1
        else
            log "${YELLOW}News acknowledged. Proceeding with update sequence...${RESET}"
            
            # Acknowledge all active postings to unlock future execution
            sudo informant read --all &>/dev/null
        fi
    else
        log "${GREEN}No unread critical Arch news found.${RESET}"
    fi
}

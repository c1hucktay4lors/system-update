# Arch Linux System Update Script (`system-update`)

An automated, robust, and fully interactive system maintenance utility for Arch Linux. This script provides centralized package management, automated caching cleanup, and terminal-safe logging without sacrificing the native, verbose visual feedback of package managers.

## Features

- **Interactive TTY Logging:** Utilizes the Unix `script` pseudo-terminal utility to capture logs while preserving live `pacman` and `flatpak` progress animations, download bars, and manual interactive confirmations (`[Y/n]`).
- **Modular Updates:** Supports targeted or combined updates for Core Packages (`pacman`), AUR Packages (`yay`), and `flatpak` applications via combinable CLI flags.
- **Automated Sudo Handling:** Employs `sudo -v` upfront to cache user credentials, preventing broken or hidden password prompts inside detached terminal logs.
- **Dry-Run (Simulation) Mode:** Preview incoming packages and database changes using downstream `--print` or simulation features safely before pulling files.
- **Smart Kernel Auditing:** Automatically cross-references the currently running kernel hook (`uname -r`) against newly installed core kernel images to prompt clean reboots when driver or module mismatches could occur.
- **State-Compliant Logs:** Completely conforms to standard Unix environmental specs by routing runtime histories directly to `$XDG_STATE_HOME/system-update/`.

---

## Installation

You can run the script standalone or deploy it system-wide using the built-in deployment module.

### 1. Clone the repository
```bash
git clone [https://github.com/yourusername/your-repo-name.git](https://github.com/yourusername/your-repo-name.git)
cd your-repo-name
chmod +x system-update.sh

2. Install System-WideRun the script with the -i flag to automatically deploy it to /usr/local/bin:Bash./system-update.sh -i
Alternatively, on its very first run, the script will automatically check your environment and offer an interactive prompt to install itself system-wide.UsageBy default, executing system-update with no arguments triggers a full, standard maintenance sweep (equivalent to running -pFc).Bashsystem-update [options]
Command-Line FlagsFlagModule NameDescription-pPacman CoreExecutes full system upgrade (pacman -Syu).-aAUR CoreUpdates AUR utilities and dependencies using yay.-FFlatpakSyncs Flatpak runtimes and automatically strips unused dependencies.-cCache CleanupRuns paccache -rk2 to prune package archives while keeping the last two versions.-dDry RunSimulates execution, printing pending packages without writing changes.-fSystem SnapshotAppends a fastfetch system summary terminal output upon completion.-iInstallerDeploys the script source securely into the local binaries environment.-hHelp MenuDisplays the configuration summary, local log paths, and flag pairings.ExamplesRun standard core maintenance (Pacman + Flatpak + Cache Cleanup):Bashsystem-update
Perform a dry-run test to see what updates are pending:Bashsystem-update -d
Run an exhaustive system upgrade including AUR and finish with a fastfetch snapshot:Bashsystem-update -paf
Architecture & Logging MechanicsStandard shell pipeline logging (command | tee log.txt) strips out standard terminal characteristics (TTY). This causes advanced package managers like pacman to drop download animations, and causes tools like flatpak to automatically reject interactive updates by defaulting to No.To bypass this behavior, this script leverages pseudo-terminals via the script environment utility:Bashscript -eqc "sudo pacman -Syu --color=always" /dev/null | tee -a "$LOGFILE"
This forces downstream tools to see a valid terminal matrix, preserving user choices and rich terminal colors, while tee transparently maintains an uncorrupted audit log inside ~/.local/state/system-update/system-update.log.Version Changelogv1.4.0 — Current Stable ReleaseIntegrated script utility boundaries for Flatpak and Pacman steps to restore download tracking bars and interactive manual choices inside piped streams.Implemented upfront sudo -v state token generation to protect child processes from credential context lockouts.Migrated old shell conditional parameters to native Bash double-bracket [[ ]] tests.Embedded automatic realpath tracking routines to safely find the script's physical source during deployment tasks.v1.3.6 — Streamlined individual maintenance commands and introduced modular core flags.v1.0.0 — First stable script environment with static text log integration.

# Arch Linux System Update Script (`system-update`)

An automated, robust, and fully interactive system maintenance utility for Arch Linux. This script provides centralized package management, automated caching cleanup, and terminal-safe logging without sacrificing the native, verbose visual feedback of package managers. 

Made primarily with ChatGPT and Google Gemini, as I did not want to write out all of these commands one after the other to update his system, and I had never messed with AI before in this context. This is purely an experiment to see if i can have it do what I want, but make it pretty looking. Code is AI generated, but looked over by human eyes to check for discrepancies (in which the human has made mistakes).

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
git clone [https://github.com/mwsmith867/system-update.git](https://github.com/mwsmith867/system-update.git)
cd system-update
chmod +x system-update.sh
```
### 2. Install System-Wide

Run the script with the `-i` flag to automatically deploy it to `/usr/local/bin`
```bash
./system-update.sh -i
```
Alternatively, on its very first run, the script will automatically check your environment and offer an interactive prompt to install itself system-wide.

## Usage

By default, executing `system-update` with no arguments triggers a full, standard maintenance sweep (equivalent to running `-pFc`).
```bash
system-update [options]
```
### Command-Line Flags

| Flag | Sub-Command / Tool | Description | Default Behavior / Notes |
| :---: | :--- | :--- | :--- |
| `-p` | `pacman` | Updates core system packages. | Pre-configured to execute a full system upgrade (`-Syu`). |
| `-F` | `flatpak` | Updates Flatpak applications. | Pre-configured to automatically update all installed flatpaks. |
| `-c` | `paccache` | Runs package cache cleanup. | Retains the last 2 versions of installed packages to save space. |
| `-a` | `yay` | Updates AUR packages. | Optional; updates AUR packages only (disabled by default). |
| `-d` | *Simulation* | Executes a Dry-run. | Displays a preview of what packages would be updated without changing files. |
| `-f` | `fastfetch` | System snapshot. | Appends a clean hardware/OS summary at the very end (if installed). |
| `-i` | *Installer* | System-wide deployment. | Copies and configures the script to `/usr/local/bin` for global access. |
| `-h` | *Help* | Assistance menu. | Displays the CLI tool usage syntax and flags guide. |

## Examples

Run standard core maintenance (Pacman + Flatpak + Cache Cleanup):
```bash
system-update
```
Perform a dry-run test to see what updates are pending:
```bash
system-update -d
```
Run an exhaustive system upgrade including AUR and finish with a fastfetch snapshot:
```bash
system-update -paf
```
## Architecture & Logging Mechanics

Standard shell pipeline logging (`command | tee log.txt`) strips out standard terminal characteristics (TTY). This causes advanced package managers like `pacman` to drop download animations, and causes tools like `flatpak` to automatically reject interactive updates by defaulting to `No`.

To bypass this behavior, this script leverages pseudo-terminals via the `script` environment utility:
```bash
script -eqc "sudo pacman -Syu --color=always" /dev/null | tee -a "$LOGFILE"
```

This forces downstream tools to see a valid terminal matrix, preserving user choices and rich terminal colors, while `tee` transparently maintains an non corrupted audit log inside `~/.local/state/system-update/system-update.log`.

## Version Changelog

-   **v1.4.0** — _Current Stable Release_
    
    -   Integrated `script` utility boundaries for Flatpak and Pacman steps to restore download tracking bars and interactive manual choices inside piped streams.
        
    -   Implemented upfront `sudo -v` state token generation to protect child processes from credential context lockouts.
        
    -   Migrated old shell conditional parameters to native Bash double-bracket `[[ ]]` tests.
        
    -   Embedded automatic `realpath` tracking routines to safely find the script's physical source during deployment tasks.
        
-   **v1.3.6** — Streamlined individual maintenance commands and introduced modular core flags.
    
-   **v1.0.0** — First stable script environment with static text log integration.

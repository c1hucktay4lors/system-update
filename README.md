# Max's Arch System Update Script (`system-update`)

A fully interactive system maintenance utility for Arch Linux. This script provides centralized package manager updates, automated cache cleanup, and terminal-safe logging without sacrificing the native, verbose visual feedback of the package managers.

Made primarily with ChatGPT and Google Gemini, this project started because I wanted to update my system without manually writing out repetitive commands, and I wanted to see what it was like using AI in this context. This is purely an experiment to see if I can have AI build exactly what I want, while making it look clean and polished. The code is AI-generated but reviewed by human eyes to check for discrepancies (though the human has certainly made a few mistakes along the way!).

## Features

- **Interactive TTY Logging:** Utilizes the Unix `script` pseudo-terminal utility to capture logs while preserving live `pacman` and `flatpak` progress animations, download bars, and manual interactive confirmations (`[Y/n]`).
- **Modular Updates:** Supports targeted or combined updates for Core Packages (`pacman`), AUR Packages (`yay`), and `flatpak` applications via combinable CLI flags.
- **Automated Sudo Handling:** Employs `sudo -v` upfront to cache user credentials, preventing broken or hidden password prompts inside detached terminal logs.
- **Dry-Run (Simulation) Mode:** Preview incoming packages and database changes using downstream `--print` or simulation features safely before pulling files.
- **Smart Kernel Auditing:** Automatically cross-references the currently running kernel hook (`uname -r`) against newly installed core kernel images to prompt clean reboots when driver or module mismatches could occur.
- **State-Compliant Logs:** Completely conforms to standard Unix environmental specs by routing runtime histories directly to `$XDG_STATE_HOME/system-update/`.
- **Private GitHub API Self-Updater:** Automatically pings this private GitHub repository's REST API to detect newer releases, downloads the latest script asset securely using localized tokens, and updates itself system-wide.

---

## Prerequisites

This script is designed to run out of the box on a standard Arch Linux system with minimal configuration. However, because it manages various package managers and system utilities, it relies on several core binaries to execute all its modules.

### 1. Already Installed by Default (Base System)
These standard tools handle the script's basic infrastructure, argument handling, and pseudo-terminal management:
* **`bash`**: The script uses a `#!/bin/bash` shebang and relies on native Bash keywords like `[[ ]]` and `getopts`. *(Note: It will not run correctly under a strict POSIX shell like `sh` or `dash`)*.
* **`util-linux` (provides `script`)**: Crucial for the interactive logging architecture. The `script` command creates the pseudo-terminal (TTY) that forces `pacman` to render download bars and prevents `flatpak` from defaulting to "No".
* **`coreutils` (provides `realpath`)**: Used during the installation prompt to resolve the absolute physical path of the script source before deploying to `/usr/local/bin`.
* **`sudo`**: Necessary to refresh credentials upfront (`sudo -v`) and to authorize root system modifications.
* **`pacman`**: Required for the core `-p` system update flag and for auditing `linux` package strings during the kernel version check.
* **`ncurses` (provides `tput`)**: Used in the help menu to calculate your terminal width (`tput cols`) and cleanly center the title text.

### 2. NOT Installed by Default (User-Installed)
The script gracefully skips modules if an optional tool is missing. To utilize specific flags or features, make sure the following are installed:
* **`pacman-contrib` (provides `paccache`)**: **Important.** The `paccache` script used in the cache cleanup module (`-c`) is no longer bundled with the core `pacman` package. It must be installed separately via `pacman-contrib`.
* **`jq`**: Required for the script self-update feature. It parses the JSON payload returned by the GitHub REST API to locate your release assets.
* **`flatpak`**: Required to run the `-F` flag to update sandboxed application runtimes and clear out unused data.
* **`yay`**: Required if you run the script with the `-a` flag to fetch and build updates from the Arch User Repository (AUR).
* **`fastfetch`**: Required only if you pass the `-f` flag to print a hardware/OS system summary snapshot upon script completion.

### Quick Install Command
To ensure absolutely every feature of your script works perfectly, you can sync all optional and tool-specific dependencies from the official repositories with a single command:

```bash
sudo pacman -S pacman-contrib jq flatpak yay fastfetch
```
[And follow the instructions to install yay here](https://github.com/jguer/yay)

## Installation

### Option 1: Using Git

### Clone the repository
```bash
git clone https://github.com/c1hucktay4lors/system-update.git
cd system-update
```
### Option 2: Using the Releases tab

Download the latest [release](https://github.com/c1hucktay4lors/system-update/releases/latest).

### Set as executable:
```bash 
chmod +x system-update.sh
```

## First-time run

When runing the script for the first time:
```bash
./system-update.sh
```

It will automatically check your environment and offer an interactive prompt to install itself in `usr/local/bin` so it can be called upon system-wide:

```bash
   ===== System Update (vX.X.X) =====
system-update is not installed system-wide.

Would you like to install it to /usr/local/bin/system-update? (y/N): 

```

Selecting no will end the script and allow you to re-run with any flags requested, as well as a ```.install_prompt_shown``` and ```system-update.log``` file being added to ```~/.local/state/system-update/``` 

Run the script with the `-i` flag to automatically deploy it to `/usr/local/bin` if you select no to the inital system-wide install:

```bash
./system-update.sh -i
```

## Usage

By default, executing `system-update` with no arguments triggers a full, standard maintenance sweep without AUR updates (equivalent to running `-pFc`).
```bash
system-update [options]
```
### Command-Line Flags

| Flag | Sub-Command / Tool | Description | Default Behavior / Notes |
| :---: | :--- | :--- | :--- |
| `-p` | `pacman` | Updates core system packages | Pre-configured to execute a full system upgrade (`-Syu`) |
| `-F` | `flatpak` | Updates Flatpak applications | Pre-configured to automatically update all installed flatpaks |
| `-c` | `paccache` | Runs package cache cleanup | Retains the last 2 versions of installed packages to save space |
| `-a` | `yay` | Updates AUR packages | Updates AUR packages only (disabled by default) |
| `-d` | *Simulation* | Executes a Dry-run | Displays a preview of what packages would be updated without changing files |
| `-f` | `fastfetch` | System snapshot | Appends a clean hardware/OS summary at the very end (if installed) |
| `-i` | *Installer* | System-wide deployment | Copies and configures the script to `/usr/local/bin` for global access |
| `-u` | *GitHub API* | Manual Script Updater | Pings the private repo to immediately check for and download the latest script release |
| `-h` | *Help* | Assistance menu | Displays the usage, syntax and flags guide |

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

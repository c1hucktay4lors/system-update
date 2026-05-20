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

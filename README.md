# `system-update` (Testing)

A small Bash wrapper that runs my usual Arch maintenance steps with one command instead of typing four. This is the `Testing` branch where I try changes before they're stable. Most of it was written with AI assistance.

---

## What it does

Run with no arguments, it does a standard sweep: a full pacman upgrade, a Flatpak update, and a package-cache trim. AUR updates and orphan removal are opt-in. Everything can be combined or run on its own, and there's a dry-run that changes nothing.

## How it's organized

Source lives in `src/`, split into small modules. `build.sh` concatenates them into a single executable, `system-update.sh`, which is the thing you actually run or install.

```
system-update/
├── build.sh            # concatenates src/ into system-update.sh
├── system-update.sh    # the built, runnable script
└── src/
    ├── main.sh         # argument parsing + run order
    └── lib/
        ├── logging.sh      # logging, colors, traps, shared run helpers
        ├── dependencies.sh # checks (and offers to install) required tools
        ├── updates.sh      # pacman, cache, orphans, .pacnew review
        ├── aur.sh          # yay
        ├── flatpak.sh      # flatpak
        ├── archnews.sh     # Arch news check via informant
        ├── github.sh       # self-update from a GitHub release
        └── kernel.sh       # kernel report + reboot advisory
```

## How a few things work

**Dependency check.** On every run, the script verifies the tools it needs are present (a `command -v` sweep — cheap enough to do each time). If something's missing it lists it and offers to install it. Because this gate runs every time, the other modules don't repeat per-command checks. A dry-run never installs anything; it just reports what's missing.

**Logging without breaking the terminal.** Piping a command into `tee` normally strips colors and confuses tools into auto-answering prompts. Interactive steps instead run inside a pseudo-terminal via `script`, so colors, progress bars, and `[Y/n]` prompts work, while a color-stripped copy goes to the log:

```bash
script -eqc "sudo pacman -Syu --color=always" /dev/null | tee >( ... )
```

Logs land in `$XDG_STATE_HOME/system-update/` and rotate once they pass ~2 MB.

**Safety checks.** Before upgrading, it checks the Arch news feed (via `informant`) and a stale pacman `db.lck`. After upgrading, it flags `.pacnew`/`.pacsave` files to merge and warns if the running kernel differs from the one now on disk (reboot recommended).

## Build & run

```bash
./build.sh          # build system-update.sh from src/
./system-update.sh  # run it; offers to install system-wide on first run
```

If `shellcheck` is installed, `build.sh` runs it and fails the build on errors.

## Usage

By default (no flags), `system-update` runs the equivalent of `-pFc`.

```
system-update [options]
```

| Flag | Tool | Description | Default |
| :---: | :--- | :--- | :--- |
| `-p` | pacman | Full system upgrade (`-Syu`) | on by default |
| `-F` | flatpak | Update apps, prune unused runtimes | on by default |
| `-c` | paccache | Trim cache, keep last 2 versions | on by default |
| `-a` | yay | Update AUR packages | off |
| `-o` | pacman | Remove orphaned packages (`-Rns`) | off |
| `-d` | — | Dry-run: preview only, no changes | — |
| `-f` | fastfetch | System snapshot at the end | — |
| `-i` | — | Install to `/usr/local/bin` | — |
| `-u` | — | Check GitHub for a script update | — |
| `-h` | — | Help | — |

### Examples

```bash
system-update           # standard: pacman + flatpak + cache trim
system-update -d        # dry-run across the default engines
system-update -paf      # pacman + AUR + fastfetch
system-update -pFcao    # everything, including orphan removal
system-update -u        # check for a script update now
```

# `system-update` (Claude)

A small Bash wrapper that runs my usual Arch maintenance steps with one command instead of typing four. This is the `Claude` branch where I used a friends Claude Pro subscription and Opus to rewrite Gemini's code.

---

## What it does

Run with no arguments, it does a standard sweep: a full pacman upgrade, a Flatpak update, and a package-cache trim. AUR updates, orphan removal, and a pre-update Timeshift snapshot are opt-in. Everything can be combined or run on its own, and there's a dry-run that changes nothing.

## How it's organized

Source lives in `src/`, split into small modules. `build.sh` concatenates them into a single executable, `system-update.sh`, which is the thing you actually run or install.

```
system-update/
├── build.sh            # concatenates src/ into system-update.sh
├── make-release.sh     # builds + slims comments -> ./system-update (release asset)
├── system-update.sh    # the built, runnable script
├── tests/
│   └── filter_log.bats # regression tests for the log-filtering function
├── .github/workflows/
│   ├── ci.yml          # build + shellcheck + bats on push / PR
│   └── release.yml     # tag-driven release build & publish
└── src/
    ├── main.sh         # argument parsing + run order
    └── lib/
        ├── logging.sh      # logging, colors, traps, shared run helpers
        ├── dependencies.sh # checks (and offers to install) required tools
        ├── snapshot.sh     # optional pre-update Timeshift snapshot (-s)
        ├── updates.sh      # pacman (+ keyring & disk checks), cache, orphans, .pacnew
        ├── aur.sh          # yay
        ├── flatpak.sh      # flatpak
        ├── archnews.sh     # Arch news check via informant
        ├── github.sh       # self-update from a GitHub release
        └── kernel.sh       # kernel report + reboot advisory
```

## How a few things work

**Dependency check.** On every run, the script verifies the tools it needs are present (a `command -v` sweep — cheap enough to do each time). If something's missing it lists it and offers to install it. Because this gate runs every time, the other modules don't repeat per-command checks. A dry-run never installs anything; it just reports what's missing.

**Logging without breaking the terminal.** Piping a command into `tee` normally strips colors and confuses tools into auto-answering prompts. Interactive steps instead run inside a pseudo-terminal via `script`, so colors, progress bars, and `[Y/n]` prompts work; the captured output is then color-stripped into the log. For steps that need root, `sudo` wraps `script` (rather than sitting inside it) so the password prompt happens on the real terminal and a single cached credential is reused for the whole run:

```bash
sudo script -eqc "pacman -Syu --color=always" /dev/null | tee "$tmp"
# $tmp is then filtered (ANSI + progress redraws stripped) and appended to the log
```

Logs land in `$XDG_STATE_HOME/system-update/` and rotate once they pass ~2 MB. On-screen colors are suppressed automatically when output isn't a terminal or when `NO_COLOR` is set.

**Safety checks.** Before upgrading it checks the Arch news feed (via `informant`), a stale pacman `db.lck`, and free disk space, then refreshes `archlinux-keyring` only if a newer one is pending — the usual cause of mid-upgrade signature errors — staying quiet when it's already current. It also prints a count of pending official updates. After upgrading it flags `.pacnew`/`.pacsave` files to merge and warns if the running kernel differs from the one now on disk (reboot recommended), and closes with a one-line summary of what ran.

**Pre-update snapshot (`-s`).** Optionally takes a Timeshift snapshot before any package changes, so a bad upgrade can be rolled back. Timeshift picks its own backend — native snapshots on Btrfs, incremental `rsync` on ext4 and everything else — so this works regardless of filesystem. It's best-effort: if Timeshift isn't installed it prints the install command and continues; if the snapshot itself fails it asks whether to proceed without one. Timeshift isn't part of a stock Arch install, so `-s` is a no-op until you `sudo pacman -S timeshift`.

## Build, test & run

```bash
./build.sh          # build system-update.sh from src/
./system-update.sh  # run it; offers to install system-wide on first run
bats tests/         # run the filter_log regression tests
```

If `shellcheck` is installed, `build.sh` runs it and fails the build on errors. CI (`.github/workflows/ci.yml`) runs the build, shellcheck, and the `bats` tests on every push and pull request.

## Self-update

`system-update -u` checks the latest GitHub release and offers to upgrade in place. The repository is public, so no token is needed. When run from a clone it reads the repo from the git remote; the installed copy in `/usr/local/bin` has no git metadata, so set the repo once — either edit `SCRIPT_REPO` in `src/lib/github.sh` (the `OWNER/REPO` placeholder) or export `SYSUPDATE_REPO=owner/repo`.

## Releasing

A release attaches a single file named `system-update` (no extension — the name the self-updater downloads) to a GitHub release. Build it locally with:

```bash
./make-release.sh   # builds + slims comments -> ./system-update
```

The slimming only removes whole-line comments and blank runs (inline code is untouched), and the result is re-checked with `bash -n`.

To publish, tag a version matching `VERSION` in `src/lib/logging.sh` and push it:

```bash
git tag v1.9.0-beta && git push origin v1.9.0-beta
```

The `.github/workflows/release.yml` Action then builds, lints, verifies the tag matches `VERSION`, and creates the release with `system-update` attached (tags containing a hyphen, like `-beta`, are marked pre-release). The slimmed asset is a build artifact — no need to commit it.

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
| `-s` | timeshift | Pre-update snapshot (rollback safety; ext4 via rsync) | off |
| `-e` | — | Everything: `-pFcaof` (pacman, flatpak, cache, AUR, orphans, fastfetch). Snapshot is *not* included — combine with `-s` if you want one. | — |
| `-d` | — | Dry-run: preview only, no changes | — |
| `-f` | fastfetch | Show a fastfetch system summary at the end | — |
| `-i` | — | Install to `/usr/local/bin` | — |
| `-u` | — | Check GitHub for a script update | — |
| `-V` | — | Print version and exit (also `--version`) | — |
| `-h` | — | Help (also `--help`) | — |

### Examples

```bash
system-update           # standard: pacman + flatpak + cache trim
system-update -e        # everything: pacman + flatpak + cache + AUR + orphans + fastfetch
system-update -es       # everything, with a pre-update snapshot first
system-update -ed       # dry-run across everything
system-update -ps       # snapshot, then a pacman upgrade
system-update -paf      # pacman + AUR + fastfetch
system-update -u        # check for a script update now
system-update -V        # print version and exit
```

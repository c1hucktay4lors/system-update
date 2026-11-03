#!/bin/bash
#====================================================================
# RELEASE RUNNER: system-update v1.9.0
#====================================================================
# Run in your normal terminal (where `gh` is authenticated):
#
#     bash release-1.9.0.sh
#
# What it does, in order:
#   1. Preflight: gh auth, git identity, VERSION string
#   2. Rebuilds system-update.sh + slim `system-update` asset
#   3. Clones the repo, copies the 3 changed files to the Claude branch
#   4. SHOWS the diff, then asks before committing + pushing
#   5. Creates GitHub release v1.9.0 (stable) with BOTH assets attached:
#        - system-update      (slim; the name the self-updater downloads)
#        - system-update.sh   (full; back-compat for older installs)
#   6. Verifies the release via the GitHub API
#   7. Offers to install v1.9.0 to /usr/local/bin on this machine
#====================================================================
set -euo pipefail

REPO="c1hucktay4lors/system-update"
BRANCH="Claude"
TAG="v1.9.0"
TITLE="System-update v1.9.0"

cd "$(dirname "$0")"
PROJ="$(pwd)"

#--------------------------------------------------------------------
# 1. PREFLIGHT
#--------------------------------------------------------------------
echo "==> Preflight checks"

command -v gh >/dev/null || { echo "  [FAIL] gh CLI not found (pacman -S gh)"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "  [FAIL] gh is not authenticated — run: gh auth login"; exit 1; }
echo "  [OK] gh authenticated as: $(gh api user -q .login 2>/dev/null || echo 'unknown')"

if ! git config user.email >/dev/null; then
    echo "  [FAIL] git user.email not set — run: git config --global user.email you@example.com"
    exit 1
fi
echo "  [OK] git identity: $(git config user.name) <$(git config user.email)>"

grep -q 'VERSION="1.9.0"' src/lib/logging.sh || { echo "  [FAIL] VERSION in src/lib/logging.sh is not 1.9.0"; exit 1; }
echo "  [OK] VERSION=1.9.0"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "  [FAIL] release $TAG already exists on $REPO — nothing to do."
    exit 1
fi
echo "  [OK] release $TAG does not exist yet"

#--------------------------------------------------------------------
# 2. BUILD
#--------------------------------------------------------------------
echo
echo "==> Building"
bash build.sh
bash make-release.sh
bash -n system-update && bash -n system-update.sh
echo "  [OK] both assets pass bash -n"
echo "  [OK] $(./system-update -V)"

#--------------------------------------------------------------------
# 3. PREPARE CLAUDE BRANCH
#--------------------------------------------------------------------
echo
echo "==> Preparing branch '$BRANCH'"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gh repo clone "$REPO" "$WORK/clone"
cd "$WORK/clone"
git checkout "$BRANCH" 2>&1 | tail -1

# The three files that differ from the branch (everything else is identical).
cp "$PROJ/system-update.sh"    system-update.sh
cp "$PROJ/src/lib/logging.sh"  src/lib/logging.sh
cp "$PROJ/README.md"           README.md
git add -A

echo
echo "==> Changes about to be committed:"
git status --short
git diff --cached --stat
echo

read -r -p "Commit and push these changes to the '$BRANCH' branch? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted before push."; exit 1; }

git commit -m "v1.9.0: rebuild with LC_ALL=C locale fix, bump VERSION to 1.9.0, refresh README release tag"
git push origin "$BRANCH"
echo "  [OK] pushed to $REPO ($BRANCH)"

#--------------------------------------------------------------------
# 4. CREATE RELEASE
#--------------------------------------------------------------------
echo
echo "==> Creating release $TAG (stable)"

NOTES="$WORK/notes.md"
cat > "$NOTES" <<'EOF'
## What's new

Since v1.4.0:

- **AUR updates (`-a`)** — `yay -Sua`, PTY-logged so build prompts and colors survive
- **Orphan removal (`-o`)** — lists orphans, asks before `pacman -Rns`
- **Pre-update snapshot (`-s`)** — optional Timeshift snapshot (Btrfs CoW or rsync) before any package change, so a bad upgrade can be rolled back
- **Arch news gate** — checks `informant` for unread critical news and asks before upgrading
- **Kernel audit + reboot advisory** — reports running vs installed kernels; a "REBOOT RECOMMENDED" banner if the running kernel's module tree is gone
- **Safety rails** — stale `db.lck` detection, free-disk-space guard, smart `archlinux-keyring` refresh (only when newer), pending-update count
- **.pacnew/.pacsave review** — surfaces config files to merge via `pacdiff`
- **Dependency gate** — every run verifies required tools and offers to install what's missing
- **Single sudo prompt** — credential cached up front and kept warm for the whole run
- **Clean logging** — interactive capture via pty, ANSI-stripped log at `~/.local/state/system-update/` with ~2 MB rotation, `NO_COLOR` aware
- **Self-update (`-u`)** — checks the GitHub release and upgrades in place (weekly by default)
- **Dry-run (`-d`)** — preview any combination of flags, change nothing

## Fixes

- **Locale crash**: `sed: Invalid range end` on every log line in UTF-8 locales — ANSI stripping now pinned to `LC_ALL=C`
- **Self-update asset name**: this release attaches `system-update`, the exact name the self-updater downloads (previous releases only had `system-update.sh`, so `-u` could never find it). Both files are attached for compatibility with older installed copies.

## Install / update

```bash
# one-time install:
curl -fsSL https://github.com/c1hucktay4lors/system-update/releases/download/v1.9.0/system-update \
  | sudo tee /usr/local/bin/system-update >/dev/null && sudo chmod +x /usr/local/bin/system-update

# or, if already installed:
system-update -u
```
EOF

cd "$PROJ"
gh release create "$TAG" \
    --repo "$REPO" \
    --target "$BRANCH" \
    --title "$TITLE" \
    --notes-file "$NOTES" \
    "$PROJ/system-update" \
    "$PROJ/system-update.sh"
echo "  [OK] release created"

#--------------------------------------------------------------------
# 5. VERIFY
#--------------------------------------------------------------------
echo
echo "==> Verifying release"
gh release view "$TAG" --repo "$REPO" --json tagName,isPrerelease,assets,url \
  --jq '"  tag:         " + .tagName
        + "\n  prerelease:  " + (.isPrerelease|tostring)
        + "\n  assets:      " + (.assets | map(.name) | join(", "))
        + "\n  url:         " + .url'

echo
echo "==> Self-update asset lookup test (what `system-update -u` does):"
DL_URL=$(curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases" \
    | jq -r '.[0].assets[] | select(.name=="system-update") | .browser_download_url')
echo "  [OK] latest release asset 'system-update' resolves to:"
echo "       $DL_URL"

#--------------------------------------------------------------------
# 6. OPTIONAL LOCAL INSTALL
#--------------------------------------------------------------------
echo
read -r -p "Install v1.9.0 to /usr/local/bin on this machine now? [y/N] " inst
if [[ "$inst" =~ ^[Yy]$ ]]; then
    sudo cp "$PROJ/system-update.sh" /usr/local/bin/system-update
    sudo chmod +x /usr/local/bin/system-update
    echo "  [OK] installed:"
    system-update -V
fi

echo
echo "==> Done. Release $TAG is live at:"
echo "    https://github.com/$REPO/releases/tag/$TAG"

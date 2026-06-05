#!/bin/bash
#====================================================================
# SYSTEM TOOL: Release Asset Builder
#====================================================================
# MODULE_VERSION: 1.0
#--------------------------------------------------------------------
# Builds the single-file script and produces a slimmed release asset
# named 'system-update' (the exact name the self-updater downloads).
#
# Slimming removes WHOLE-LINE comments and blank runs only; inline code
# is never touched, so it cannot corrupt '#' inside strings, ${#var},
# $#, or regexes. The result is re-checked with `bash -n`.
#====================================================================

set -uo pipefail

SRC="system-update.sh"
ASSET="system-update"

echo "Building $SRC ..."
bash build.sh >/dev/null || { echo "build failed"; exit 1; }

# Keep the shebang (line 1). From the rest: drop whole-line comments,
# blank out whitespace-only lines, then squeeze blank runs to one.
{
    head -n 1 "$SRC"
    tail -n +2 "$SRC" \
        | sed -E '/^[[:space:]]*#/d; s/^[[:space:]]+$//' \
        | cat -s
} > "$ASSET"
chmod +x "$ASSET"

# Safety: the slimmed asset must still parse cleanly.
if ! bash -n "$ASSET"; then
    echo "ERROR: slimmed asset failed syntax check; not releasing." >&2
    exit 1
fi

full=$(wc -c < "$SRC")
slim=$(wc -c < "$ASSET")
printf '%s built: %d bytes (from %d — %d%% smaller)\n' \
    "$ASSET" "$slim" "$full" "$(( (full - slim) * 100 / full ))"
echo "Attach '$ASSET' to a GitHub release (or let the Actions workflow do it on a tag push)."

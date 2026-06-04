#!/bin/bash
#====================================================================
# SYSTEM TOOL: Modular Script Asset Compiler
#====================================================================
# MODULE_VERSION: 1.1
#--------------------------------------------------------------------
# Concatenates the source modules in src/ into a single standalone
# executable (system-update.sh).
#====================================================================

set -uo pipefail

TARGET="system-update.sh"
SRC_DIR="src"
LIB_DIR="$SRC_DIR/lib"

GREEN="\e[32m"
BLUE="\e[34m"
RED="\e[31m"
RESET="\e[0m"

echo -e "${BLUE}Starting system-update compilation...${RESET}"

# 1. Initialize target with the shebang (must be the literal first line).
echo "#!/bin/bash" > "$TARGET"

# 2. Core logging/env module first (defines set flags, colors, helpers).
if [[ -f "$LIB_DIR/logging.sh" ]]; then
    echo -e "  -> Linking Core: logging.sh"
    echo -e "\n# --- MODULE: logging.sh ---" >> "$TARGET"
    cat "$LIB_DIR/logging.sh" >> "$TARGET"
else
    echo -e "${RED}Error: Core logging.sh missing from $LIB_DIR${RESET}"
    exit 1
fi

# 3. Append the remaining modules.
for module in "$LIB_DIR"/*.sh; do
    if [[ -f "$module" && "$(basename "$module")" != "logging.sh" ]]; then
        echo -e "  -> Linking Module: $(basename "$module")"
        echo -e "\n# --- MODULE: $(basename "$module") ---" >> "$TARGET"
        cat "$module" >> "$TARGET"
    fi
done

# 4. Append the orchestrator last.
echo -e "\n# --- CORE: main.sh ---" >> "$TARGET"
cat "$SRC_DIR/main.sh" >> "$TARGET"

# 5. Make it executable.
chmod +x "$TARGET"

# 6. Optional lint pass: fail the build on real errors if shellcheck exists.
if command -v shellcheck &>/dev/null; then
    echo -e "  -> Running shellcheck..."
    if shellcheck -S error "$TARGET"; then
        echo -e "  -> shellcheck: no errors"
    else
        echo -e "${RED}✘ shellcheck reported errors in $TARGET${RESET}"
        exit 1
    fi
else
    echo -e "  -> shellcheck not installed; skipping lint (install it for CI-grade checks)."
fi

echo -e "${GREEN}✔ Compilation successful! $TARGET created. Run -h for usage.${RESET}"

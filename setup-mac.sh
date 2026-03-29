#!/bin/bash
# setup-mac.sh
# One-time setup for a new Mac. Safe to run multiple times (idempotent).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Checking prerequisites..."

if ! command -v podman &>/dev/null; then
    echo "ERROR: Podman not found. Install with: brew install podman"
    exit 1
fi

if ! command -v fish &>/dev/null; then
    echo "ERROR: Fish not found. Install with: brew install fish"
    exit 1
fi

echo "==> Initialising Podman machine (if not already running)..."
if ! podman machine list | grep -q "running"; then
    podman machine init 2>/dev/null || true
    podman machine start
else
    echo "    Podman machine already running, skipping."
fi

echo "==> Configuring global gitignore..."
GITIGNORE_GLOBAL="$HOME/.gitignore_global"
touch "$GITIGNORE_GLOBAL"

for entry in ".github-token" ".dev-init.fish"; do
    if ! grep -qxF "$entry" "$GITIGNORE_GLOBAL"; then
        echo "$entry" >> "$GITIGNORE_GLOBAL"
        echo "    Added $entry to $GITIGNORE_GLOBAL"
    else
        echo "    $entry already in $GITIGNORE_GLOBAL, skipping."
    fi
done

git config --global core.excludesfile "$GITIGNORE_GLOBAL"
echo "    Set core.excludesfile to $GITIGNORE_GLOBAL"

echo "==> Creating ~/projects directory..."
mkdir -p "$HOME/projects"

echo "==> Installing dev function into fish config..."
FISH_CONFIG="$HOME/.config/fish/config.fish"
mkdir -p "$HOME/.config/fish"
touch "$FISH_CONFIG"

DEV_FUNCTION_SOURCE="$SCRIPT_DIR/fish/dev.fish"

if ! grep -q "function dev" "$FISH_CONFIG"; then
    echo "" >> "$FISH_CONFIG"
    echo "# Sandboxed development environment — loaded from $DEV_FUNCTION_SOURCE" >> "$FISH_CONFIG"
    echo "source $DEV_FUNCTION_SOURCE" >> "$FISH_CONFIG"
    echo "    Added dev function to $FISH_CONFIG"
else
    echo "    dev function already in $FISH_CONFIG"
    echo "    If you want to update it, the source line points to $DEV_FUNCTION_SOURCE"
    echo "    Edit that file directly — changes take effect on next fish reload."
fi

echo ""
echo "✓ Mac setup complete."
echo ""
echo "Next steps:"
echo "  1. Reload fish config:   source ~/.config/fish/config.fish"
echo "  2. Build the image:      podman build -t devenv -f Dockerfile.dev ."
echo "  3. Start a project:      dev <project-name>"

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

for entry in ".github-token" ".dev-init.fish" ".devenv-parent"; do
    if ! grep -qxF "$entry" "$GITIGNORE_GLOBAL"; then
        echo "$entry" >> "$GITIGNORE_GLOBAL"
        echo "    Added $entry to $GITIGNORE_GLOBAL"
    else
        echo "    $entry already in $GITIGNORE_GLOBAL, skipping."
    fi
done

git config --global core.excludesfile "$GITIGNORE_GLOBAL"
echo "    Set core.excludesfile to $GITIGNORE_GLOBAL"

echo "==> Configuring safe git hooks path..."
# Prevent sandbox escape: without this, an agent inside the container could
# plant malicious hooks in /workspace/.git/hooks/ which would execute on
# the Mac when the user runs git outside the container.
# Global config is the baseline (covers non-fish contexts like GUI tools).
# The fish env vars below provide command-line-level precedence that cannot
# be overridden by local .git/config — this is the primary defense.
SAFE_HOOKS_DIR="$HOME/.config/git/hooks"
mkdir -p "$SAFE_HOOKS_DIR"
git config --global core.hooksPath "$SAFE_HOOKS_DIR"
echo "    Set core.hooksPath to $SAFE_HOOKS_DIR"

echo "==> Creating ~/projects directory..."
mkdir -p "$HOME/projects"

echo "==> Configuring user identity..."
DEVENV_CONFIG_DIR="$HOME/.config/devenv"
DEVENV_CONFIG="$DEVENV_CONFIG_DIR/config"
mkdir -p "$DEVENV_CONFIG_DIR"

if [ -f "$DEVENV_CONFIG" ]; then
    echo "    Config already exists at $DEVENV_CONFIG, skipping."
else
    read -p "Your full name (for git commits): " user_name
    read -p "Your email (for git commits): " user_email

    if [ -z "$user_name" ] || [ -z "$user_email" ]; then
        echo "ERROR: Name and email are required."
        exit 1
    fi

    echo "DEVENV_USER_NAME=$user_name" > "$DEVENV_CONFIG"
    echo "DEVENV_USER_EMAIL=$user_email" >> "$DEVENV_CONFIG"
    echo "    Saved to $DEVENV_CONFIG"
fi

echo "==> Installing dev function into fish config..."
FISH_CONFIG="$HOME/.config/fish/config.fish"
mkdir -p "$HOME/.config/fish"
touch "$FISH_CONFIG"

DEV_FUNCTION_SOURCE="$SCRIPT_DIR/fish/dev.fish"

if grep -q "source.*dev.fish" "$FISH_CONFIG"; then
    echo "    dev function already sourced from $DEV_FUNCTION_SOURCE"
elif ! grep -q "function dev" "$FISH_CONFIG"; then
    echo "" >> "$FISH_CONFIG"
    echo "# Sandboxed development environment — loaded from $DEV_FUNCTION_SOURCE" >> "$FISH_CONFIG"
    echo "source $DEV_FUNCTION_SOURCE" >> "$FISH_CONFIG"
    echo "    Added dev function to $FISH_CONFIG"
else
    echo "    Found inline 'dev' function — replacing with source line..."
    # Create a temp file with the inline function removed and source line added
    python3 -c "
import re, sys
with open('$FISH_CONFIG') as f:
    content = f.read()
# Remove the inline function block (function dev ... end)
content = re.sub(r'\n*# Sandboxed development environment[^\n]*\n', '\n', content)
content = re.sub(r'function dev\b.*?^end\n?', '', content, flags=re.DOTALL | re.MULTILINE)
# Append the source line
content = content.rstrip() + '\n\n# Sandboxed development environment — loaded from $DEV_FUNCTION_SOURCE\nsource $DEV_FUNCTION_SOURCE\n'
with open('$FISH_CONFIG', 'w') as f:
    f.write(content)
"
    echo "    Replaced inline function with: source $DEV_FUNCTION_SOURCE"
fi

# Force core.hooksPath at command-line precedence via git env vars.
# Git config precedence: system < global < local < command-line.
# GIT_CONFIG_COUNT/KEY/VALUE have command-line precedence, so a malicious
# .git/config inside /workspace cannot override the hooks path.
HOOKS_ENV_MARKER="GIT_CONFIG_COUNT"
if ! grep -q "$HOOKS_ENV_MARKER" "$FISH_CONFIG"; then
    cat >> "$FISH_CONFIG" << 'HOOKEOF'

# Sandbox safety: force core.hooksPath at command-line precedence.
# Prevents agents from overriding hooksPath via local .git/config.
set -gx GIT_CONFIG_COUNT 1
set -gx GIT_CONFIG_KEY_0 core.hooksPath
set -gx GIT_CONFIG_VALUE_0 ~/.config/git/hooks
HOOKEOF
    echo "    Added git hooks env vars to $FISH_CONFIG"
else
    echo "    Git hooks env vars already in $FISH_CONFIG, skipping."
fi

echo "==> Installing shared workflow docs..."
mkdir -p "$HOME/workflows"
cp -r "$SCRIPT_DIR/docs/workflows/"* "$HOME/workflows/"
echo "    Installed to $HOME/workflows"

echo "==> Installing Claude Code skills and agents..."
CLAUDE_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_DIR"
# Copy skills and agents from claude-config/ to ~/.claude/, preserving directory structure.
# Existing files are overwritten to pick up updates from the repository.
cp -r "$SCRIPT_DIR/claude-config/skills" "$CLAUDE_DIR/" 2>/dev/null || true
cp -r "$SCRIPT_DIR/claude-config/agents" "$CLAUDE_DIR/" 2>/dev/null || true
# Copy CLAUDE.md and other root-level config files (but not skills/agents dirs again)
for f in "$SCRIPT_DIR/claude-config"/*; do
    if [ -f "$f" ]; then
        cp "$f" "$CLAUDE_DIR/"
    fi
done
echo "    Installed to $CLAUDE_DIR"

echo "==> Installing Claude Code plugins..."
if command -v claude &>/dev/null; then
    if ! claude plugin list 2>/dev/null | grep -q "codex@openai-codex"; then
        claude plugin marketplace add openai/codex-plugin-cc
        claude plugin install codex@openai-codex
        echo "    Installed codex plugin"
    else
        echo "    Codex plugin already installed, skipping."
    fi
else
    echo "    Claude Code not found — skipping plugin install (install Claude Code first)"
fi

echo "==> Building container image..."
podman build -t devenv -f "$SCRIPT_DIR/Dockerfile.dev" "$SCRIPT_DIR"

echo ""
echo "✓ Mac setup complete."
echo ""
echo "Next steps:"
echo "  1. Reload fish config:   source ~/.config/fish/config.fish"
echo "  2. Start a project:      dev <project-name>"

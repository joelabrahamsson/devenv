#!/bin/bash
# setup-mac.sh
# One-time setup for a new Mac. Safe to run multiple times (idempotent).
#
# Flags:
#   --reconfigure-reviewers   Clear and re-prompt for the reviewer configuration
#                             (CLAUDE_REVIEWER, CODEX_REVIEWER, REVIEWER_COPILOT_MODEL)
#                             stored in ~/.config/devenv/config.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RECONFIGURE_REVIEWERS=0
case " $* " in
    *" --reconfigure-reviewers "*) RECONFIGURE_REVIEWERS=1 ;;
esac

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

echo "==> Configuring reviewer..."
# If --reconfigure-reviewers was passed, strip any existing reviewer keys so the
# missing-key path below re-prompts. Use a same-directory temp file so the rename
# is intra-filesystem and atomic (mv across filesystems falls back to copy+delete).
if [ "$RECONFIGURE_REVIEWERS" -eq 1 ] && [ -f "$DEVENV_CONFIG" ]; then
    tmp_config=$(mktemp "$DEVENV_CONFIG_DIR/.config.XXXXXXXX")
    grep -v -E '^(CLAUDE_REVIEWER|CODEX_REVIEWER|REVIEWER_COPILOT_MODEL)=' \
        "$DEVENV_CONFIG" > "$tmp_config" || true
    mv "$tmp_config" "$DEVENV_CONFIG"
    echo "    Cleared existing reviewer keys"
fi

# Multi-pass key-presence check:
#   - CLAUDE_REVIEWER and CODEX_REVIEWER are always required.
#   - REVIEWER_COPILOT_MODEL is required only if either reviewer is "copilot".
existing_claude_reviewer=""
existing_codex_reviewer=""
existing_copilot_model=""
if [ -f "$DEVENV_CONFIG" ]; then
    existing_claude_reviewer=$(grep '^CLAUDE_REVIEWER=' "$DEVENV_CONFIG" | head -n1 | cut -d= -f2-)
    existing_codex_reviewer=$(grep '^CODEX_REVIEWER=' "$DEVENV_CONFIG" | head -n1 | cut -d= -f2-)
    existing_copilot_model=$(grep '^REVIEWER_COPILOT_MODEL=' "$DEVENV_CONFIG" | head -n1 | cut -d= -f2-)
fi

needs_copilot_model=0
if [ "$existing_claude_reviewer" = "copilot" ] || [ "$existing_codex_reviewer" = "copilot" ]; then
    needs_copilot_model=1
fi

reviewer_config_complete=0
if [ -n "$existing_claude_reviewer" ] && [ -n "$existing_codex_reviewer" ]; then
    if [ "$needs_copilot_model" -eq 0 ] || [ -n "$existing_copilot_model" ]; then
        reviewer_config_complete=1
    fi
fi

if [ "$reviewer_config_complete" -eq 1 ]; then
    echo "    Reviewer config already set, skipping."
    CLAUDE_REVIEWER="$existing_claude_reviewer"
    CODEX_REVIEWER="$existing_codex_reviewer"
    REVIEWER_COPILOT_MODEL="$existing_copilot_model"
else
    # Prompt for any missing keys. Empty input takes the default.
    if [ -n "$existing_claude_reviewer" ]; then
        CLAUDE_REVIEWER="$existing_claude_reviewer"
    else
        while true; do
            read -p "Reviewer for Claude Code skills (plan-review / implement-plan)? [codex/copilot] (default: codex): " ans
            ans=${ans:-codex}
            case "$ans" in
                codex|copilot) CLAUDE_REVIEWER="$ans"; break ;;
                *) echo "    Please enter 'codex' or 'copilot'." ;;
            esac
        done
    fi

    if [ -n "$existing_codex_reviewer" ]; then
        CODEX_REVIEWER="$existing_codex_reviewer"
    else
        while true; do
            read -p "Reviewer for Codex skills (plan-review / implement-plan)? [claude/copilot] (default: claude): " ans
            ans=${ans:-claude}
            case "$ans" in
                claude|copilot) CODEX_REVIEWER="$ans"; break ;;
                *) echo "    Please enter 'claude' or 'copilot'." ;;
            esac
        done
    fi

    REVIEWER_COPILOT_MODEL=""
    if [ "$CLAUDE_REVIEWER" = "copilot" ] || [ "$CODEX_REVIEWER" = "copilot" ]; then
        if [ -n "$existing_copilot_model" ]; then
            REVIEWER_COPILOT_MODEL="$existing_copilot_model"
        else
            while true; do
                read -p "Copilot model to use for reviews? [gpt-5.4/gpt-5.3-codex/gpt-5.2] (default: gpt-5.4): " ans
                ans=${ans:-gpt-5.4}
                case "$ans" in
                    gpt-5.4|gpt-5.3-codex|gpt-5.2) REVIEWER_COPILOT_MODEL="$ans"; break ;;
                    *) echo "    Please enter one of: gpt-5.4, gpt-5.3-codex, gpt-5.2." ;;
                esac
            done
        fi
    fi

    # Persist via temp-file-and-mv: drop any stale reviewer keys, then append the new ones.
    tmp_config=$(mktemp "$DEVENV_CONFIG_DIR/.config.XXXXXXXX")
    if [ -f "$DEVENV_CONFIG" ]; then
        grep -v -E '^(CLAUDE_REVIEWER|CODEX_REVIEWER|REVIEWER_COPILOT_MODEL)=' \
            "$DEVENV_CONFIG" > "$tmp_config" || true
    fi
    {
        echo "CLAUDE_REVIEWER=$CLAUDE_REVIEWER"
        echo "CODEX_REVIEWER=$CODEX_REVIEWER"
        if [ -n "$REVIEWER_COPILOT_MODEL" ]; then
            echo "REVIEWER_COPILOT_MODEL=$REVIEWER_COPILOT_MODEL"
        fi
    } >> "$tmp_config"
    mv "$tmp_config" "$DEVENV_CONFIG"
    echo "    Saved reviewer config to $DEVENV_CONFIG"
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

echo "==> Installing shell aliases..."
FISH_FUNCTIONS="$HOME/.config/fish/functions"
mkdir -p "$FISH_FUNCTIONS"
# Remove old hand-created function files and replace with managed versions
for old_file in "$FISH_FUNCTIONS/gst.fish" "$FISH_FUNCTIONS/gst=git.fish"; do
    rm -f "$old_file"
done
cat > "$FISH_FUNCTIONS/gst.fish" << 'ALIASEOF'
function gst --wraps='git status' --description 'alias gst=git status'
  git status $argv
end
ALIASEOF
echo "    Installed gst alias"

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
INSTALL_COPILOT=0
INSTALL_CODEX=0
if [ "$CLAUDE_REVIEWER" = "copilot" ] || [ "$CODEX_REVIEWER" = "copilot" ]; then
    INSTALL_COPILOT=1
fi
# Codex CLI is needed only on the Claude side (where the dispatch path runs
# `codex exec`). The Codex-side skills invoke `claude`, not `codex`, so
# CODEX_REVIEWER=claude does NOT require the Codex CLI to be installed.
if [ "$CLAUDE_REVIEWER" = "codex" ]; then
    INSTALL_CODEX=1
fi
BUILD_DATE=$(date -u +%FT%TZ)
if git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_SHA=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)
    if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null)" ]; then
        GIT_SHA="${GIT_SHA}+dirty"
    fi
else
    GIT_SHA="unknown"
fi
echo "    Build args: INSTALL_COPILOT=$INSTALL_COPILOT INSTALL_CODEX=$INSTALL_CODEX"
echo "    Build info: DEVENV_BUILD_DATE=$BUILD_DATE DEVENV_GIT_SHA=$GIT_SHA"
podman build \
    --build-arg INSTALL_COPILOT="$INSTALL_COPILOT" \
    --build-arg INSTALL_CODEX="$INSTALL_CODEX" \
    --build-arg DEVENV_BUILD_DATE="$BUILD_DATE" \
    --build-arg DEVENV_GIT_SHA="$GIT_SHA" \
    -t devenv -f "$SCRIPT_DIR/Dockerfile.dev" "$SCRIPT_DIR"

echo ""
echo "✓ Mac setup complete."
echo ""
echo "Next steps:"
echo "  1. Reload fish config:   source ~/.config/fish/config.fish"
echo "  2. Start a project:      dev <project-name>"

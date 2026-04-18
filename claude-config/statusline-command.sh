#!/bin/sh
# Claude Code status line script

input=$(cat)

# Git repo name (top-level directory name of the git repo)
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -n "$cwd" ]; then
  repo=$(GIT_DIR="$cwd/.git" GIT_WORK_TREE="$cwd" git --git-dir="$cwd/.git" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
fi

# Git branch
if [ -n "$cwd" ]; then
  branch=$(GIT_DIR="$cwd/.git" GIT_WORK_TREE="$cwd" git --git-dir="$cwd/.git" symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(GIT_DIR="$cwd/.git" GIT_WORK_TREE="$cwd" git --git-dir="$cwd/.git" rev-parse --short HEAD 2>/dev/null)
  fi
fi

# Effort level (output style name)
effort=$(echo "$input" | jq -r '.output_style.name // empty')

# Context usage percentage
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Build output
parts=""

if [ -n "$repo" ] && [ -n "$branch" ]; then
  parts="${repo}:${branch}"
elif [ -n "$repo" ]; then
  parts="${repo}"
elif [ -n "$branch" ]; then
  parts="${branch}"
fi

if [ -n "$effort" ] && [ "$effort" != "default" ]; then
  if [ -n "$parts" ]; then
    parts="${parts}  ${effort}"
  else
    parts="${effort}"
  fi
fi

if [ -n "$used" ]; then
  used_int=$(printf '%.0f' "$used")
  if [ -n "$parts" ]; then
    parts="${parts}  ctx:${used_int}%"
  else
    parts="ctx:${used_int}%"
  fi
fi

printf '%s' "$parts"

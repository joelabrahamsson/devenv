# Global Container Instructions

These instructions apply to all projects inside the dev container.

## Consulting GPT via Copilot CLI

GitHub Copilot CLI is available in this container. When the user asks you to "consult with gpt", "ask gpt", "get a second opinion", or similar, use Copilot CLI to query GPT:

```bash
copilot -p "your prompt here" --allow-all
```

Pass relevant context (code snippets, file contents, diffs) directly in the prompt. Use this for code reviews, architecture feedback, debugging ideas, or any situation where a second opinion would be valuable.

## Bug Fix Workflow

When fixing bugs, follow a TDD red-green workflow by default:

1. **Red** — write a failing test that reproduces the bug. Run the test to confirm it fails for the expected reason.
2. **Green** — fix the bug with the minimal change needed. Run the test to confirm it passes.
3. Run the full relevant test suite to confirm no regressions.

Do not skip the failing test step. The test proves the bug exists and prevents regressions. Only skip this workflow if the user explicitly asks to, or if the bug is in code that has no test infrastructure.

## Missing Tools and Browsers

This container has system dependencies pre-installed, but user-space tools (like Playwright browsers) may need to be installed on first use. If a tool or browser is missing, install it rather than concluding it can't run. For example:
- Playwright: `npx playwright install chromium`
- Other tools: check the tool's docs for a user-space install command

You have write access to your home directory and node_modules — most installs work without root.

## Git Worktrees

You can create git worktrees inside this container (e.g., `git worktree add /home/dev/wt-branch feature-branch`). Temporary worktrees for parallel agent tasks work fine.

However, worktrees created inside the container are **ephemeral** — they live on the container filesystem and are lost if the container is removed or rebuilt. Only `/workspace` is persisted to the host.

For long-lived parallel branch work, ask the user to run `dev-worktree <project> <branch>` on the Mac side instead. That creates a separate container with its own isolation.

## Container Resources

This container has 8 GB of memory and 4 CPUs. Do not artificially limit processes with flags like `--max-old-space-size=512`. Run builds, tests, and tools with their default memory settings — the container has plenty of headroom.

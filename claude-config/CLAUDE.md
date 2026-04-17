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

## Docker and Test Infrastructure

This container runs inside a sandboxed environment with a dedicated Docker-in-Docker (DinD) daemon. A filtering proxy controls what Docker operations are allowed.

**What works:**
- `docker compose up`, `docker compose down`, `docker compose ps`, `docker compose logs`, `docker compose exec`, `docker compose run`, `docker compose pull`
- `localhost:<port>` — compose services that publish ports are reachable at localhost (e.g., postgres at `localhost:5432`)

**What does NOT work:**
- `docker compose build` — blocked by the proxy; use pre-built images only
- `docker exec`, `docker run`, `docker build`, `docker images`, `docker ps`, or any direct `docker` command — only `docker compose` is available
- Bind-mounting host paths into compose services
- Pulling images not on the allowlist

**To interact with a running service** (e.g., run psql against postgres), use `docker compose exec`:
```bash
docker compose exec postgres psql -U postgres -d mydb -c "\dt"
```

**NOT** `docker exec container-name ...` — that will fail.

**If an image is blocked**, ask the user to add it to the allowlist on the host. Do not attempt workarounds.

## Container Resources

This container has 8 GB of memory and 4 CPUs. Do not artificially limit processes with flags like `--max-old-space-size=512`. Run builds, tests, and tools with their default memory settings — the container has plenty of headroom.

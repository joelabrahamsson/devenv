# Global Container Instructions

These instructions apply to all projects inside the dev container.

## Bug Fix Workflow

When fixing bugs, follow a TDD red-green workflow by default:

1. **Red** — write a failing test that reproduces the bug. Run the test to confirm it fails for the expected reason.
2. **Green** — fix the bug with the minimal change needed. Run the test to confirm it passes.
3. Run the full relevant test suite to confirm no regressions.

Do not skip the failing test step. The test proves the bug exists and prevents regressions. Only skip this workflow if the user explicitly asks to, or if the bug is in code that has no test infrastructure.

## Consulting an alternate model for a second opinion

A second-opinion CLI is installed in this container based on the user's reviewer configuration. The choice is exposed via two env vars: `$CODEX_REVIEWER` (`copilot` or `claude`) and `$REVIEWER_COPILOT_MODEL` (only meaningful when Copilot is the chosen reviewer). **Do not assume Copilot is available** — read `$CODEX_REVIEWER` first.

When the user asks for a second opinion, dispatch based on the captured value:

```bash
# If $CODEX_REVIEWER is "copilot":
copilot -p "your prompt here" --model "$REVIEWER_COPILOT_MODEL" --allow-all

# If $CODEX_REVIEWER is "claude":
claude -p "your prompt here" --dangerously-skip-permissions --no-session-persistence
```

The reviewer can be reconfigured by running `bash setup-mac.sh --reconfigure-reviewers` on the Mac, then `dev <project> --rebuild`.

## Missing Tools and Browsers

This container has system dependencies pre-installed, but user-space tools (like Playwright browsers) may need to be installed on first use. If a tool or browser is missing, install it rather than concluding it can't run. For example:
- Playwright: `npx playwright install chromium`
- Other tools: check the tool's docs for a user-space install command

You have write access to your home directory and node_modules — most installs work without root.

## Git Worktrees

You can create git worktrees inside this container (e.g., `git worktree add /home/dev/wt-branch feature-branch`). Temporary worktrees for parallel agent tasks work fine.

However, worktrees created inside the container are **ephemeral** — they live on the container filesystem and are lost if the container is removed or rebuilt. Only `/workspace` is persisted to the host.

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

## Secrets and Test Environments

Project file contents you read — including `.env` values and command output — get sent to OpenAI as part of conversation context. The container sandbox protects the Mac; it does not prevent secrets inside `/workspace` from leaving in conversation context. Treat real credentials accordingly:

- For tests, prefer a `.env.test` (or framework-equivalent) populated with dummy values, and configure the test runner to load it explicitly. Do not run tests against the project's real `.env` unless the user asks for it.
- Never `cat`, `echo`, or otherwise print the contents of `.env`, `.env.*`, `*.pem`, `*.key`, or files under `secrets/` or `credentials/`. If you need to confirm a variable exists, check its name, not its value.
- If a test fails with an error message that would dump a real connection string, API key, or token, stop and tell the user rather than re-running with more logging.

## Container Resources

This container has 8 GB of memory and 4 CPUs. Do not artificially limit processes with flags like `--max-old-space-size=512`. Run builds, tests, and tools with their default memory settings — the container has plenty of headroom.

## Image Build Info

This image bakes two env vars at build time:

- `$DEVENV_BUILD_DATE` — UTC ISO timestamp of the build
- `$DEVENV_GIT_SHA` — devenv-repo commit the image was built from (suffixed `+dirty` if the working tree had uncommitted changes when built; `unknown` if not built through `setup-mac.sh`)

Run `devenv-version` for a human-readable summary, or `echo $DEVENV_BUILD_DATE $DEVENV_GIT_SHA` for raw values. If you suspect the image is stale (e.g., a documented skill behavior isn't taking effect), report both to the user — they can compare against the devenv repo on their Mac and refresh with `bash setup-mac.sh` then `dev <project> --rebuild`.

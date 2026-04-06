# Sandboxed Development Environment

A reproducible, sandboxed development environment using Podman containers on macOS. Each project runs in its own isolated container with fish shell, Node.js, Python, and Claude Code pre-installed.

## Philosophy and Reasoning

### Why containers for development?

The primary motivation is running Claude Code with `--dangerously-skip-permissions`, which allows agents to execute commands without prompting for approval. This unlocks much faster AI-assisted development (no interruptions), but requires a safety net: if an agent runs a destructive command, it should only affect the container, not your Mac.

Containers give us:
- **Isolation**: Agent can't read `~/.ssh/`, `~/.aws/`, or other sensitive Mac files
- **Reproducibility**: Every project starts from the same known-good image
- **Cleanup**: Destroying a container undoes everything the agent did
- **Per-project scoping**: Each project has its own container, credentials, and dependencies

### Why Podman over Docker Desktop / Colima?

Podman is daemonless — each container runs as its own process rather than through a central daemon. This means no background service consuming memory when you're not using it, and containers run rootless by default (better security model).

### Why per-project GitHub tokens?

Rather than using a single GitHub credential with broad access, each project gets a fine-grained token scoped to only that repository. If an agent somehow exfiltrates a token, the blast radius is limited to one repo.

### Why fish shell inside the container?

Consistency with the Mac development environment. Using the same shell everywhere reduces cognitive overhead and means muscle memory transfers.

### Bundled Skills and Agents

The environment includes custom skills and agents (in `claude-config/`) for a plan → implement → finalize workflow. Each skill can be used independently or as a pipeline. Reviews always run in parallel using both a Claude agent and GitHub Copilot CLI.

**`/plan-review [description]`** — Planning phase
1. Enters plan mode and creates a detailed TDD-structured plan
2. Runs two parallel adversarial reviews (Claude agent + Copilot CLI)
3. Consolidates feedback, revises the plan, saves to `docs/plans/`
4. Offers to implement immediately, compact context first, or save for later

**`/implement-plan [path]`** — Implementation phase
1. Reads the plan and creates a task list from its steps
2. Delegates each step to a Sonnet subagent following strict TDD (red → green → refactor)
3. Runs the full test suite to verify everything works end-to-end
4. Runs two parallel adversarial code reviews (Claude agent + Copilot CLI)
5. Consolidates feedback and fixes issues
6. Offers to commit+push, create a PR, or run `/finalize`

**`/finalize [path]`** — Documentation and shipping phase
1. Reads the plan + git diff to understand what was built and why
2. Generates an ADR in `docs/adrs/` capturing the reasoning behind decisions
3. Deletes the plan file
4. Offers to commit+push or create a PR

**Supporting agents:**
- **adversarial-reviewer** — reviews plans for completeness, TDD coverage, bug risk, and compliance with project conventions
- **code-reviewer** — reviews implemented code for bugs, security, test quality, and adherence to the plan

TDD is enforced by default (skippable only if the plan explicitly says so). Plan files in `docs/plans/` bridge context between skills and sessions. ADRs capture reasoning, not just what was built.

### The `--dangerously-skip-permissions` flag

Claude Code normally asks permission before every file write or shell command. This flag disables those prompts, enabling uninterrupted agent execution. It's safe here because:
- The container has no access to Mac credentials
- Only the mounted project directory is accessible
- Git provides a complete undo history
- The container itself is disposable

Claude Code refuses to run with this flag as root, which is why the container uses a non-root `dev` user.

### Security boundaries and known limitations

The sandbox provides strong isolation from the Mac — agents cannot access Mac credentials, SSH keys, or files outside the mounted project directory. Within the Podman VM, additional layers enforce restrictions:

- **DinD sidecar** — each project gets its own isolated Docker daemon; the agent can only interact with it through the compose allowlist wrapper
- **Docker socket proxy** — all Docker API calls go through a filtering proxy that uses an allowlist of permitted endpoints. Container creation is inspected to block bind mounts, privileged mode, host namespaces, capabilities, devices, and sysctls. Exec creation blocks privileged exec. Image pulls are validated against the image allowlist. Unrecognised API endpoints are blocked by default.
- **Docker shim** — raw `docker` commands are blocked; only `docker compose` is allowed, routed through the allowlist wrapper
- **Image allowlist** — only pre-approved images can be used; both `image:` references, `FROM` directives in Dockerfiles, and direct image pulls via the Docker API are validated against `allowed-images.txt`
- **Credential proxy** — the GitHub token is stored in a root-only mount and served to git via a proxy that only responds for `github.com`. The agent cannot read the raw token directly
- **Git hooks protection** — `.git/hooks/` is made read-only inside the container and git is configured to use a safe hooks directory, preventing the agent from writing hooks that would execute on the Mac
- **Resource limits** — containers are capped at 8 GB memory, 4 CPUs, and 1024 PIDs to prevent runaway agents from DoSing the Mac
- **SELinux label override** (`--security-opt label=disable`) — required on macOS because the Podman VM's SELinux policy blocks socket and volume access otherwise. This disables MAC labeling inside the container but does not weaken the VM boundary

**Accepted risks:**
- **Outbound network** — containers have unrestricted internet access. An agent could exfiltrate source code. This is a trade-off for agent usability (pulling packages, accessing APIs). The blast radius is limited by using per-project tokens scoped to a single repository.
- **Credential proxy** — any process running as `dev` can query the credential proxy socket for `github.com` credentials. The token is per-repo scoped, limiting exposure.
- **Unpinned installer scripts** — some tools are installed via `curl | bash` without hash verification. These are from reputable sources (pyenv, uv, bun) and the image is only built locally.

---

## Prerequisites

- macOS with [Podman](https://podman.io) installed (`brew install podman`)
- [Fish shell](https://fishshell.com) installed (`brew install fish`) and set as default shell
- A GitHub account

---

## Mac Setup

Run the Mac setup script once on a new machine:

```bash
bash setup-mac.sh
```

This script:
1. Initialises the Podman VM
2. Configures the global gitignore (excludes `.github-token`, `.dev-init.fish`, `.devenv-parent`)
3. Prompts for your name and email (used for git commits inside containers) and saves them to `~/.config/devenv/config`
4. Installs the `dev` function into your fish config
5. Creates the `~/projects/` directory
6. Installs Claude Code skills and agents to `~/.claude/` (from `claude-config/`)
7. Builds the container image

After running, reload your fish config to pick up the `dev` function:

```bash
source ~/.config/fish/config.fish
```

Re-run `bash setup-mac.sh` after pulling changes to rebuild the image and pick up any updates. The script is idempotent — steps that are already done are skipped. Remember to reload your fish config afterwards if `fish/dev.fish` has changed.

---

## Container Image

The image includes:
- Fish shell (default shell)
- Node.js LTS (via NodeSource)
- npm
- nvm.fish (for per-project Node version switching)
- Python 3.13 (via pyenv)
- uv (fast Python package manager)
- GitHub CLI (`gh`)
- GitHub Copilot CLI (standalone, via npm)
- Claude Code
- Docker Compose (with image allowlist wrapper)
- Playwright system dependencies (run `npx playwright install chromium` for browsers)

---

## Starting a Project

```bash
dev <project-name>
```

On first run for a new project this will:
1. Prompt for a GitHub fine-grained token (see below)
2. Create a DinD sidecar container (`<project-name>-dind`) with an isolated Docker daemon
3. Create a dev container named `<project-name>`
4. Mount `~/projects/<project-name>` as `/workspace`
5. Mount `node_modules` as a separate volume (isolates Linux/Mac native binaries)
6. Configure git with your identity and credential helper
7. Drop you into a fish shell inside the container

On subsequent runs it simply starts the container and opens a shell.

**Note:** Since `node_modules` is a separate volume, you need to run `npm ci` (or equivalent) inside the container after creating it. Your Mac's `node_modules` is unaffected — each environment maintains its own.

### Creating a GitHub Token

When prompted, go to:
**github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**

Suggested settings:
- **Name**: same as your project
- **Repository access**: Only select repositories → pick the specific repo
- **Permissions**:
  - **Contents**: Read & Write
  - **Pull requests**: Read & Write — for creating and updating PRs via `gh`
  - **Metadata**: Read

The token is saved to `~/.config/devenv/tokens/<project-name>` on your Mac — outside both the repository and the container's workspace mount. Existing tokens at `~/projects/<project-name>/.github-token` are automatically migrated on first use.

Inside the container, the agent **cannot read the raw token**. Git credentials are served via a credential proxy (a small service running as root that reads the token from a root-only mount). The `gh` CLI and Copilot CLI are authenticated via `gh auth login` at container creation — auth state is stored inside the container, not the raw token.

---

## Daily Usage

```bash
# Enter a project
dev myproject

# Remove a project's containers and infrastructure (keeps project files and token)
dev-rm myproject

# Open an additional shell in the same container (from another terminal)
dev-shell myproject

# Inside the container — run Claude Code with full autonomy
superclaude  # alias for: claude --dangerously-skip-permissions

# GitHub Copilot CLI — suggest commands or explain them
copilot suggest "undo last git commit but keep changes"
copilot explain "git rebase -i HEAD~3"

# Ask Claude to consult GPT for a second opinion (uses Copilot CLI)
# Just say "consult with gpt" or "ask gpt to review this"
```

---

## Newlines in Claude Code (containers)

Podman's PTY layer doesn't pass Shift+Enter through to Claude Code inside containers. **Ctrl+J** is pre-configured as an alternative newline keybinding (via `claude-config/keybindings.json`).

If you prefer Shift+Enter, configure your terminal emulator to send a newline for that key. In iTerm2:

1. Open **Preferences → Profiles → Keys → Key Mappings**
2. Click **+** to add a new mapping
3. Set the shortcut to **Shift+Enter**
4. Set the action to **Send Text** with value `\n`

---

## Docker Compose / Test Infrastructure

Containers can spin up test infrastructure (databases, queues, etc.) via Docker Compose. Each project has its own DinD (Docker-in-Docker) sidecar with a fully isolated Docker daemon.

Both `docker compose` and `docker-compose` syntax work inside the container. The agent cannot use raw `docker` commands — a shim only allows `docker compose`, which goes through the allowlist wrapper before reaching the DinD daemon.

### DinD (Docker-in-Docker) sidecar

Each project gets its own DinD container (`<project>-dind`) running a fully isolated Docker daemon. Compose services run inside DinD, giving each project its own network namespace, port space, and container lifecycle.

This means two projects — or two worktrees of the same project — can each run postgres on port 5432 without collision. `localhost:5432` works as usual. Docker-compose files work identically inside and outside the sandbox.

The DinD container runs privileged (required for Docker-in-Docker) but is created by the trusted Mac-side `dev` script, not by the agent. The agent only interacts with DinD through docker-compose, which goes through the allowlist wrapper.

### Image allowlist

Only images listed in `docker-allowlist/allowed-images.txt` are permitted. The allowlist is mounted read-only so the agent cannot modify it.

Images are matched by their full name (without tag). For example, the entry `postgres` matches `postgres:15` but **not** `evil-registry.com/postgres` or `postgresexploit`. Services using `build:` are allowed — the wrapper validates the `FROM` directives in the referenced Dockerfiles against the allowlist.

To add a new allowed image, edit `docker-allowlist/allowed-images.txt` on your Mac and recreate the container:

```bash
dev myproject --rebuild
```

---

## Worktrees

To work on multiple branches of the same project simultaneously, each in its own isolated container:

```bash
dev-worktree myproject fix/some-branch
```

This creates a git worktree at `~/projects/myproject-fix/some-branch`, then launches a dev container for it with its own DinD sidecar. Both the main project and the worktree can run their own postgres, redis, etc. without port collisions. The GitHub token is shared with the parent project automatically. If the branch doesn't exist, it is created from HEAD.

Use `--rebuild` to recreate the worktree's container:

```bash
dev-worktree myproject fix/some-branch --rebuild
```

To remove a worktree and all its infrastructure (container, DinD, volume, network):

```bash
dev-worktree-rm myproject fix/some-branch
```

---

## Updating Claude Code

Claude Code is installed in the image. To update, re-run the setup script and recreate containers:

```bash
bash setup-mac.sh
dev myproject --rebuild
```

---

## Credential Persistence

Auth state is persisted on the Mac and survives container rebuilds:

- **GitHub token** — per-project, stored at `~/.config/devenv/tokens/<project>`. Git credentials and `gh` auth are set up automatically on container creation. Worktrees share the parent project's token.
- **Claude Code** — shared across all projects, stored at `~/.config/devenv/claude-state/`. Login once with `claude /login` and it works in all containers.
- **Copilot CLI** — shared across all projects, stored at `~/.config/devenv/copilot-state/`. Login once with `copilot -i` then `/login`. Copilot uses a separate OAuth device flow — the GitHub PAT is not sufficient.

---

## Repository Structure

```
.
├── README.md                          # This file
├── CLAUDE.md                          # Instructions for agents working on this repo
├── Dockerfile.dev                     # Container image definition
├── setup-mac.sh                       # One-time Mac setup (also re-run to update)
├── claude-config/                     # Copied to ~/.claude/ in containers and on Mac
│   ├── CLAUDE.md                      # Global Claude Code instructions for all projects
│   ├── keybindings.json               # Ctrl+J newline binding for containers
│   ├── skills/
│   │   ├── plan-review/SKILL.md       # /plan-review — planning with adversarial review
│   │   ├── implement-plan/SKILL.md    # /implement-plan — TDD implementation via subagents
│   │   └── finalize/SKILL.md          # /finalize — ADR generation + ship
│   └── agents/
│       ├── adversarial-reviewer/      # Plan review agent (Sonnet)
│       └── code-reviewer/             # Code review agent (Sonnet)
├── fish/
│   └── dev.fish                       # dev, dev-shell, dev-worktree, dev-worktree-rm functions
└── docker-allowlist/
    ├── allowed-images.txt             # Permitted Docker images for test infrastructure
    ├── credential-proxy.py            # Serves git credentials over Unix socket (root-only)
    ├── docker-compose-wrapper.sh      # Validates images + sets up socat port forwarding
    ├── docker-shim.sh                 # Only allows `docker compose`, blocks other commands
    ├── docker-socket-proxy.py         # Filters Docker API calls (blocks bind mounts, privileged, etc.)
    └── git-credential-proxy.sh        # Git credential helper that queries the credential proxy
```

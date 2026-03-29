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

### Compound Engineering Plugin

Claude Code is configured with the [Compound Engineering Plugin](https://github.com/EveryInc/compound-engineering-plugin) by Every.to. This provides a set of specialized agents and workflow commands that implement the Plan → Work → Review → Compound loop:

- `/ce:plan` — spawns parallel research agents to build an implementation plan
- `/ce:work` — executes the plan with progress tracking
- `/ce:review` — spawns 14 specialized review agents in parallel (security, performance, architecture, etc.)
- `/ce:compound` — documents learnings for future sessions

The plugin is pre-installed in the container image so it's available without any manual setup.

### The `--dangerously-skip-permissions` flag

Claude Code normally asks permission before every file write or shell command. This flag disables those prompts, enabling uninterrupted agent execution. It's safe here because:
- The container has no access to Mac credentials
- Only the mounted project directory is accessible
- Git provides a complete undo history
- The container itself is disposable

Claude Code refuses to run with this flag as root, which is why the container uses a non-root `dev` user.

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
2. Configures the global gitignore (excludes `.github-token` and `.dev-init.fish`)
3. Installs the `dev` function into your fish config
4. Creates the `~/projects/` directory

Then reload your fish config:

```bash
source ~/.config/fish/config.fish
```

---

## Building the Container Image

Build the base image once. Rebuild whenever you update `Dockerfile.dev` (e.g. to upgrade Claude Code or add new tools):

```bash
podman build -t devenv -f Dockerfile.dev .
```

The image includes:
- Fish shell (default shell)
- Node.js LTS (via NodeSource)
- npm, pnpm
- nvm.fish (for per-project Node version switching)
- Python 3.13 (via pyenv)
- uv (fast Python package manager)
- GitHub CLI (`gh`)
- Claude Code
- Compound Engineering Plugin (pre-installed into `~/.claude/`)
- Docker Compose (with image allowlist wrapper)
- Bun (required by Compound Engineering tooling)

---

## Starting a Project

```bash
dev <project-name>
```

On first run for a new project this will:
1. Prompt for a GitHub fine-grained token (see below)
2. Create a container named `<project-name>`
3. Mount `~/projects/<project-name>` as `/workspace`
4. Configure git with your identity and credential helper
5. Drop you into a fish shell inside the container

On subsequent runs it simply starts the container and opens a shell.

### Creating a GitHub Token

When prompted, go to:
**github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**

Suggested settings:
- **Name**: same as your project
- **Repository access**: Only select repositories → pick the specific repo
- **Permissions**: Contents (Read & Write), Metadata (Read)

The token is saved to `~/projects/<project-name>/.github-token` on your Mac (outside the container). It's excluded from git via the global gitignore.

---

## Daily Usage

```bash
# Enter a project
dev myproject

# Inside the container — run Claude Code with full autonomy
claude --dangerously-skip-permissions

# Typical compound engineering session
# /ce:plan Add user notifications
# /ce:work
# /ce:review
# /ce:compound
```

---

## Docker Compose / Test Infrastructure

Containers can spin up sibling containers (databases, queues, etc.) via the Podman socket. The `dev` function mounts the socket and an image allowlist into the container.

Only images listed in `docker-allowlist/allowed-images.txt` are permitted. The allowlist is mounted read-only so the agent cannot modify it.

To add a new allowed image, edit `docker-allowlist/allowed-images.txt` on your Mac and recreate the container:

```bash
podman rm -f myproject
dev myproject
```

---

## Updating Claude Code

Claude Code is installed in the image. To update it, rebuild the image:

```bash
podman build -t devenv -f Dockerfile.dev .
```

Existing containers are not affected until you recreate them (`podman rm -f <project>`).

---

## Credential Persistence

Credentials (gh auth, claude login) persist inside a container as long as the container exists. They survive `podman stop` / `podman start`. They are lost when you `podman rm` the container.

After recreating a container you need to:
1. Run `gh auth login` inside the container
2. Run `claude` and `/login` inside the container

The GitHub token for git operations does not need to be re-entered — it's stored on the Mac side and wired up automatically by the `dev` function.

---

## Repository Structure

```
.
├── README.md                          # This file
├── Dockerfile.dev                     # Container image definition
├── setup-mac.sh                       # One-time Mac setup script
├── fish/
│   └── dev.fish                       # The `dev` function (sourced by setup-mac.sh)
└── docker-allowlist/
    ├── allowed-images.txt             # Permitted Docker images for test infrastructure
    └── docker-compose-wrapper.sh     # Wrapper that enforces the allowlist
```

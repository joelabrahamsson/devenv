# devenv — Sandboxed Development Environment

A sandboxed development environment for macOS that lets AI coding agents run with full autonomy inside isolated Podman containers. Each project gets its own container with fish shell, Node.js, Python, Claude Code, and Docker Compose — with no access to your Mac's credentials, SSH keys, or files outside the project directory.

The primary use case is running Claude Code with `--dangerously-skip-permissions` (aliased as `superclaude`), which disables permission prompts and enables uninterrupted agent execution. The sandbox ensures that if an agent runs something destructive, it only affects the container.

---

## Prerequisites

- macOS with [Podman](https://podman.io) installed (`brew install podman`)
- [Fish shell](https://fishshell.com) installed (`brew install fish`) and set as default shell
- A GitHub account

---

## Setup

Run the setup script once on a new Mac:

```bash
bash setup-mac.sh
```

This initialises the Podman VM, prompts for your name and email (for git commits), installs the `dev` shell function and safety-critical git config into your fish config, copies Claude Code skills and agents to `~/.claude/`, and builds the container image.

After running, reload fish:

```bash
source ~/.config/fish/config.fish
```

Re-run `bash setup-mac.sh` after pulling changes to pick up updates. The script is idempotent. Reload fish afterwards if `fish/dev.fish` has changed.

---

## Starting a Project

```bash
dev myproject
```

On first run this will:
1. Prompt for a GitHub fine-grained token scoped to that repository
2. Create a DinD sidecar with an isolated Docker daemon
3. Create a dev container with `~/projects/myproject` mounted as `/workspace`
4. Configure git, credential helper, and `gh` CLI auth
5. Drop you into a fish shell

On subsequent runs it starts the existing container and opens a shell.

### Creating a GitHub Token

When prompted, go to **github.com → Settings → Developer settings → Fine-grained tokens → Generate new token**.

Suggested settings:
- **Repository access**: Only select repositories → pick the specific repo
- **Permissions**: Contents (Read & Write), Pull requests (Read & Write), Metadata (Read)

The token is saved to `~/.config/devenv/tokens/<project>` on your Mac — outside the repo and the container workspace. Inside the container, the agent cannot read the raw token; git credentials are served via a proxy that only responds for `github.com`.

---

## Daily Usage

```bash
# Enter a project
dev myproject

# Open an additional shell in the same container
dev-shell myproject

# Remove containers and infrastructure (keeps project files and token)
dev-rm myproject

# Rebuild after image or config changes
dev myproject --rebuild

# Inside the container — run Claude Code with full autonomy
superclaude
```

### Docker Compose / Test Infrastructure

Projects can run test infrastructure (Postgres, Redis, etc.) via Docker Compose. Each project has its own DinD sidecar with a fully isolated Docker daemon — two projects can each run postgres on port 5432 without collision.

Both `docker compose` and `docker-compose` work. Raw `docker` commands are blocked. Only images listed in `docker-allowlist/allowed-images.txt` are permitted. To allow a new image, edit the file on your Mac and run `dev myproject --rebuild`.

### Worktrees

Work on multiple branches of the same project simultaneously, each in its own isolated container:

```bash
# Create a worktree container (creates the branch if it doesn't exist)
dev-worktree myproject fix/some-branch

# Remove a worktree and all its infrastructure
dev-worktree-rm myproject fix/some-branch
```

The GitHub token is shared with the parent project automatically.

---

## Bundled Skills and Agents

The environment includes custom Claude Code skills and agents (in `claude-config/`) for a **plan → implement → finalize** workflow. Each skill can be used independently or as a pipeline. Reviews run in parallel using both a Claude agent and GitHub Copilot CLI.

### `/plan-review [description]` — Planning

Enters plan mode, explores the codebase, and creates a detailed TDD-structured implementation plan. Two adversarial reviews run in parallel (a Claude agent and Copilot CLI). Feedback is consolidated, the plan is revised, and saved to `docs/plans/`. You can then implement immediately, compact context first, or save for later.

### `/implement-plan [path]` — Implementation

Reads the plan and delegates each step to a Sonnet subagent following strict TDD (red → green → refactor). After all steps pass, the full test suite runs, then two parallel adversarial code reviews (Claude agent + Copilot CLI) catch remaining issues. Offers to commit, create a PR, or run `/finalize`.

### `/finalize [path]` — Documentation and shipping

Reads the plan and git diff, generates an Architecture Decision Record in `docs/adrs/` capturing the reasoning behind decisions, deletes the plan file, and offers to commit or create a PR.

### Supporting agents

- **adversarial-reviewer** — reviews plans for completeness, TDD coverage, risk, and adherence to project conventions
- **code-reviewer** — reviews code for bugs, security, test quality, and adherence to the plan

TDD is enforced by default. Plan files in `docs/plans/` bridge context between skills and sessions. ADRs capture reasoning, not just what was built.

---

## Credential Persistence

Auth state survives container rebuilds:

- **GitHub token** — per-project, at `~/.config/devenv/tokens/<project>`. Worktrees share the parent's token.
- **Claude Code** — shared across projects, at `~/.config/devenv/claude-state/`. Login once with `claude /login`.
- **Copilot CLI** — shared across projects, at `~/.config/devenv/copilot-state/`. Login once with `copilot -i` then `/login`.

---

## Newlines in Claude Code

Podman's PTY layer doesn't pass Shift+Enter through. **Ctrl+J** is pre-configured as an alternative newline keybinding (via `claude-config/keybindings.json`).

For Shift+Enter in iTerm2: Preferences → Profiles → Keys → Key Mappings → add Shift+Enter → Send Text → `\n`.

---

## Container Image

The image includes: fish shell, Node.js LTS, nvm.fish, Python 3.13 (pyenv), uv, GitHub CLI, GitHub Copilot CLI, Claude Code, Docker Compose, and Playwright system dependencies.

---

## Repository Structure

```
.
├── Dockerfile.dev                     # Container image definition
├── setup-mac.sh                       # One-time Mac setup (re-run to update)
├── claude-config/                     # Copied to ~/.claude/ in containers and on Mac
│   ├── CLAUDE.md                      # Global Claude Code instructions for all projects
│   ├── settings.json                  # Claude Code settings (skip permission prompt)
│   ├── keybindings.json               # Ctrl+J newline binding
│   ├── skills/
│   │   ├── plan-review/SKILL.md       # /plan-review — planning with adversarial review
│   │   ├── implement-plan/SKILL.md    # /implement-plan — TDD implementation via subagents
│   │   └── finalize/SKILL.md          # /finalize — ADR generation + ship
│   └── agents/
│       ├── adversarial-reviewer/      # Plan review agent
│       └── code-reviewer/             # Code review agent
├── fish/
│   └── dev.fish                       # dev, dev-shell, dev-worktree, dev-rm functions
└── docker-allowlist/
    ├── allowed-images.txt             # Permitted Docker images
    ├── credential-proxy.py            # Serves git credentials over Unix socket
    ├── docker-compose-wrapper.sh      # Validates images + socat port forwarding
    ├── docker-shim.sh                 # Only allows `docker compose`
    ├── docker-socket-proxy.py         # Filters Docker API calls
    └── git-credential-proxy.sh        # Git credential helper
```

---

## Security Model

The sandbox provides strong isolation from the Mac. Agents cannot access Mac credentials, SSH keys, or files outside the mounted project directory. Within the container, multiple layers enforce restrictions:

- **Docker socket proxy** — all Docker API calls go through a filtering proxy with an allowlist of permitted endpoints. Container creation is inspected to block bind mounts, privileged mode, host namespaces, capabilities, devices, and sysctls. A background thread re-applies socket permissions every 5 seconds to defend against DinD restarts.
- **Image allowlist** — only pre-approved images can be pulled or used. Enforced at both the compose wrapper and Docker API level. `image:` references, `FROM` directives, and direct API pulls are all validated.
- **Docker shim** — raw `docker` commands are blocked; only `docker compose` is allowed.
- **Credential proxy** — the GitHub token is in a root-only mount, served to git via a proxy that only responds for `github.com`. The agent cannot read the token file directly.
- **Git hooks protection** — Mac-side fish config forces `core.hooksPath` to an empty directory at command-line precedence (via `GIT_CONFIG_COUNT` env vars), so agents cannot plant hooks that execute on the Mac. Inside the container, `.git/hooks` is symlinked to `/dev/null` as a secondary barrier.
- **Privilege limits** — non-root user, `no-new-privileges`, 8 GB memory, 4 CPUs, 1024 PIDs.

### Accepted risks

- **Outbound network** — containers have unrestricted internet access. An agent could exfiltrate source code. This is a trade-off for usability (pulling packages, accessing APIs). Per-project tokens scoped to a single repository limit the blast radius.
- **Credential proxy extraction** — any process running as `dev` can query the credential proxy for `github.com` credentials. The proxy prevents passive discovery and misdirected use, not determined extraction.
- **Unpinned installers** — some tools are installed via `curl | bash` without hash verification. These are from reputable sources and the image is only built locally.

---

## Philosophy

### Why containers?

The primary motivation is running AI agents with `--dangerously-skip-permissions`. This unlocks much faster agent-assisted development (no permission prompts), but requires a safety net: if an agent runs a destructive command, it should only affect the container, not your Mac.

Containers also give reproducibility (every project starts from the same image), easy cleanup (destroy the container to undo everything), and per-project scoping (separate credentials, dependencies, and Docker daemons).

### Why Podman?

Podman is daemonless — no background service consuming memory when you're not using it. Containers run rootless by default for a better security baseline.

### Why per-project tokens?

Rather than a single GitHub credential with broad access, each project gets a fine-grained token scoped to one repository. If a token is compromised, the blast radius is one repo.

### Why fish shell?

Consistency with the Mac development environment. Same shell everywhere reduces cognitive overhead.

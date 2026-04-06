# Agent Instructions

This repository defines a sandboxed development environment for macOS using Podman containers. It is used both as documentation and as a setup guide that an agent can help execute.

## Purpose

When helping the user set up or modify this environment, follow this guidance:

## Setup Order

When setting up on a new machine, the correct order is:

1. Verify prerequisites (`podman`, `fish` installed)
2. Run `setup-mac.sh` to configure the Mac side
3. Reload fish config
4. Build the container image with `podman build`
5. Test with `dev <projectname>`

Never skip step 2 before step 4 — the `dev` function must exist before a container can be created.

## Key Files

- **`Dockerfile.dev`** — defines the container image. Edit this to add new tools or upgrade versions.
- **`setup-mac.sh`** — run once on a new Mac. Idempotent — safe to run again.
- **`fish/dev.fish`** — the `dev` shell function that manages containers. Sourced into `~/.config/fish/config.fish` by the setup script.
- **`docker-allowlist/allowed-images.txt`** — one image name prefix per line. Edit to allow new Docker images for test infrastructure.
- **`docker-allowlist/docker-compose-wrapper.sh`** — intercepts docker-compose calls and validates against the allowlist. Do not modify without understanding the security implications.
- **`docker-allowlist/credential-proxy.py`** — serves git credentials over a Unix socket. The agent queries this instead of reading the raw token.
- **`docker-allowlist/git-credential-proxy.sh`** — git credential helper that queries the credential proxy.
- **`claude-config/`** — copied to `~/.claude/` in the container image. Contains global Claude Code instructions (CLAUDE.md) and can hold skills or other config. Edit here, rebuild image to apply.

## Important Constraints

- The container runs as a non-root user (`dev`). This is required for `--dangerously-skip-permissions` to work with Claude Code.
- The Mac home directory is NOT mounted inside the container. This is intentional for sandboxing.
- Only `~/projects/<projectname>` is mounted, plus the docker allowlist (read-only) and Podman socket.
- The GitHub token is stored at `~/.config/devenv/tokens/<projectname>` on the Mac (not in the project directory).
- The token is mounted to a root-only path inside the container. The agent cannot read it directly — git credentials are served via a credential proxy over a Unix socket.
- The `gh` CLI is authenticated via `gh auth login` at container creation. Auth state is stored in `~/.config/gh/` inside the container — the raw token is never in the environment.
- GitHub Copilot CLI is installed in the container image via npm (`@github/copilot`).
- Credentials (claude login) live inside the container and are lost if the container is removed.
- Each project has its own DinD (Docker-in-Docker) sidecar with a fully isolated Docker daemon. Docker-compose services run inside DinD. `localhost:<port>` works normally. Multiple projects can run the same services on the same ports without collision.

## Common Tasks

**Add a new tool to the container:**
Edit `Dockerfile.dev`, add the install step in the appropriate place (before `USER dev` for system tools, after for user-space tools), then rebuild.

**Allow a new Docker image for test infrastructure:**
Add the image name prefix to `docker-allowlist/allowed-images.txt`. No rebuild needed — recreate the container with `podman rm -f <project> && dev <project>`.

**Upgrade Claude Code:**
Claude Code is installed via npm in the Dockerfile. Rebuild the image to get the latest version.

**Reset a project container:**
```bash
podman rm -f <projectname>
dev <projectname>
# then: gh auth login, claude /login
```

## User Details

User identity (name, email) is stored in `~/.config/devenv/config`, created by `setup-mac.sh` on first run.

- Shell: fish
- Primary languages: TypeScript/Node.js, Python

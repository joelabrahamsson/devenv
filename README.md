# devenv — Sandboxed Development Environment

A sandboxed development environment for macOS that lets AI coding agents run with full autonomy inside isolated Podman containers. Each project gets its own container with fish shell, Node.js, Python, Claude Code, and Docker Compose — with no access to your Mac's credentials, SSH keys, or files outside the project directory.

The primary use case is running AI coding agents with full autonomy — Claude Code with `--dangerously-skip-permissions` (aliased as `superclaude`) and OpenAI Codex CLI with `approval_policy = "never"` baked into the default config. Both skip permission prompts for uninterrupted agent execution. The sandbox ensures that if an agent runs something destructive, it only affects the container.

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

This initialises the Podman VM, prompts for your name and email (for git commits), installs the `dev` shell function and safety-critical git config into your fish config, copies Claude Code skills and agents to `~/.claude/`, installs Claude Code plugins (codex-plugin-cc), copies shared workflow docs to `~/workflows/`, and builds the container image.

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

### Port Forwarding

To access a web app running inside the container from your Mac's browser, use the `-p` flag to forward ports:

```bash
# Forward container port 3000 to Mac port 3000
dev myproject -p 3000:3000

# Forward multiple ports
dev myproject -p 3000:3000 -p 5173:5173

# Map to a different host port (Mac port 8080 → container port 3000)
dev myproject -p 8080:3000
```

The format is `-p HOST:CONTAINER` (same as Docker). Once forwarded, browse to `http://localhost:HOST` on your Mac.

Port mappings are set at container creation time. To change them on an existing container, use `--rebuild`:

```bash
dev myproject --rebuild -p 3000:3000 -p 5173:5173
```

### Docker Compose / Test Infrastructure

Projects can run test infrastructure (Postgres, Redis, etc.) via Docker Compose. Each project has its own DinD sidecar with a fully isolated Docker daemon — two projects can each run postgres on port 5432 without collision.

Both `docker compose` and `docker-compose` work. Raw `docker` commands are blocked. Only images listed in `docker-allowlist/allowed-images.txt` are permitted. To allow a new image, edit the file on your Mac and run `dev myproject --rebuild`.

### Worktrees

Work on multiple branches of the same project simultaneously, each in its own isolated container:

```bash
# Create a worktree container (creates the branch if it doesn't exist)
dev-worktree myproject fix/some-branch

# With port forwarding
dev-worktree myproject fix/some-branch -p 3000:3000

# Remove a worktree and all its infrastructure
dev-worktree-rm myproject fix/some-branch
```

The GitHub token is shared with the parent project automatically.

---

## Planning Workflow (Claude Code + Codex CLI)

The environment includes a **spec → plan → implement → finalize** workflow available in both Claude Code and Codex CLI. Each skill can be used independently or as a pipeline. Reviews run in parallel using cross-model adversarial review — both platforms use their own subagent plus Copilot CLI as second opinion (GPT-5.4 for Claude Code, Sonnet for Codex).

Shared workflow content (review criteria, plan format, spec format, TDD structure) lives in `docs/workflows/planning/` and is referenced by both platforms' skills at `~/workflows/planning/` inside the container.

### Claude Code

| Skill | Description |
|---|---|
| `/bdd-spec [feature]` | Conversational BDD spec authoring — elicits specs through structured dialogue, produces executable tests |
| `/plan-review [description]` | Explores codebase, creates TDD plan, runs parallel adversarial reviews (Claude agent + Copilot CLI), revises, saves to `docs/plans/` |
| `/implement-plan [path]` | Delegates each step to Sonnet subagents with strict TDD, runs a boy scout cleanup pass, then parallel code reviews |
| `/finalize [path]` | Generates ADR in `docs/adrs/`, deletes plan file, offers to commit or create PR |

### Codex CLI

| Skill | Description |
|---|---|
| `$bdd-spec [feature]` | Same conversational spec authoring workflow |
| `$plan-review [description]` | Same workflow, uses Codex subagent + Copilot CLI (Sonnet) for parallel reviews |
| `$implement-plan [path]` | Same workflow, uses Codex subagents + Copilot CLI (Sonnet) for code reviews |
| `$finalize [path]` | Same workflow (mostly platform-agnostic) |

### Specification tests

The `/bdd-spec` skill produces human-owned BDD specification tests through a four-stage conversation: **Understanding** (clarify the feature), **Scenario Outline** (agree on coverage at headline level), **Detailing** (full Given/When/Then steps), and **Challenge Round** (devil's advocate on gaps and assumptions). The agent elicits specs — it doesn't write them for you.

Spec tests form a durable layer of acceptance criteria that agents must not modify without explicit user approval. They sit above agent-written integration and unit tests in a three-tier test strategy:

1. **Specification tests** — human-owned, capture intent, small in number, durable
2. **Integration tests** — agent-written and human-reviewed
3. **Unit tests** — agent-written, disposable scaffolding

When spec files are passed to `/plan-review`, they become formal acceptance criteria in the plan. The existing spec test serves as the failing test (RED phase) for TDD steps that satisfy spec scenarios — no duplicate tests needed. `/implement-plan` runs spec tests as acceptance gates and instructs subagents to never modify spec files. Adversarial reviewers check both that spec files were not modified and that the implementation semantically satisfies the spec.

Example pipeline with specs:
```bash
/bdd-spec "user login with email and password"
# → conversational spec authoring
# → saves test/specs/authentication/user-login.spec.ts

/plan-review test/specs/authentication/user-login.spec.ts — also handle rate limiting and session expiry
# → spec becomes acceptance criteria, additional scope is planned alongside

/implement-plan docs/plans/2026-04-23-user-login.md
# → spec tests are read-only acceptance gates throughout implementation
```

Without specs, the pipeline works exactly as before — all spec-related behavior is opt-in.

### Testing and regression policy

Both `/implement-plan` and `$implement-plan` follow strict TDD: subagents run a *targeted* (inner-loop) test command during RED/GREEN/REFACTOR for fast feedback, and the *regression bar* (the project's full-suite gate) runs at commit boundaries. The plan inherits the regression bar verbatim from the project's CLAUDE.md / AGENTS.md, or uses a strict "run everything on every commit" default if none is documented.

**Adjusting the bar.** The regression bar comes from your project's convention docs. To make it tiered (e.g., fast tests on every commit, e2e at end of phase), document the tiering in the project's CLAUDE.md or AGENTS.md — `/plan-review` and `$plan-review` capture it verbatim into the plan, and the implementer follows whatever the plan says.

**Adjusting *when* the bar runs.** Projects with slow suites can opt out of per-commit gating by adding this line to CLAUDE.md or AGENTS.md:

```
Regression policy: defer to end-of-plan
```

When the marker is present, `/implement-plan` and `$implement-plan` skip the regression bar at every commit boundary; subagents run only the inner-loop targeted command. The orchestrator then runs the full regression bar exactly once at the end-of-plan verification step, before code review. This trades per-commit greenness for speed — useful when the suite takes minutes and the work spans many steps. Inner-loop failures are still never acceptable; only the *full-suite* run is deferred.

Default behavior (per-commit gating) is unchanged for projects without the marker. If your workflow relies on `git bisect` against the regression bar across intermediate commits, do not opt in.

### Supporting components

- **adversarial-reviewer** — reviews plans for completeness, TDD coverage, risk, spec awareness, and adherence to project conventions (Claude Code: named agent, Codex: subagent with `references/` instructions)
- **code-reviewer** — reviews code for bugs, security, test quality, spec integrity, and adherence to the plan
- **boyscout** — after implementation, cleans up touched files and their one-hop neighbors: removes dead code, fixes stale comments, corrects naming inconsistencies, and applies small quality improvements
- **Shared workflow docs** (`docs/workflows/planning/`) — review criteria, code review criteria, plan format, and spec format referenced by both platforms

TDD is enforced by default. Plan files in `docs/plans/` bridge context between skills and sessions. ADRs capture reasoning, not just what was built.

---

## Credential Persistence

Auth state survives container rebuilds:

- **GitHub token** — per-project, at `~/.config/devenv/tokens/<project>`. Worktrees share the parent's token.
- **Claude Code** — shared across projects, at `~/.config/devenv/claude-state/`. Login once with `claude /login`.
- **Copilot CLI** — shared across projects, at `~/.config/devenv/copilot-state/`. Login once with `copilot -i` then `/login`.
- **Codex CLI** — shared across projects, at `~/.config/devenv/codex-state/`. Login once with `codex login` (or `codex login --device-auth` for headless).

---

## Newlines in Claude Code

Podman's PTY layer doesn't pass Shift+Enter through. **Ctrl+J** is pre-configured as an alternative newline keybinding (via `claude-config/keybindings.json`).

For Shift+Enter in iTerm2: Preferences → Profiles → Keys → Key Mappings → add Shift+Enter → Send Text → `\n`.

---

## Container Image

The image includes: fish shell, Node.js LTS, pnpm, yarn, nvm.fish, Python 3.13 (pyenv), uv, GitHub CLI, GitHub Copilot CLI, Claude Code (with codex-plugin-cc), OpenAI Codex CLI (with `approval_policy = "never"`), Docker Compose, and Playwright system dependencies.

---

## Repository Structure

```
.
├── Dockerfile.dev                     # Container image definition
├── setup-mac.sh                       # One-time Mac setup (re-run to update)
├── docs/workflows/planning/           # Shared workflow docs (deployed to ~/workflows/)
│   ├── review-criteria.md             # Adversarial plan review checklist
│   ├── code-review-criteria.md        # Adversarial code review checklist
│   ├── plan-format.md                 # Plan file format and TDD structure
│   └── spec-format.md                 # Specification test conventions and format
├── claude-config/                     # Copied to ~/.claude/ in containers and on Mac
│   ├── CLAUDE.md                      # Global Claude Code instructions for all projects
│   ├── settings.json                  # Claude Code settings
│   ├── statusline-command.sh          # Status line script (repo, branch, effort, context)
│   ├── keybindings.json               # Ctrl+J newline binding
│   ├── skills/
│   │   ├── bdd-spec/SKILL.md          # /bdd-spec — conversational BDD spec authoring
│   │   ├── plan-review/SKILL.md       # /plan-review — planning with adversarial review
│   │   ├── implement-plan/SKILL.md    # /implement-plan — TDD implementation via subagents
│   │   └── finalize/SKILL.md          # /finalize — ADR generation + ship
│   └── agents/
│       ├── adversarial-reviewer/      # Plan review agent (refs ~/workflows/)
│       ├── boyscout/                  # Boy scout cleanup agent (post-implementation)
│       └── code-reviewer/             # Code review agent (refs ~/workflows/)
├── codex-config/                      # Copied to ~/.codex/ in containers
│   ├── AGENTS.md                      # Global Codex instructions for all projects
│   └── skills/
│       ├── bdd-spec/SKILL.md          # $bdd-spec — conversational BDD spec authoring
│       ├── plan-review/               # $plan-review — planning with adversarial review
│       │   ├── SKILL.md
│       │   └── references/            # Subagent instructions
│       ├── implement-plan/            # $implement-plan — TDD implementation via subagents
│       │   ├── SKILL.md
│       │   └── references/            # Subagent instructions
│       └── finalize/SKILL.md          # $finalize — ADR generation + ship
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
- **Conversation-context exposure** — project file contents read by the agent during normal operation (including `.env` values, source code, and command output) may be transmitted to Anthropic or OpenAI as part of conversation context. The sandbox protects the Mac and prevents lateral damage; it does not prevent the agent from reading and transmitting files within `/workspace`. For client work involving regulated data, NDAs, or production credentials, consider whether the project should run in this environment at all, or whether secrets should be replaced with vault references (e.g. 1Password CLI's `op run`) before agent sessions. The `claude-config/CLAUDE.md` and `codex-config/AGENTS.md` instructions steer agents toward `.env.test` for test runs to reduce accidental leakage, but this is a convention, not an enforcement mechanism.
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

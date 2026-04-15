# fish/dev.fish
# Manages sandboxed development containers via Podman.
# Sourced from ~/.config/fish/config.fish by setup-mac.sh.
#
# Functions:
#   dev <project-name> [--rebuild]       — create/enter a project container
#   dev-rm <project-name>               — remove a project's containers and infrastructure
#   dev-worktree <project> <branch> [--rebuild] — create a git worktree and enter its container
#   dev-worktree-rm <project> <branch>  — remove a worktree and its infrastructure
#   dev-shell <project-name>             — open an additional shell in a running container
#
# Each project gets a DinD (Docker-in-Docker) sidecar container that provides
# a fully isolated Docker daemon. Compose services run inside DinD, so
# multiple projects can each run postgres on port 5432 without collision.
#
# The GitHub token is stored at ~/.config/devenv/tokens/<project> on the Mac.
# It is mounted read-only to a root-only path inside the container and served
# to git via a credential proxy — the agent cannot read the raw token.
# Claude login lives inside the container and is lost on container removal.

function dev
    set project $argv[1]
    if test -z "$project"
        echo "Usage: dev <project-name> [--rebuild]"
        return 1
    end

    # --- Handle --rebuild flag ---
    if contains -- --rebuild $argv
        set dind_name "$project-dind"
        set dind_volume "$project-docker"
        set dind_network "$project-net"
        if podman container exists $project
            echo "Removing dev container '$project'..."
            podman rm -f $project
        end
        if podman container exists $dind_name
            echo "Removing DinD container '$dind_name'..."
            podman rm -f $dind_name
        end
        if podman volume exists $dind_volume
            echo "Removing DinD volume '$dind_volume'..."
            podman volume rm $dind_volume
        end
        if podman network exists $dind_network
            echo "Removing network '$dind_network'..."
            podman network rm $dind_network
        end
        set node_modules_volume "$project-node-modules"
        if podman volume exists $node_modules_volume
            echo "Removing node_modules volume '$node_modules_volume'..."
            podman volume rm $node_modules_volume
        end
        # Remove workspace node_modules volumes (pnpm workspaces)
        for vol in (podman volume ls --format '{{.Name}}' | grep "^$project-nm-")
            echo "Removing workspace node_modules volume '$vol'..."
            podman volume rm $vol
        end
    end

    # Resolve the devenv repo directory (parent of fish/)
    set devenv_dir (dirname (dirname (status filename)))

    mkdir -p ~/projects/$project

    # --- GitHub token setup ---
    # Token is stored outside the project directory so it's never visible
    # inside the container's /workspace mount. The credential proxy serves
    # it to git over a Unix socket.
    set token_dir ~/.config/devenv/tokens
    set token_file $token_dir/$project
    mkdir -p $token_dir

    # Migrate token from old location (~/projects/<project>/.github-token)
    set old_token_file ~/projects/$project/.github-token
    if test -f $old_token_file -a ! -f $token_file
        mv $old_token_file $token_file
        chmod 600 $token_file
        echo "✓ Migrated token from $old_token_file to $token_file"
    end

    if not test -f $token_file
        echo ""
        echo "No GitHub token found for '$project'."
        echo ""
        echo "Create a fine-grained token at:"
        echo "  https://github.com/settings/personal-access-tokens/new"
        echo ""
        echo "Suggested settings:"
        echo "  Name:               $project"
        echo "  Repository access:  Only select repositories → pick your repo"
        echo "  Permissions:"
        echo "    Contents:         Read & Write  (git push/pull)"
        echo "    Pull requests:    Read & Write  (create/update PRs)"
        echo "    Metadata:         Read          (required)"
        echo ""
        read --silent --prompt-str "Paste token (or press Enter to skip): " token
        if test -n "$token"
            echo $token > $token_file
            chmod 600 $token_file
            echo "✓ Token saved to $token_file"
        else
            echo "⚠ Skipping token setup — git push/pull and gh copilot may not work"
        end
        echo ""
    end

    # --- Container names ---
    set dind_name "$project-dind"
    set dind_volume "$project-docker"
    set dind_network "$project-net"

    # --- Create containers (first time only) ---
    set is_new 0
    if not podman container exists $project
        set is_new 1
        echo "Creating new containers for '$project'..."

        # Create a shared network and volume for the dev container and DinD sidecar.
        # The network lets the dev container reach compose services published by DinD.
        if not podman network exists $dind_network
            podman network create $dind_network
        end
        if not podman volume exists $dind_volume
            podman volume create $dind_volume
        end

        # Create the DinD sidecar — a fully isolated Docker daemon per project.
        # Runs privileged (required for DinD) but created by the trusted Mac-side
        # script, not by the agent. The agent only talks to it via docker-compose
        # through the allowlist wrapper.
        if not podman container exists $dind_name
            podman create \
                --name $dind_name \
                --network $dind_network \
                --privileged \
                --security-opt label=disable \
                -v $dind_volume:/var/run \
                -e DOCKER_TLS_CERTDIR="" \
                docker:27-dind
        end

        # label=disable is required on macOS — the Podman VM uses SELinux labels
        # that block socket and volume access without it.
        # Isolate node_modules so Linux and Mac binaries don't conflict.
        # The project directory is shared, but node_modules gets its own volume.
        # For pnpm workspaces, each package's node_modules also gets a volume.
        set node_modules_volume "$project-node-modules"
        if not podman volume exists $node_modules_volume
            podman volume create $node_modules_volume
        end

        set workspace_nm_args
        set project_dir ~/projects/$project
        if test -f $project_dir/pnpm-workspace.yaml
            # Find workspace package directories by resolving globs from pnpm-workspace.yaml.
            # Each package's node_modules gets its own volume to isolate Linux/Mac binaries.
            # Extract glob patterns (lines like "  - 'packages/*'") and resolve them.
            for line in (string match -r '^\s*-\s+.+' < $project_dir/pnpm-workspace.yaml)
                set pattern (string replace -r '^\s*-\s*' '' $line | string trim | string trim -c "'" | string trim -c '"')
                test -z "$pattern"; and continue
                set parent_dir (dirname $pattern)
                for pkg_dir in (find $project_dir/$parent_dir -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                    set rel_path (string replace "$project_dir/" "" $pkg_dir)
                    # Volume name: project-nm-<flattened-relative-path>
                    set vol_name "$project-nm-"(string replace -a '/' '-' $rel_path)
                    if not podman volume exists $vol_name
                        podman volume create $vol_name
                    end
                    set workspace_nm_args $workspace_nm_args \
                        -v $vol_name:/workspace/$rel_path/node_modules
                end
            end
        end

        set create_args -it \
            --name $project \
            --network $dind_network \
            -v ~/projects/$project:/workspace \
            -v $node_modules_volume:/workspace/node_modules \
            $workspace_nm_args \
            -v $devenv_dir/docker-allowlist:/etc/docker-allowlist:ro \
            -v $dind_volume:/var/run/docker-dind \
            --security-opt label=disable \
            --security-opt no-new-privileges \
            --env COMPOSE_PROJECT_NAME=$project \
            --env DOCKER_HOST=unix:///var/run/docker.sock \
            --memory 8g \
            --cpus 4 \
            --pids-limit 1024 \
            -w /workspace

        # If this is a worktree, mount the parent repo's .git directory
        # so git operations work inside the container.
        set parent_marker ~/projects/$project/.devenv-parent
        if test -f $parent_marker
            set parent_project (cat $parent_marker)
            # Validate parent project name to prevent path traversal.
            # The agent controls /workspace and could write a malicious value
            # (e.g., "../../.ssh") to .devenv-parent to mount arbitrary Mac dirs.
            if not string match -qr '^[a-zA-Z0-9_-]+$' -- $parent_project
                echo "ERROR: Invalid parent project name in .devenv-parent: '$parent_project'"
                return 1
            end
            if not test -d ~/projects/$parent_project/.git
                echo "ERROR: Parent project ~/projects/$parent_project does not exist"
                return 1
            end
            set create_args $create_args \
                -v ~/projects/$parent_project/.git:/workspace-parent-git
        end

        # Mount the GitHub token to a root-only path inside the container.
        # The agent cannot read it directly — git credentials are served via
        # the credential proxy, and gh/copilot authenticate via gh auth login.
        if test -f $token_file
            set create_args $create_args -v $token_file:/run/secrets/github-token:ro
        end

        # Persist Claude Code auth state across container rebuilds.
        # Shared across all projects — auth is tied to the user's account.
        set claude_state_dir ~/.config/devenv/claude-state
        mkdir -p $claude_state_dir
        for fname in credentials.json claude.json
            if not test -f $claude_state_dir/$fname
                echo '{}' > $claude_state_dir/$fname
                chmod 600 $claude_state_dir/$fname
            end
        end
        set create_args $create_args \
            -v $claude_state_dir/credentials.json:/home/dev/.claude/.credentials.json \
            -v $claude_state_dir/claude.json:/home/dev/.claude.json

        # Persist Copilot CLI auth state across container rebuilds.
        # Shared across all projects — auth is tied to the user's account.
        set copilot_state_dir ~/.config/devenv/copilot-state
        mkdir -p $copilot_state_dir
        set create_args $create_args -v $copilot_state_dir:/home/dev/.copilot

        # Persist Codex CLI auth state across container rebuilds.
        # Shared across all projects — auth is tied to the user's account.
        set codex_state_dir ~/.config/devenv/codex-state
        mkdir -p $codex_state_dir
        set create_args $create_args -v $codex_state_dir:/home/dev/.codex

        if not podman create $create_args devenv fish
            echo "ERROR: Failed to create container."
            return 1
        end
    end

    # Start both containers
    podman start $dind_name
    podman start $project

    # Wait for DinD socket to be ready, then start the filtering proxy in front of it.
    # The proxy blocks sandbox escapes (bind mounts, privileged, host namespaces)
    # while allowing normal compose operations through.
    echo -n "Waiting for Docker daemon..."
    set dind_ready false
    for i in (seq 1 30)
        if podman exec $project test -S /var/run/docker-dind/docker.sock 2>/dev/null
            set dind_ready true
            echo " ready"
            break
        end
        echo -n "."
        sleep 1
    end
    if test "$dind_ready" = false
        echo ""
        echo "⚠ Docker daemon did not start — docker-compose may not work"
    end

    # Restrict the DinD volume mount directory so the dev user cannot bypass the
    # filtering proxy by accessing the real Docker socket directly.
    # This is the primary defense — the proxy also re-applies permissions periodically.
    podman exec --user root $project chmod 700 /var/run/docker-dind 2>/dev/null

    # Start the socket proxy if not already running (it stops on container restart).
    # The proxy listens on /var/run/docker.sock (accessible by dev user) and
    # forwards filtered requests to /var/run/docker-dind/docker.sock (root-only).
    if not podman exec $project test -S /var/run/docker.sock 2>/dev/null
        podman exec --user root -d $project \
            env DOCKER_SOCKET_REAL=/var/run/docker-dind/docker.sock \
                DOCKER_SOCKET_PROXY=/var/run/docker.sock \
            python3 /usr/local/bin/docker-socket-proxy
        sleep 1
    end

    # Start credential proxy if not already running
    if not podman exec $project test -S /run/credential-proxy.sock 2>/dev/null
        podman exec --user root -d $project \
            python3 /usr/local/bin/credential-proxy
    end

    # --- First-time container configuration ---
    if test $is_new -eq 1
        # Read user identity from config
        set devenv_config ~/.config/devenv/config
        if not test -f $devenv_config
            echo "ERROR: ~/.config/devenv/config not found. Run setup-mac.sh first."
            return 1
        end
        set user_name (string replace 'DEVENV_USER_NAME=' '' (grep '^DEVENV_USER_NAME=' $devenv_config))
        set user_email (string replace 'DEVENV_USER_EMAIL=' '' (grep '^DEVENV_USER_EMAIL=' $devenv_config))

        echo "Configuring git..."

        # Fix worktree gitdir path if this is a worktree container.
        # The .git file references the Mac-side path which doesn't exist in the container.
        # We rewrite it to point to the mounted parent .git directory.
        if test -f $parent_marker
            set parent_project (cat $parent_marker)
            podman exec $project bash -c "
                if [ -f /workspace/.git ]; then
                    echo 'gitdir: /workspace-parent-git/worktrees/$project' > /workspace/.git
                fi
            "
            podman exec $project git config --global --add safe.directory /workspace-parent-git
        end

        podman exec $project git config --global user.name "$user_name"
        podman exec $project git config --global user.email "$user_email"
        podman exec $project git config --global init.defaultBranch main
        podman exec $project git config --global --add safe.directory /workspace
        podman exec $project git config --global credential.helper /usr/local/bin/git-credential-proxy
        # Rewrite SSH URLs to HTTPS transparently so the credential helper works,
        # without changing the actual remote in .git/config (which stays as SSH
        # for use on the Mac side).
        podman exec $project git config --global url."https://github.com/".insteadOf "git@github.com:"

        # Defense-in-depth for git hooks. The primary defense is the Mac-side
        # core.hooksPath (set by setup-mac.sh) which points Mac git away from
        # /workspace/.git/hooks/. This symlink is a secondary barrier — the dev
        # user CAN remove it (since /workspace is writable), but Mac-side git
        # won't look in .git/hooks/ regardless.
        podman exec --user root $project bash -c "
            mkdir -p /home/dev/.safe-hooks
            chown dev:dev /home/dev/.safe-hooks
            if [ -d /workspace/.git/hooks ]; then
                rm -rf /workspace/.git/hooks
                ln -s /dev/null /workspace/.git/hooks
            fi
        "
        podman exec $project git config --global core.hooksPath /home/dev/.safe-hooks

        # Authenticate gh CLI using the token (read by root, piped to gh).
        # This stores auth state in ~/.config/gh/ inside the container,
        # so the raw token is never in the environment.
        if test -f $token_file
            podman exec --user root $project bash -c \
                "cat /run/secrets/github-token | su dev -c 'gh auth login --with-token'"
            echo "✓ GitHub CLI authenticated"
        end

        # Install the docker-compose allowlist wrapper.
        # The wrapper reads /etc/docker-allowlist/allowed-images.txt (mounted read-only
        # from Mac) and rejects any image not on the list before calling docker-compose-real.
        if test -f $devenv_dir/docker-allowlist/docker-compose-wrapper.sh
            podman exec --user root $project bash -c "
                cp /etc/docker-allowlist/docker-compose-wrapper.sh /usr/local/bin/docker-compose
                chmod 755 /usr/local/bin/docker-compose
            "
            echo "✓ docker-compose allowlist wrapper installed"
        end

        echo "✓ Container ready"

        # Only show login reminder if Claude credentials are not already set up
        set claude_state_dir ~/.config/devenv/claude-state
        if test -f $claude_state_dir/credentials.json
            set creds_content (cat $claude_state_dir/credentials.json)
            if test "$creds_content" = "{}"
                echo ""
                echo "Don't forget to authenticate:"
                echo "  claude   (then /login)"
            end
        end
    end

    podman exec -it $project fish
end

function dev-worktree
    set project $argv[1]
    set branch $argv[2]
    if test -z "$project" -o -z "$branch"
        echo "Usage: dev-worktree <project-name> <branch-name> [--rebuild]"
        return 1
    end

    # Sanitize branch name for use as container/volume name (no slashes allowed)
    set safe_branch (string replace -a '/' '-' $branch)
    set worktree_name "$project-$safe_branch"
    set worktree_path ~/projects/$worktree_name

    if not test -d $worktree_path/.git -o -f $worktree_path/.git
        if not test -d ~/projects/$project/.git
            echo "ERROR: ~/projects/$project is not a git repository."
            return 1
        end
        # Remove empty directory if it exists (from a previous failed attempt)
        if test -d $worktree_path
            rmdir $worktree_path 2>/dev/null
        end
        echo "Creating worktree '$worktree_name'..."
        # Create the branch if it doesn't exist
        if git -C ~/projects/$project rev-parse --verify $branch 2>/dev/null
            git -C ~/projects/$project worktree add $worktree_path $branch
        else
            echo "Branch '$branch' doesn't exist, creating from current HEAD..."
            git -C ~/projects/$project worktree add -b $branch $worktree_path
        end
        if test $status -ne 0
            echo "ERROR: Failed to create worktree."
            return 1
        end
    end

    # Ensure the token is stored under the parent project name.
    # If no token exists yet, prompt and save under the parent name.
    set token_dir ~/.config/devenv/tokens
    mkdir -p $token_dir
    if not test -f $token_dir/$project
        echo ""
        echo "No GitHub token found for '$project'."
        echo ""
        echo "Create a fine-grained token at:"
        echo "  https://github.com/settings/personal-access-tokens/new"
        echo ""
        echo "Suggested settings:"
        echo "  Name:               $project"
        echo "  Repository access:  Only select repositories → pick your repo"
        echo "  Permissions:"
        echo "    Contents:         Read & Write  (git push/pull)"
        echo "    Pull requests:    Read & Write  (create/update PRs)"
        echo "    Metadata:         Read          (required)"
        echo ""
        read --silent --prompt-str "Paste token (or press Enter to skip): " token
        if test -n "$token"
            echo $token > $token_dir/$project
            chmod 600 $token_dir/$project
            echo "✓ Token saved for '$project'"
        else
            echo "⚠ Skipping token setup — git push/pull and gh copilot may not work"
        end
        echo ""
    end
    # Symlink the worktree to the parent project's token
    if test -f $token_dir/$project -a ! -f $token_dir/$worktree_name
        ln -s $token_dir/$project $token_dir/$worktree_name
        echo "✓ Linked token from '$project'"
    end

    # Store the parent project name so dev knows to mount the parent .git dir
    echo $project > $worktree_path/.devenv-parent

    # Pass through any remaining flags (e.g., --rebuild)
    dev $worktree_name $argv[3..-1]
end

function dev-worktree-rm
    set project $argv[1]
    set branch $argv[2]
    if test -z "$project" -o -z "$branch"
        echo "Usage: dev-worktree-rm <project-name> <branch-name>"
        return 1
    end

    set safe_branch (string replace -a '/' '-' $branch)
    set worktree_name "$project-$safe_branch"
    set worktree_path ~/projects/$worktree_name

    # Remove containers and infrastructure
    if podman container exists $worktree_name
        podman rm -f $worktree_name
        echo "✓ Removed container '$worktree_name'"
    end
    if podman container exists "$worktree_name-dind"
        podman rm -f "$worktree_name-dind"
        echo "✓ Removed DinD container"
    end
    if podman volume exists "$worktree_name-docker"
        podman volume rm "$worktree_name-docker"
        echo "✓ Removed DinD volume"
    end
    if podman network exists "$worktree_name-net"
        podman network rm "$worktree_name-net"
        echo "✓ Removed network"
    end
    if podman volume exists "$worktree_name-node-modules"
        podman volume rm "$worktree_name-node-modules"
        echo "✓ Removed node_modules volume"
    end
    for vol in (podman volume ls --format '{{.Name}}' | grep "^$worktree_name-nm-")
        podman volume rm $vol
        echo "✓ Removed workspace node_modules volume '$vol'"
    end

    # Remove token symlink
    rm -f ~/.config/devenv/tokens/$worktree_name

    # Remove worktree directory and prune git metadata
    if test -d $worktree_path
        rm -rf $worktree_path
        git -C ~/projects/$project worktree prune
        echo "✓ Removed worktree '$worktree_name'"
    end
end

function dev-rm
    set project $argv[1]
    if test -z "$project"
        echo "Usage: dev-rm <project-name>"
        return 1
    end

    set dind_name "$project-dind"
    set dind_volume "$project-docker"
    set dind_network "$project-net"
    set node_modules_volume "$project-node-modules"

    if podman container exists $project
        podman rm -f $project
        echo "✓ Removed container '$project'"
    end
    if podman container exists $dind_name
        podman rm -f $dind_name
        echo "✓ Removed DinD container"
    end
    if podman volume exists $dind_volume
        podman volume rm $dind_volume
        echo "✓ Removed DinD volume"
    end
    if podman volume exists $node_modules_volume
        podman volume rm $node_modules_volume
        echo "✓ Removed node_modules volume"
    end
    for vol in (podman volume ls --format '{{.Name}}' | grep "^$project-nm-")
        podman volume rm $vol
        echo "✓ Removed workspace node_modules volume '$vol'"
    end
    if podman network exists $dind_network
        podman network rm $dind_network
        echo "✓ Removed network"
    end

    echo "Project data at ~/projects/$project is untouched."
    echo "Token at ~/.config/devenv/tokens/$project is untouched."
    echo "Run 'dev $project' to recreate the container."
end

function dev-shell
    set project $argv[1]
    if test -z "$project"
        echo "Usage: dev-shell <project-name>"
        return 1
    end

    if not podman container exists $project
        echo "ERROR: Container '$project' does not exist. Run 'dev $project' first."
        return 1
    end

    if not podman ps --format '{{.Names}}' | grep -qx "$project"
        echo "ERROR: Container '$project' is not running. Run 'dev $project' first."
        return 1
    end

    podman exec -it $project fish
end

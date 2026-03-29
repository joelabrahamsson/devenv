# fish/dev.fish
# Manages sandboxed development containers via Podman.
# Sourced from ~/.config/fish/config.fish by setup-mac.sh.
#
# Usage: dev <project-name>
#
# First run for a new project:
#   - Prompts for a GitHub fine-grained token (saved to ~/projects/<name>/.github-token)
#   - Creates a Podman container named <project-name>
#   - Mounts ~/projects/<project-name> as /workspace (read-write)
#   - Mounts docker-allowlist as /etc/docker-allowlist (read-only)
#   - Mounts the Podman socket for docker-compose support
#   - Configures git identity and credential helper inside the container
#   - Installs the docker-compose allowlist wrapper
#
# Subsequent runs: starts the container and opens a fish shell.
#
# Credentials (gh auth, claude login) persist inside the container.
# They are lost if the container is removed (podman rm -f <project>).
# The GitHub token persists on the Mac side and is re-wired automatically.

function dev
    set project $argv[1]
    if test -z "$project"
        echo "Usage: dev <project-name>"
        return 1
    end

    # Resolve the dotfiles directory relative to this script's location
    set devenv_dir (dirname (status filename))

    mkdir -p ~/projects/$project

    # --- GitHub token setup ---
    # Token is stored on the Mac side so it survives container rebuilds.
    # chmod 644 so the container's non-root dev user can read it.
    set token_file ~/projects/$project/.github-token

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
        echo "  Permissions:        Contents (Read & Write), Metadata (Read)"
        echo ""
        read --prompt-str "Paste token (or press Enter to skip): " token
        if test -n "$token"
            echo $token > $token_file
            chmod 644 $token_file
            echo "✓ Token saved to $token_file"
        else
            echo "⚠ Skipping token setup — git push/pull may not work"
        end
        echo ""
    end

    # --- Get Podman socket path ---
    # Used to allow docker-compose to spin up sibling containers (e.g. test databases).
    # Filtered through the allowlist wrapper to restrict which images can be used.
    set podman_socket (podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null)

    # --- Create container (first time only) ---
    set is_new 0
    if not podman container exists $project
        set is_new 1
        echo "Creating new container for '$project'..."

        set create_args -it \
            --name $project \
            -v ~/projects/$project:/workspace \
            -v $devenv_dir/docker-allowlist:/etc/docker-allowlist:ro \
            -w /workspace

        if test -n "$podman_socket" -a -S "$podman_socket"
            set create_args $create_args -v $podman_socket:/var/run/docker.sock
        end

        podman create $create_args devenv fish
    end

    podman start $project

    # --- First-time container configuration ---
    if test $is_new -eq 1
        echo "Configuring git..."
        podman exec $project fish -c "
            git config --global user.name 'Joel Abrahamsson'
            git config --global user.email 'mail@joelabrahamsson.com'
            git config --global init.defaultBranch main
            git config --global --add safe.directory /workspace
            git config --global credential.helper '!f() { echo \"password=\$(cat /workspace/.github-token)\"; echo \"username=x-token\"; }; f'
        "

        # Install the docker-compose allowlist wrapper.
        # The wrapper reads /etc/docker-allowlist/allowed-images.txt (mounted read-only
        # from Mac) and rejects any image not on the list before calling docker-compose-real.
        if test -f $devenv_dir/docker-allowlist/docker-compose-wrapper.sh
            podman exec $project bash -c "
                cp /etc/docker-allowlist/docker-compose-wrapper.sh /usr/local/bin/docker-compose
                chmod 755 /usr/local/bin/docker-compose
            "
            echo "✓ docker-compose allowlist wrapper installed"
        end

        echo "✓ Container ready"
        echo ""
        echo "Don't forget to authenticate:"
        echo "  gh auth login"
        echo "  claude   (then /login)"
    end

    podman exec -it $project fish
end

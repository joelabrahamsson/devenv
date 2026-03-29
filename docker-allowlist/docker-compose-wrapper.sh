#!/bin/bash
# docker-allowlist/docker-compose-wrapper.sh
#
# Wraps docker-compose to enforce an image allowlist before any containers
# are started. The allowlist is read from /etc/docker-allowlist/allowed-images.txt,
# which is mounted read-only from the Mac side — the agent inside the container
# cannot modify it.
#
# Only the up, run, and start commands are checked. Other commands (down, logs,
# ps, etc.) pass through directly.
#
# The real docker-compose binary is at /usr/local/bin/docker-compose-real.

ALLOWLIST="/etc/docker-allowlist/allowed-images.txt"
COMPOSE_FILE="docker-compose.yml"

# Parse args to find -f / --file flag
args=("$@")
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "-f" || "${args[$i]}" == "--file" ]]; then
        COMPOSE_FILE="${args[$((i+1))]}"
    fi
done

COMMAND="${1:-}"

if [[ "$COMMAND" == "up" || "$COMMAND" == "run" || "$COMMAND" == "start" ]]; then
    # Find the compose file (try common names if not specified via -f)
    for candidate in "$COMPOSE_FILE" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [[ -f "$candidate" ]]; then
            COMPOSE_FILE="$candidate"
            break
        fi
    done

    if [[ -f "$COMPOSE_FILE" ]]; then
        # Extract all image references from the compose file
        images=$(python3 -c "
import yaml, sys
try:
    with open('$COMPOSE_FILE') as f:
        data = yaml.safe_load(f)
    services = data.get('services', {}) if data else {}
    for name, svc in services.items():
        if isinstance(svc, dict):
            img = svc.get('image', '')
            if img:
                print(img)
except Exception as e:
    print('PARSE_ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)

        if [[ $? -ne 0 ]]; then
            echo "❌ docker-compose wrapper: could not parse $COMPOSE_FILE"
            echo "   $images"
            exit 1
        fi

        if [[ -z "$images" ]]; then
            # No image references found (all services may use build:) — allow through
            exec /usr/local/bin/docker-compose-real "$@"
        fi

        if [[ ! -f "$ALLOWLIST" ]]; then
            echo "❌ docker-compose wrapper: allowlist not found at $ALLOWLIST"
            echo "   Is the docker-allowlist directory mounted?"
            exit 1
        fi

        while IFS= read -r image; do
            [[ -z "$image" ]] && continue

            # Strip tag and registry prefix for matching
            image_base="${image%%:*}"          # remove :tag
            image_name="${image_base##*/}"     # remove registry/org prefix

            allowed=false
            while IFS= read -r allowed_prefix; do
                # Skip comments and blank lines
                [[ -z "$allowed_prefix" || "$allowed_prefix" == \#* ]] && continue
                if [[ "$image_name" == "$allowed_prefix"* ]]; then
                    allowed=true
                    break
                fi
            done < "$ALLOWLIST"

            if [[ "$allowed" == false ]]; then
                echo "❌ Image not allowed: $image"
                echo "   Add '$image_name' to the allowed-images.txt in your devenv repository"
                echo "   Then recreate the container: podman rm -f <project> && dev <project>"
                exit 1
            fi
        done <<< "$images"
    fi
fi

# All checks passed (or command doesn't need checking) — run the real binary
exec /usr/local/bin/docker-compose-real "$@"

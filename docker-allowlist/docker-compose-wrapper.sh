#!/bin/bash
# docker-allowlist/docker-compose-wrapper.sh
#
# Wraps docker-compose to enforce an image allowlist before any containers
# are started. The allowlist is read from /etc/docker-allowlist/allowed-images.txt,
# which is mounted read-only from the Mac side — the agent inside the container
# cannot modify it.
#
# Both image: references and FROM directives in Dockerfiles (via build:) are
# validated against the allowlist.
#
# Only the up, run, and start commands are checked. Other commands (down, logs,
# ps, etc.) pass through directly.
#
# The real docker-compose binary is at /usr/local/bin/docker-compose-real.

ALLOWLIST="/etc/docker-allowlist/allowed-images.txt"
COMPOSE_FILE="docker-compose.yml"

# Parse args to find -f / --file flag and the subcommand.
# Global flags that take a value must be skipped to avoid misidentifying the subcommand.
KNOWN_COMMANDS="build config create down events exec images kill logs pause port ps pull push restart rm run start stop top unpause up version wait"
args=("$@")
COMMAND=""
skip_next=false
for arg in "$@"; do
    if $skip_next; then
        skip_next=false
        continue
    fi
    # Global flags that take a value argument
    if [[ "$arg" == "-f" || "$arg" == "--file" || "$arg" == "-p" || "$arg" == "--project-name" || \
          "$arg" == "--project-directory" || "$arg" == "--env-file" || "$arg" == "--profile" || \
          "$arg" == "--progress" || "$arg" == "--ansi" ]]; then
        skip_next=true
        continue
    fi
    # Match against known compose subcommands
    if [[ -z "$COMMAND" && "$arg" != -* ]]; then
        for cmd in $KNOWN_COMMANDS; do
            if [[ "$arg" == "$cmd" ]]; then
                COMMAND="$arg"
                break
            fi
        done
    fi
done
# Re-parse for -f value (separate loop to keep it clean)
for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "-f" || "${args[$i]}" == "--file" ]]; then
        COMPOSE_FILE="${args[$((i+1))]}"
    fi
done

if [[ "$COMMAND" == "up" || "$COMMAND" == "run" || "$COMMAND" == "start" ]]; then
    # Find the compose file (try common names if not specified via -f)
    for candidate in "$COMPOSE_FILE" "docker-compose.yaml" "compose.yml" "compose.yaml"; do
        if [[ -f "$candidate" ]]; then
            COMPOSE_FILE="$candidate"
            break
        fi
    done

    if [[ -f "$COMPOSE_FILE" ]]; then
        # Extract image references from both image: directives and FROM lines
        # in Dockerfiles referenced by build: directives.
        # Uses env vars (not string interpolation) to avoid code injection.
        parse_output=$(COMPOSE_FILE="$COMPOSE_FILE" /usr/bin/python3 -c "
import yaml, sys, os, re

compose_file = os.environ['COMPOSE_FILE']
compose_dir = os.path.dirname(os.path.abspath(compose_file)) or '.'

try:
    with open(compose_file) as f:
        data = yaml.safe_load(f)
    services = data.get('services', {}) if data else {}
    for name, svc in services.items():
        if not isinstance(svc, dict):
            continue
        img = svc.get('image', '')
        if img:
            print('IMAGE:' + img)
        build = svc.get('build')
        if build:
            # build can be a string (context path) or a dict with context/dockerfile
            if isinstance(build, str):
                context = build
                dockerfile = 'Dockerfile'
            elif isinstance(build, dict):
                context = build.get('context', '.')
                dockerfile = build.get('dockerfile', 'Dockerfile')
            else:
                continue
            # Resolve dockerfile path relative to compose file directory
            if not os.path.isabs(context):
                context = os.path.join(compose_dir, context)
            context = os.path.realpath(context)
            # Reject build contexts outside /workspace to prevent filesystem probing
            if not context.startswith('/workspace'):
                print('ERROR:Service \"' + name + '\": build context \"' + context + '\" is outside /workspace', file=sys.stderr)
                sys.exit(1)
            df_path = os.path.join(context, dockerfile)
            if os.path.isfile(df_path):
                with open(df_path) as df:
                    for line in df:
                        line = line.strip()
                        m = re.match(r'^FROM\s+(\S+)', line, re.IGNORECASE)
                        if m:
                            from_image = m.group(1)
                            # Skip build stages (FROM ... AS ...)
                            if from_image.lower() == 'scratch':
                                continue
                            print('IMAGE:' + from_image)
            else:
                print('ERROR:Service \"' + name + '\": Dockerfile not found at ' + df_path, file=sys.stderr)
                sys.exit(1)
except Exception as e:
    print('PARSE_ERROR: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)

        if [[ $? -ne 0 ]]; then
            echo "❌ docker-compose wrapper: could not parse $COMPOSE_FILE"
            echo "   $parse_output"
            exit 1
        fi

        images=$(echo "$parse_output" | grep '^IMAGE:' | sed 's/^IMAGE://')

        if [[ -z "$images" ]]; then
            echo "❌ docker-compose wrapper: no image references found in $COMPOSE_FILE"
            exit 1
        fi

        if [[ ! -f "$ALLOWLIST" ]]; then
            echo "❌ docker-compose wrapper: allowlist not found at $ALLOWLIST"
            echo "   Is the docker-allowlist directory mounted?"
            exit 1
        fi

        while IFS= read -r image; do
            [[ -z "$image" ]] && continue

            # Strip tag for matching, but keep registry/org prefix.
            # This prevents attacker.com/postgres from matching "postgres".
            image_base="${image%%:*}"

            allowed=false
            while IFS= read -r allowed_entry; do
                # Skip comments and blank lines
                [[ -z "$allowed_entry" || "$allowed_entry" == \#* ]] && continue
                if [[ "$image_base" == "$allowed_entry" ]]; then
                    allowed=true
                    break
                fi
            done < "$ALLOWLIST"

            if [[ "$allowed" == false ]]; then
                echo "❌ Image not allowed: $image"
                echo "   Add '$image_base' to allowed-images.txt on the host and recreate the container."
                exit 1
            fi
        done <<< "$images"

        # TOCTOU mitigation: snapshot the validated compose file to a temp directory.
        # The dev user controls /workspace and could swap the file between our
        # validation and docker-compose-real's read. The socket proxy provides
        # authoritative enforcement at pull time, but this snapshot closes the
        # race at the wrapper level.
        SNAPSHOT_DIR=$(mktemp -d /tmp/compose-snapshot.XXXXXX)
        trap '[[ -n "$SNAPSHOT_DIR" ]] && rm -rf "$SNAPSHOT_DIR"' EXIT
        cp "$COMPOSE_FILE" "$SNAPSHOT_DIR/docker-compose.yml"
        VALIDATED_COMPOSE="$SNAPSHOT_DIR/docker-compose.yml"
    fi
fi

# For up/run/start: run compose using the validated snapshot (if available),
# then set up socat forwarding from localhost to DinD for each published port.
if [[ -n "$VALIDATED_COMPOSE" ]]; then
    # Build args with -f pointing to validated snapshot and --project-directory
    # to preserve relative path resolution from the original working directory.
    compose_args=("--project-directory" "$PWD" "-f" "$VALIDATED_COMPOSE")
    skip_next_arg=false
    for arg in "$@"; do
        if $skip_next_arg; then skip_next_arg=false; continue; fi
        if [[ "$arg" == "-f" || "$arg" == "--file" ]]; then skip_next_arg=true; continue; fi
        if [[ "$arg" == -f=* || "$arg" == --file=* ]]; then continue; fi
        compose_args+=("$arg")
    done

    /usr/local/bin/docker-compose-real "${compose_args[@]}"
    COMPOSE_EXIT=$?

    if [[ $COMPOSE_EXIT -eq 0 ]]; then
        DIND_HOST="${COMPOSE_PROJECT_NAME}-dind"

        COMPOSE_FILE="$VALIDATED_COMPOSE" /usr/bin/python3 -c "
import yaml, os, re
with open(os.environ['COMPOSE_FILE']) as f:
    data = yaml.safe_load(f)
services = data.get('services', {}) if data else {}
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    for port in svc.get('ports', []):
        port_str = str(port)
        m = re.match(r'^(?:\d+\.\d+\.\d+\.\d+:)?(\d+):(\d+)', port_str)
        if m:
            print(f'{m.group(1)}:{m.group(2)}')
" 2>/dev/null | while IFS=: read -r host_port container_port; do
            [[ -z "$host_port" ]] && continue
            pkill -f "socat.*TCP-LISTEN:${host_port}," 2>/dev/null || true
            socat TCP-LISTEN:${host_port},fork,reuseaddr \
                  TCP:${DIND_HOST}:${host_port} &
        done
    fi

    exit $COMPOSE_EXIT
fi

# On down/stop, kill socat forwarders for ports from the compose file
if [[ "$COMMAND" == "down" || "$COMMAND" == "stop" ]] && [[ -f "$COMPOSE_FILE" ]]; then
    COMPOSE_FILE="$COMPOSE_FILE" /usr/bin/python3 -c "
import yaml, os, re
with open(os.environ['COMPOSE_FILE']) as f:
    data = yaml.safe_load(f)
services = data.get('services', {}) if data else {}
for name, svc in services.items():
    if not isinstance(svc, dict):
        continue
    for port in svc.get('ports', []):
        m = re.match(r'^(?:\d+\.\d+\.\d+\.\d+:)?(\d+):\d+', str(port))
        if m:
            print(m.group(1))
" 2>/dev/null | while IFS= read -r port; do
        pkill -f "socat.*TCP-LISTEN:${port}," 2>/dev/null || true
    done
fi

# All checks passed (or command doesn't need checking) — run the real binary
exec /usr/local/bin/docker-compose-real "$@"

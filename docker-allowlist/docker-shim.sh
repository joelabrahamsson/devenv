#!/bin/bash
# docker-allowlist/docker-shim.sh
#
# Minimal shim that intercepts `docker compose` and delegates to the
# docker-compose wrapper (which enforces the image allowlist).
#
# Only the `compose` subcommand is supported. All other docker commands
# are rejected — this avoids giving the agent a full Docker CLI which
# could bypass the allowlist.

if [[ "$1" == "compose" ]]; then
    shift
    exec /usr/local/bin/docker-compose "$@"
fi

echo "❌ Only 'docker compose' is supported in this environment."
echo "   Other docker commands are not available."
exit 1

#!/usr/bin/env python3
"""
Git credential proxy.

Runs as root inside the container, serving git credentials over a Unix socket.
The dev user's git credential helper queries this proxy instead of reading the
raw token file.

Security guarantees:
  1. Host restriction — credentials are only served for github.com, preventing
     the agent from forwarding the token to attacker-controlled git remotes.
  2. No passive file access — the token file (/run/secrets/github-token) is
     root-only, so tools scanning the filesystem won't discover it.

Known limitation: the dev user CAN query this proxy directly (e.g., via a
socket connection sending protocol=https/host=github.com) and obtain the raw
token. This is inherent — git itself needs the token, and the dev user runs
git. The proxy prevents *passive* discovery and *misdirected* use, not
*determined* extraction.
"""

import os
import socket
import sys
import threading

TOKEN_FILE = os.environ.get("CREDENTIAL_TOKEN_FILE", "/run/secrets/github-token")
PROXY_SOCKET = os.environ.get("CREDENTIAL_SOCKET", "/run/credential-proxy.sock")


ALLOWED_HOSTS = {"github.com"}


def handle_client(conn):
    try:
        data = conn.recv(4096).decode().strip()
        # Parse git credential protocol lines (key=value)
        attrs = {}
        for line in data.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                attrs[k.strip()] = v.strip()

        if (attrs.get("host") in ALLOWED_HOSTS
                and attrs.get("protocol") == "https"
                and os.path.exists(TOKEN_FILE)):
            with open(TOKEN_FILE) as f:
                token = f.read().strip()
            conn.sendall(f"username=x-token\npassword={token}\n".encode())
        else:
            conn.sendall(b"")
    except Exception:
        pass
    finally:
        conn.close()


def main():
    if not os.path.exists(TOKEN_FILE):
        print(f"WARNING: Token file not found at {TOKEN_FILE}", file=sys.stderr)

    if os.path.exists(PROXY_SOCKET):
        os.unlink(PROXY_SOCKET)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(PROXY_SOCKET)
    # Allow the dev user to connect
    os.chmod(PROXY_SOCKET, 0o666)
    server.listen(5)

    print(f"Credential proxy listening on {PROXY_SOCKET}", file=sys.stderr)

    try:
        while True:
            conn, _ = server.accept()
            threading.Thread(target=handle_client, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        if os.path.exists(PROXY_SOCKET):
            os.unlink(PROXY_SOCKET)


if __name__ == "__main__":
    main()

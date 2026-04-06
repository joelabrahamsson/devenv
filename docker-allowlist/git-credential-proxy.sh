#!/bin/bash
# Git credential helper that queries the credential proxy.
# Installed as the git credential helper inside the container.
#
# Git calls this with "get", "store", or "erase" as the first argument.
# We only handle "get" — the proxy returns username/password.
#
# Git sends protocol/host/path on stdin. We forward it to the proxy
# so it can validate the host before returning credentials.

if [[ "$1" == "get" ]]; then
    /usr/bin/python3 -c "
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    sock.connect('/run/credential-proxy.sock')
    sock.sendall(sys.stdin.buffer.read())
    data = b''
    while True:
        chunk = sock.recv(1024)
        if not chunk:
            break
        data += chunk
    sys.stdout.write(data.decode())
except Exception:
    pass
finally:
    sock.close()
"
fi

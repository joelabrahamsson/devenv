#!/usr/bin/env python3
"""
Filtering proxy for the Docker/Podman socket.

Sits between the dev user and the DinD daemon, allowing docker-compose
operations while blocking requests that could escape the sandbox.

Security model: ALLOWLIST-based. Only explicitly permitted API endpoints
are forwarded. Everything else is blocked by default.

Allowed:
  - Container lifecycle: create (inspected), start, stop, kill, remove, wait,
    inspect, list, logs, top, stats, attach, resize, archive, changes
  - Exec: create (inspected — blocks privileged), start, inspect, resize
  - Images: list, inspect, history, tag
  - Image pull: only images on the allowlist
  - Image build: allowed (FROM validation is done by compose wrapper)
  - Networks: all operations (create, list, inspect, connect, disconnect, remove)
  - Volumes: all operations (create, list, inspect, remove, prune)
  - System: info, version, ping, events, df

Blocked:
  - Container creation with: bind mounts, privileged, host namespaces,
    capabilities, devices, sysctls, VolumesFrom
  - Exec creation with: privileged
  - Image pull of non-allowlisted images
  - Any endpoint not in the allowlist
"""

import json
import os
import re
import select
import socket
import sys
import threading
import time


REAL_SOCKET = os.environ.get("DOCKER_SOCKET_REAL", "/var/run/docker-real.sock")
PROXY_SOCKET = os.environ.get("DOCKER_SOCKET_PROXY", "/var/run/docker.sock")
ALLOWLIST_FILE = "/etc/docker-allowlist/allowed-images.txt"
BUFFER_SIZE = 65536

# Compile allowed API patterns (method, path_regex)
ALLOWED_ENDPOINTS = [
    # System
    ("GET", r"/_ping"),
    ("HEAD", r"/_ping"),
    ("GET", r"/version"),
    ("GET", r"/info"),
    ("GET", r"/events"),
    ("GET", r"/system/df"),

    # Containers — lifecycle
    ("POST", r"/containers/create"),          # inspected separately
    ("GET", r"/containers/json"),
    ("GET", r"/containers/[^/]+/json"),
    ("GET", r"/containers/[^/]+/top"),
    ("GET", r"/containers/[^/]+/logs"),
    ("GET", r"/containers/[^/]+/changes"),
    ("GET", r"/containers/[^/]+/stats"),
    ("GET", r"/containers/[^/]+/archive"),
    ("POST", r"/containers/[^/]+/start"),
    ("POST", r"/containers/[^/]+/stop"),
    ("POST", r"/containers/[^/]+/restart"),
    ("POST", r"/containers/[^/]+/kill"),
    ("POST", r"/containers/[^/]+/pause"),
    ("POST", r"/containers/[^/]+/unpause"),
    ("POST", r"/containers/[^/]+/wait"),
    ("POST", r"/containers/[^/]+/resize"),
    ("POST", r"/containers/[^/]+/attach"),
    ("POST", r"/containers/[^/]+/rename"),
    ("DELETE", r"/containers/[^/]+"),

    # Exec — inspected separately for privileged
    ("POST", r"/containers/[^/]+/exec"),      # inspected separately
    ("POST", r"/exec/[^/]+/start"),
    ("POST", r"/exec/[^/]+/resize"),
    ("GET", r"/exec/[^/]+/json"),

    # Images — read operations + build (FROM checked by compose wrapper)
    ("GET", r"/images/json"),
    ("GET", r"/images/[^/]+/json"),
    ("GET", r"/images/[^/]+/history"),
    ("POST", r"/images/[^/]+/tag"),
    # /build is NOT allowed — agents could bypass the compose wrapper's FROM
    # validation by calling the build API directly. Builds must go through
    # docker-compose, which validates FROM directives before invoking compose-real.
    ("POST", r"/images/create"),              # pulls — inspected separately

    # Networks
    ("GET", r"/networks"),
    ("GET", r"/networks/[^/]+"),
    ("POST", r"/networks/create"),
    ("POST", r"/networks/[^/]+/connect"),
    ("POST", r"/networks/[^/]+/disconnect"),
    ("DELETE", r"/networks/[^/]+"),
    ("POST", r"/networks/prune"),

    # Volumes
    ("GET", r"/volumes"),
    ("GET", r"/volumes/[^/]+"),
    ("POST", r"/volumes/create"),
    ("DELETE", r"/volumes/[^/]+"),
    ("POST", r"/volumes/prune"),
]


def load_allowlist():
    """Load allowed image names from the allowlist file."""
    allowed = set()
    if os.path.exists(ALLOWLIST_FILE):
        with open(ALLOWLIST_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    allowed.add(line)
    return allowed


def is_endpoint_allowed(method, path):
    """Check if a method+path combination is in the allowlist."""
    # Strip version prefix (e.g., /v1.41/containers/json -> /containers/json)
    path_base = re.sub(r"^/v\d+\.\d+", "", path.split("?")[0])
    for allowed_method, pattern in ALLOWED_ENDPOINTS:
        if method == allowed_method and re.match(pattern + "$", path_base):
            return True
    return False


def needs_body_inspection(method, path):
    """Check if this request needs body inspection."""
    path_base = re.sub(r"^/v\d+\.\d+", "", path.split("?")[0])
    if method == "POST" and re.match(r"/containers/create$", path_base):
        return "container_create"
    if method == "POST" and re.match(r"/containers/[^/]+/exec$", path_base):
        return "exec_create"
    if method == "POST" and re.match(r"/images/create$", path_base):
        return "image_pull"
    return None


def check_container_create(body_bytes):
    """Inspect a container creation request and reject unsafe options."""
    try:
        config = json.loads(body_bytes)
    except (json.JSONDecodeError, ValueError):
        return False, "Could not parse container creation request"

    host_config = config.get("HostConfig", {})
    if not isinstance(host_config, dict):
        host_config = {}

    if host_config.get("Privileged"):
        return False, "Privileged containers are not allowed"
    if host_config.get("PidMode", "").lower() == "host":
        return False, "Host PID namespace is not allowed"
    if host_config.get("IpcMode", "").lower() == "host":
        return False, "Host IPC namespace is not allowed"
    if host_config.get("NetworkMode", "").lower() == "host":
        return False, "Host network mode is not allowed"
    if host_config.get("UTSMode", "").lower() == "host":
        return False, "Host UTS namespace is not allowed"
    if host_config.get("CapAdd"):
        return False, f"Adding capabilities is not allowed: {host_config['CapAdd']}"
    if host_config.get("Devices"):
        return False, f"Device access is not allowed: {host_config['Devices']}"
    if host_config.get("Sysctls"):
        return False, f"Setting sysctls is not allowed: {host_config['Sysctls']}"
    if host_config.get("VolumesFrom"):
        return False, f"VolumesFrom is not allowed: {host_config['VolumesFrom']}"

    binds = host_config.get("Binds", [])
    if binds:
        return False, f"Bind mounts are not allowed: {binds}"

    mounts = host_config.get("Mounts", [])
    if isinstance(mounts, list):
        for mount in mounts:
            if isinstance(mount, dict) and mount.get("Type", "").lower() == "bind":
                return False, f"Bind mounts are not allowed: {mount.get('Source', '')}"

    # Validate image against allowlist — prevents creating containers from
    # cached images that are not (or no longer) on the allowlist.
    image = config.get("Image", "")
    if image:
        image_base = image.split(":")[0]
        allowed_images = load_allowlist()
        if image_base not in allowed_images:
            return False, f"Image not allowed: {image}. Add '{image_base}' to allowed-images.txt"

    return True, ""


def check_exec_create(body_bytes):
    """Inspect an exec creation request — block privileged exec."""
    try:
        config = json.loads(body_bytes)
    except (json.JSONDecodeError, ValueError):
        return False, "Could not parse exec creation request"

    if config.get("Privileged"):
        return False, "Privileged exec is not allowed"

    return True, ""


def check_image_pull(path):
    """Check if the image being pulled is on the allowlist."""
    # Parse the image name from query params: /images/create?fromImage=postgres&tag=15
    match = re.search(r"[?&]fromImage=([^&]+)", path)
    if not match:
        return False, "Could not determine image name from pull request"

    image = match.group(1)
    # Strip tag for matching (same logic as compose wrapper)
    image_base = image.split(":")[0]

    allowed_images = load_allowlist()
    if image_base in allowed_images:
        return True, ""

    return False, f"Image not allowed: {image}. Add '{image_base}' to allowed-images.txt"


def monitor_permissions():
    """Periodically re-restrict the real socket and its parent directory.

    The DinD container shares the same volume and may recreate the socket
    on restart, resetting permissions. This thread re-applies restrictions
    every few seconds to minimize the bypass window.
    """
    real_dir = os.path.dirname(REAL_SOCKET)
    while True:
        try:
            st = os.stat(real_dir)
            if st.st_mode & 0o077:
                os.chmod(real_dir, 0o700)
        except OSError:
            pass
        try:
            if os.path.exists(REAL_SOCKET):
                st = os.stat(REAL_SOCKET)
                if st.st_mode & 0o077:
                    os.chmod(REAL_SOCKET, 0o600)
        except OSError:
            pass
        time.sleep(5)


def parse_http_request(data):
    """Parse an HTTP request, return (method, path, headers, body_start_offset)."""
    header_end = data.find(b"\r\n\r\n")
    if header_end == -1:
        return None, None, {}, len(data)

    header_data = data[:header_end].decode("utf-8", errors="replace")
    lines = header_data.split("\r\n")
    request_line = lines[0]
    parts = request_line.split(" ")
    method = parts[0] if len(parts) >= 1 else ""
    path = parts[1] if len(parts) >= 2 else ""

    headers = {}
    for line in lines[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower()] = v

    return method, path, headers, header_end + 4


def send_error(client_sock, status, message):
    """Send an HTTP error response to the client."""
    body = json.dumps({"message": message}).encode()
    response = (
        f"HTTP/1.1 {status} Error\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode() + body
    try:
        client_sock.sendall(response)
    except OSError:
        pass


def stream_bidirectional(sock_a, sock_b):
    """Stream data between two sockets until one closes."""
    sockets = [sock_a, sock_b]
    try:
        while sockets:
            readable, _, errored = select.select(sockets, [], sockets, 30)
            if errored:
                break
            for s in readable:
                data = s.recv(BUFFER_SIZE)
                if not data:
                    return
                target = sock_b if s is sock_a else sock_a
                target.sendall(data)
    except OSError:
        pass


def handle_client(client_sock):
    """Handle a single client connection."""
    try:
        request_data = b""
        while b"\r\n\r\n" not in request_data:
            chunk = client_sock.recv(BUFFER_SIZE)
            if not chunk:
                return
            request_data += chunk

        method, path, headers, body_offset = parse_http_request(request_data)
        if method is None:
            send_error(client_sock, 400, "Could not parse request")
            return

        # Check if the endpoint is allowed
        if not is_endpoint_allowed(method, path):
            send_error(client_sock, 403, f"Blocked by socket proxy: {method} {path} is not allowed")
            print(f"BLOCKED: {method} {path}", file=sys.stderr)
            return

        # Check if body inspection is needed
        inspection_type = needs_body_inspection(method, path)

        if inspection_type == "image_pull":
            # Image pull — check allowlist from URL params (no body needed)
            allowed, reason = check_image_pull(path)
            if not allowed:
                send_error(client_sock, 403, f"Blocked by socket proxy: {reason}")
                print(f"BLOCKED: {reason}", file=sys.stderr)
                return

        elif inspection_type in ("container_create", "exec_create"):
            # Read the full body for inspection
            content_length = int(headers.get("content-length", 0))
            if content_length == 0:
                send_error(client_sock, 400, "Missing Content-Length on inspected request")
                return

            body = request_data[body_offset:]
            while len(body) < content_length:
                chunk = client_sock.recv(BUFFER_SIZE)
                if not chunk:
                    break
                body += chunk

            # Validate body length matches Content-Length to prevent truncation attacks
            if len(body) < content_length:
                send_error(client_sock, 400, "Incomplete request body")
                return

            # Truncate to exactly Content-Length to prevent appended data
            body = body[:content_length]

            if inspection_type == "container_create":
                allowed, reason = check_container_create(body)
            else:
                allowed, reason = check_exec_create(body)

            if not allowed:
                send_error(client_sock, 403, f"Blocked by socket proxy: {reason}")
                print(f"BLOCKED: {reason}", file=sys.stderr)
                return

            # Rebuild request_data with exactly the validated body
            request_data = request_data[:body_offset] + body

        # Connect to the real socket and forward
        real_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        real_sock.connect(REAL_SOCKET)

        real_sock.sendall(request_data)

        stream_bidirectional(client_sock, real_sock)

        real_sock.close()
    except Exception as e:
        send_error(client_sock, 502, f"Proxy error: {str(e)}")
    finally:
        client_sock.close()


def main():
    if not os.path.exists(REAL_SOCKET):
        print(f"ERROR: Real socket not found at {REAL_SOCKET}", file=sys.stderr)
        sys.exit(1)

    # Restrict the real socket's parent directory so non-root users cannot
    # bypass the proxy by accessing the socket directly. The directory
    # restriction is the primary defense; socket chmod is defense-in-depth.
    real_dir = os.path.dirname(REAL_SOCKET)
    try:
        os.chmod(real_dir, 0o700)
    except OSError as e:
        print(f"WARNING: Could not restrict {real_dir}: {e}", file=sys.stderr)
    try:
        os.chmod(REAL_SOCKET, 0o600)
    except OSError:
        pass

    if os.path.exists(PROXY_SOCKET):
        os.unlink(PROXY_SOCKET)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(PROXY_SOCKET)
    os.chmod(PROXY_SOCKET, 0o666)
    server.listen(16)

    print(f"Docker socket proxy starting", file=sys.stderr)
    print(f"  Real socket: {REAL_SOCKET}", file=sys.stderr)
    print(f"  Proxy socket: {PROXY_SOCKET}", file=sys.stderr)

    # Re-apply permissions periodically to defend against DinD restarts
    threading.Thread(target=monitor_permissions, daemon=True).start()

    try:
        while True:
            client_sock, _ = server.accept()
            threading.Thread(
                target=handle_client, args=(client_sock,), daemon=True
            ).start()
    except KeyboardInterrupt:
        pass
    finally:
        server.close()
        if os.path.exists(PROXY_SOCKET):
            os.unlink(PROXY_SOCKET)


if __name__ == "__main__":
    main()

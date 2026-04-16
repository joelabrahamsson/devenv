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
  - Networks: all operations (create, list, inspect, connect, disconnect, remove)
  - Volumes: create (inspected), list, inspect, remove, prune
  - System: info, version, ping, events, df

Blocked:
  - Container creation with: bind mounts, privileged, host namespaces,
    capabilities, devices, sysctls, VolumesFrom, custom volume drivers
  - Exec creation with: privileged
  - Volume creation with: non-default drivers, driver options
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
from urllib.parse import unquote


REAL_SOCKET = os.environ.get("DOCKER_SOCKET_REAL", "/var/run/docker-real.sock")
PROXY_SOCKET = os.environ.get("DOCKER_SOCKET_PROXY", "/var/run/docker.sock")
ALLOWLIST_FILE = "/etc/docker-allowlist/allowed-images.txt"
BUFFER_SIZE = 65536
MAX_HEADER_SIZE = 64 * 1024
MAX_BODY_SIZE = 10 * 1024 * 1024

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

    # Images — read operations; build is blocked at the API level
    ("GET", r"/images/json"),
    ("GET", r"/images/.+/json"),
    ("GET", r"/images/.+/history"),
    ("POST", r"/images/.+/tag"),
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


def strip_version_prefix(path):
    """Strip the Docker API version prefix and query string from a path."""
    return re.sub(r"^/v\d+\.\d+", "", path.split("?")[0])


def normalize_image_name(image_base):
    """Normalize a fully qualified Docker image name to its short form.

    Docker resolves short names to fully qualified registry paths:
      redis          -> docker.io/library/redis
      minio/minio    -> docker.io/minio/minio

    The allowlist uses short names, so we strip the registry prefix
    to match against it. Only docker.io is normalized — other registries
    must be listed explicitly in the allowlist.
    """
    if image_base.startswith("docker.io/library/"):
        return image_base[len("docker.io/library/"):]
    if image_base.startswith("docker.io/"):
        return image_base[len("docker.io/"):]
    return image_base


def is_endpoint_allowed(method, path):
    """Check if a method+path combination is in the allowlist."""
    path_base = strip_version_prefix(path)
    for allowed_method, pattern in ALLOWED_ENDPOINTS:
        if method == allowed_method and re.match(pattern + "$", path_base):
            return True
    return False


def needs_body_inspection(method, path):
    """Check if this request needs body inspection."""
    path_base = strip_version_prefix(path)
    if method == "POST" and re.match(r"/containers/create$", path_base):
        return "container_create"
    if method == "POST" and re.match(r"/containers/[^/]+/exec$", path_base):
        return "exec_create"
    if method == "POST" and re.match(r"/images/create$", path_base):
        return "image_pull"
    if method == "POST" and re.match(r"/volumes/create$", path_base):
        return "volume_create"
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
    if host_config.get("VolumeDriver"):
        return False, f"Custom volume drivers are not allowed: {host_config['VolumeDriver']}"

    binds = host_config.get("Binds", [])
    if binds:
        for bind in binds:
            # Named volumes: "volname:/path:opts" — source has no slash.
            # Bind mounts: "/host/path:/path:opts" — source starts with /.
            source = bind.split(":")[0] if isinstance(bind, str) else ""
            if source.startswith("/"):
                return False, f"Bind mounts are not allowed: {bind}"

    mounts = host_config.get("Mounts", [])
    if isinstance(mounts, list):
        for mount in mounts:
            if not isinstance(mount, dict):
                continue
            mount_type = mount.get("Type", "").lower()
            if mount_type == "bind":
                return False, f"Bind mounts are not allowed: {mount.get('Source', '')}"
            if mount_type == "volume":
                volume_options = mount.get("VolumeOptions", {})
                if not isinstance(volume_options, dict):
                    volume_options = {}
                driver_config = volume_options.get("DriverConfig", {})
                if driver_config:
                    return False, f"Volume driver config is not allowed: {driver_config}"

    # Validate image against allowlist — prevents creating containers from
    # cached images that are not (or no longer) on the allowlist.
    image = config.get("Image", "")
    if image:
        image_base = image.split(":")[0]
        normalized = normalize_image_name(image_base)
        allowed_images = load_allowlist()
        if normalized not in allowed_images:
            return False, f"Image not allowed: {image}. Add '{normalized}' to allowed-images.txt"

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


def check_volume_create(body_bytes):
    """Inspect a volume creation request — block driver-based bind mounts."""
    try:
        config = json.loads(body_bytes)
    except (json.JSONDecodeError, ValueError):
        return False, "Could not parse volume creation request"

    if not isinstance(config, dict):
        return False, "Could not parse volume creation request"

    driver = str(config.get("Driver", "")).strip().lower()
    if driver and driver != "local":
        return False, f"Custom volume drivers are not allowed: {config.get('Driver')}"

    driver_opts = config.get("DriverOpts", {})
    if driver_opts:
        return False, f"Volume driver options are not allowed: {driver_opts}"

    return True, ""


def check_image_pull(path):
    """Check if the image being pulled is on the allowlist."""
    # Parse the image name from query params: /images/create?fromImage=postgres&tag=15
    # Use findall to detect duplicate fromImage params — Docker uses the last value,
    # so an attacker could send ?fromImage=postgres&fromImage=evil to bypass a
    # first-match check. We validate ALL values to prevent this.
    matches = re.findall(r"[?&]fromImage=([^&]+)", path)
    if not matches:
        return False, "Could not determine image name from pull request"

    allowed_images = load_allowlist()
    for image in matches:
        image_decoded = unquote(image)
        image_base = image_decoded.split(":")[0]
        normalized = normalize_image_name(image_base)
        if normalized not in allowed_images:
            return False, f"Image not allowed: {image_decoded}. Add '{normalized}' to allowed-images.txt"

    return True, ""


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

    header_data = data[:header_end].decode("iso-8859-1", errors="replace")
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


def parse_http_response(data):
    """Parse an HTTP response, return (status_code, headers, body_start_offset)."""
    header_end = data.find(b"\r\n\r\n")
    if header_end == -1:
        return None, {}, len(data)

    header_data = data[:header_end].decode("iso-8859-1", errors="replace")
    lines = header_data.split("\r\n")
    status_line = lines[0]
    parts = status_line.split(" ", 2)
    try:
        status_code = int(parts[1]) if len(parts) >= 2 else None
    except ValueError:
        status_code = None

    headers = {}
    for line in lines[1:]:
        if ": " in line:
            k, v = line.split(": ", 1)
            headers[k.lower()] = v

    return status_code, headers, header_end + 4


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


def read_http_request(client_sock):
    """Read exactly one HTTP request from the client socket."""
    request_data = b""
    while b"\r\n\r\n" not in request_data:
        chunk = client_sock.recv(BUFFER_SIZE)
        if not chunk:
            raise ValueError("Could not read request headers")
        request_data += chunk
        if b"\r\n\r\n" not in request_data and len(request_data) > MAX_HEADER_SIZE:
            raise ValueError("Request headers too large")

    method, path, headers, body_offset = parse_http_request(request_data)
    if method is None:
        raise ValueError("Could not parse request")

    transfer_encoding = headers.get("transfer-encoding", "").strip().lower()
    if transfer_encoding and transfer_encoding != "identity":
        raise ValueError("Transfer-Encoding is not supported")

    content_length_raw = headers.get("content-length", "0").strip()
    try:
        content_length = int(content_length_raw) if content_length_raw else 0
    except ValueError as exc:
        raise ValueError("Invalid Content-Length") from exc
    if content_length < 0:
        raise ValueError("Invalid Content-Length")
    if content_length > MAX_BODY_SIZE:
        raise ValueError(f"Request body too large ({content_length} bytes, max {MAX_BODY_SIZE})")

    body = request_data[body_offset:]
    if len(body) > content_length:
        raise ValueError("Pipelined requests are not allowed")
    while len(body) < content_length:
        chunk = client_sock.recv(BUFFER_SIZE)
        if not chunk:
            raise ValueError("Incomplete request body")
        body += chunk
        if len(body) > content_length:
            raise ValueError("Pipelined requests are not allowed")

    request_bytes = request_data[:body_offset] + body
    return method, path, headers, body, body_offset, request_bytes


def read_http_response_headers(sock):
    """Read an HTTP response up to the end of its headers."""
    response_data = b""
    while b"\r\n\r\n" not in response_data:
        chunk = sock.recv(BUFFER_SIZE)
        if not chunk:
            raise ValueError("Could not read upstream response headers")
        response_data += chunk
        if b"\r\n\r\n" not in response_data and len(response_data) > MAX_HEADER_SIZE:
            raise ValueError("Upstream response headers too large")

    status_code, headers, body_offset = parse_http_response(response_data)
    if status_code is None:
        raise ValueError("Could not parse upstream response")

    return status_code, headers, body_offset, response_data


def rewrite_connection_close(request_bytes, body_offset):
    """Force Connection: close on non-hijacked requests."""
    header_data = request_bytes[:body_offset - 4].decode("iso-8859-1", errors="replace")
    body = request_bytes[body_offset:]
    lines = header_data.split("\r\n")
    rewritten = [lines[0]]
    for line in lines[1:]:
        lower = line.lower()
        if lower.startswith("connection:") or lower.startswith("proxy-connection:"):
            continue
        rewritten.append(line)
    rewritten.append("Connection: close")
    return "\r\n".join(rewritten).encode("iso-8859-1") + b"\r\n\r\n" + body


def request_can_hijack(method, path):
    """Return True when a validated request may switch protocols to a raw stream."""
    path_base = strip_version_prefix(path)
    return method == "POST" and (
        re.match(r"/containers/[^/]+/attach$", path_base)
        or re.match(r"/exec/[^/]+/start$", path_base)
    )


def response_is_hijacked(status_code, headers):
    """Return True when the daemon upgraded the connection to a raw stream."""
    connection = headers.get("connection", "").lower()
    upgrade = headers.get("upgrade", "").strip()
    content_type = headers.get("content-type", "").lower()
    return (
        status_code == 101
        or "upgrade" in connection
        or bool(upgrade)
        or "application/vnd.docker.raw-stream" in content_type
    )


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


def relay_response_only(client_sock, real_sock, initial_data=b""):
    """Relay only the daemon response; reject client data after the request."""
    if initial_data:
        client_sock.sendall(initial_data)

    sockets = [client_sock, real_sock]
    try:
        while sockets:
            readable, _, errored = select.select(sockets, [], sockets, 30)
            if errored:
                break
            for s in readable:
                data = s.recv(BUFFER_SIZE)
                if not data:
                    return
                if s is real_sock:
                    client_sock.sendall(data)
                else:
                    # The request has already been validated and forwarded.
                    # Any additional client data would be a new request on the
                    # same connection, which we reject to avoid tunneling.
                    return
    except OSError:
        pass


def handle_client(client_sock):
    """Handle a single client connection."""
    try:
        try:
            method, path, headers, body, body_offset, request_data = read_http_request(client_sock)
        except ValueError as exc:
            send_error(client_sock, 400, str(exc))
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

        elif inspection_type in ("container_create", "exec_create", "volume_create"):
            if len(body) == 0:
                send_error(client_sock, 400, "Missing Content-Length on inspected request")
                return

            if inspection_type == "container_create":
                allowed, reason = check_container_create(body)
            elif inspection_type == "exec_create":
                allowed, reason = check_exec_create(body)
            else:
                allowed, reason = check_volume_create(body)

            if not allowed:
                send_error(client_sock, 403, f"Blocked by socket proxy: {reason}")
                print(f"BLOCKED: {reason}", file=sys.stderr)
                return

        # Connect to the real socket and forward
        real_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        real_sock.connect(REAL_SOCKET)

        allow_hijack = request_can_hijack(method, path)
        if not allow_hijack:
            request_data = rewrite_connection_close(request_data, body_offset)

        real_sock.sendall(request_data)

        if allow_hijack:
            try:
                status_code, response_headers, _, response_data = read_http_response_headers(real_sock)
            except ValueError as exc:
                send_error(client_sock, 502, f"Proxy error: {str(exc)}")
                return

            client_sock.sendall(response_data)
            if response_is_hijacked(status_code, response_headers):
                stream_bidirectional(client_sock, real_sock)
            else:
                relay_response_only(client_sock, real_sock)
        else:
            relay_response_only(client_sock, real_sock)

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

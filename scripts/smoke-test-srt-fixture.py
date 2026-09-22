#!/usr/bin/env python3
import base64
import errno
import http.client
import json
import os
from pathlib import Path
import re
import selectors
import socket
import sys
from urllib.parse import unquote, urlsplit


TOKEN = b"srt-smoke-local-endpoint\n"
ORIGINAL = "protected-original\n"
PERMISSION_ERRORS = {errno.EPERM, errno.EACCES, errno.EROFS}


def require(condition, message):
  if not condition:
    raise RuntimeError(message)


def denied(operation, errors=PERMISSION_ERRORS):
  try:
    operation()
  except OSError as error:
    require(error.errno in errors, f"unrelated failure, not enforcement: {error}")
    return
  raise RuntimeError("denied operation succeeded; sandbox enforcement is absent")


def policy(root, unrestricted, allow_unix, domains):
  return {
    "network": {
      "unrestricted": unrestricted == "true",
      "allowedDomains": ["127.0.0.1"] if domains != "empty" else [],
      "deniedDomains": ["127.0.0.1"] if domains == "precedence" else [],
      "allowUnixSockets": [],
      "allowAllUnixSockets": allow_unix == "true",
      "allowLocalBinding": unrestricted == "true",
    },
    "filesystem": {
      "allowWrite": [str(root / "project")],
      "denyWrite": [str(root / "project/protected")],
      "denyRead": [],
      "allowRead": [],
    },
    "ignoreViolations": {},
    "enableWeakerNetworkIsolation": False,
  }


def prepare(root):
  for directory in (root / "project/protected", root / "outside"):
    directory.mkdir(exist_ok=True)
    for name in ("overwrite", "delete", "rename"):
      (directory / name).write_text(ORIGINAL)


def unchanged(root):
  for directory in (root / "project/protected", root / "outside"):
    require(sorted(path.name for path in directory.iterdir()) ==
            ["delete", "overwrite", "rename"], f"denied directory changed: {directory}")
    for path in directory.iterdir():
      require(path.read_text() == ORIGINAL, f"denied file changed: {path}")


def filesystem(root):
  project = root / "project"
  require(Path.cwd() == project, "sandbox did not start in the separate project cwd")
  allowed = project / "allowed"
  allowed.write_text("created")
  allowed.write_text("overwritten")
  require(allowed.read_text() == "overwritten", "allowed write did not persist")
  renamed = project / "allowed-renamed"
  allowed.rename(renamed)
  renamed.unlink()
  unchanged(root)
  for directory in (project / "protected", root / "outside"):
    denied(lambda: (directory / "created").write_text("escaped"))
    denied(lambda: (directory / "overwrite").write_text("escaped"))
    denied(lambda: (directory / "delete").unlink())
    denied(lambda: (directory / "rename").rename(directory / "renamed"))
  unchanged(root)


def unix(allowed, project):
  require(Path.cwd() == project, "Unix socket probe did not start in the project cwd")
  if allowed == "false":
    def create_socket():
      with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM):
        pass
    denied(create_socket, {errno.EPERM})
    return
  path = Path("probe.sock")
  with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
    try:
      server.bind(str(path))
      server.listen(1)
      server.settimeout(5)
      with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(5)
        client.connect(str(path))
        connection, _ = server.accept()
        with connection:
          connection.settimeout(5)
          connection.sendall(TOKEN)
          with client.makefile("rb") as response:
            require(response.readline() == TOKEN, "Unix socket payload mismatch")
    finally:
      if path.exists():
        path.unlink()


def serve(ready):
  with selectors.DefaultSelector() as selector:
    ports = {}
    try:
      for protocol in ("http", "tcp"):
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.bind(("127.0.0.1", 0))
        server.listen(16)
        selector.register(server, selectors.EVENT_READ, protocol)
        ports[protocol] = server.getsockname()[1]
      pending = ready.with_suffix(".pending")
      pending.write_text(json.dumps(ports))
      pending.rename(ready)
      while True:
        for key, _ in selector.select():
          connection, _ = key.fileobj.accept()
          with connection:
            connection.settimeout(5)
            try:
              if key.data == "http":
                request = b""
                while b"\r\n\r\n" not in request and len(request) < 16384:
                  data = connection.recv(4096)
                  if not data:
                    break
                  request += data
                connection.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " +
                                   str(len(TOKEN)).encode() + b"\r\n\r\n" + TOKEN)
              else:
                connection.sendall(TOKEN)
            except (OSError, TimeoutError):
              pass
    finally:
      for key in list(selector.get_map().values()):
        key.fileobj.close()


def check_http(port, host, filtered, blocked=False):
  headers = {}
  target = f"http://{host}:{port}/smoke"
  if filtered:
    proxy = urlsplit(os.environ.get("http_proxy", ""))
    require(proxy.scheme == "http" and proxy.hostname and proxy.port,
            "sandbox did not supply an HTTP proxy")
    connection = http.client.HTTPConnection(proxy.hostname, proxy.port, timeout=5)
    if proxy.username is not None:
      credentials = f"{unquote(proxy.username)}:{unquote(proxy.password or '')}"
      headers["Proxy-Authorization"] = "Basic " + base64.b64encode(credentials.encode()).decode()
  else:
    connection = http.client.HTTPConnection(host, port, timeout=5)
    target = "/smoke"
  try:
    connection.request("GET", target, headers=headers)
    response = connection.getresponse()
    body = response.read()
    if blocked:
      require(response.status == 403 and
              response.getheader("X-Proxy-Error") == "blocked-by-allowlist",
              f"expected policy denial for {host}, got HTTP {response.status}: {body!r}")
    else:
      require(response.status == 200 and body == TOKEN,
              f"local HTTP payload mismatch for {host}: {response.status}, {body!r}")
  finally:
    connection.close()


def network(endpoints, mode):
  ports = json.loads(endpoints.read_text())
  if mode == "direct":
    for host in ("127.0.0.1", "localhost"):
      check_http(ports["http"], host, False)
    with socket.create_connection(("127.0.0.1", ports["tcp"]), timeout=5) as connection:
      with connection.makefile("rb") as response:
        require(response.readline() == TOKEN, "non-HTTP TCP payload mismatch")
  else:
    check_http(ports["http"], "127.0.0.1", True, blocked=mode == "blocked")
    check_http(ports["http"], "localhost", True, blocked=True)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
      connection.settimeout(5)
      denied(lambda: connection.connect(("127.0.0.1", ports["tcp"])),
             {errno.ECONNREFUSED} if sys.platform == "linux" else {errno.EPERM, errno.EACCES})


def rejection(kind, status, log, marker):
  output = log.read_text()
  print(output, end="", file=sys.stderr)
  require(status == "1", f"expected rejection exit 1, got {status}")
  require(not marker.exists(), f"rejected command ran: {marker}")
  if kind == "schema":
    require("Invalid configuration" in output and "network.allowedDomains" in output and
            "network.deniedDomains" in output, "missing schema validation diagnostic")
  else:
    reason = (r"missing|not found|not available|unavailable|required" if kind == "missing"
              else r"not executable|non.executable|permission denied|EACCES")
    require(any("apply-seccomp" in line and re.search(r"^Error\b", line) and
                re.search(reason, line, re.IGNORECASE) for line in output.splitlines()),
            f"missing explicit {kind} helper error; an unrelated failure is not enforcement")


def main():
  command, *args = sys.argv[1:]
  completion = None
  if command == "probe":
    completion = Path(args[0])
    command, *args = args[1:]
  if command == "policy":
    print(json.dumps(policy(Path(args[0]), *args[1:])))
  elif command == "bad-policy":
    config = policy(Path(args[0]), "true", "true", "empty")
    config["network"] = {"unrestricted": True}
    print(json.dumps(config))
  elif command == "unix":
    unix(args[0], Path(args[1]))
  elif command == "network":
    network(Path(args[0]), args[1])
  elif command == "rejection":
    rejection(args[0], args[1], Path(args[2]), Path(args[3]))
  else:
    actions = {"serve": serve, "prepare": prepare, "filesystem": filesystem, "unchanged": unchanged}
    actions[command](Path(args[0]))
  if completion is not None:
    completion.write_text("completed\n")


if __name__ == "__main__":
  try:
    main()
  except Exception as error:
    sys.exit(f"FAIL - {error}")
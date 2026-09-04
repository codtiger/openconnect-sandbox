#!/usr/bin/env python3
"""Integration test: guardian EOF must kill an uncooperative descendant."""

import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / ".build" / "arm64-apple-macosx" / "debug"
SUPERVISOR = BUILD / "OpenConnectSandboxSupervisor"
GROUP_EXEC = BUILD / "OpenConnectSandboxExec"
FIXTURE = ROOT / "Tests" / "Fixtures" / "fake-openconnect.py"


def available_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def process_exists(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main() -> int:
    if not SUPERVISOR.exists() or not GROUP_EXEC.exists():
        print("Build debug products before running the lifecycle test.", file=sys.stderr)
        return 69

    port = available_port()
    with tempfile.TemporaryDirectory(prefix="openconnect-sandbox-test-") as directory:
        child_file = Path(directory) / "child.pid"
        profile_id = str(uuid.uuid4()).upper()
        request = {
            "profile": {
                "id": profile_id,
                "name": "Lifecycle Test",
                "authenticationMode": "OpenConnect",
                "server": "vpn.invalid.example",
                "username": "",
                "authGroup": "",
                "vpnProtocol": "anyconnect",
                "socksPort": port,
                "localForwards": [],
                "additionalArguments": [f"--fixture-pid-file={child_file}"],
                "autoReconnect": False,
                "connectOnLaunch": False,
            },
            "toolPaths": {
                "openConnect": str(FIXTURE),
                "ocproxy": "/usr/bin/true",
                "openConnectSSO": "",
            },
            "groupExecPath": str(GROUP_EXEC),
            "reconnectAttempt": 0,
        }
        supervisor = subprocess.Popen(
            [str(SUPERVISOR)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        assert supervisor.stdin and supervisor.stdout
        supervisor.stdin.write(json.dumps(request) + "\n")
        supervisor.stdin.flush()

        deadline = time.monotonic() + 10
        connected = False
        while time.monotonic() < deadline:
            event = json.loads(supervisor.stdout.readline())
            if event.get("phase") == "connected":
                connected = True
                break
            if event.get("phase") == "failed":
                raise RuntimeError(event.get("message", "supervisor failed"))
        if not connected:
            raise RuntimeError("proxy never became ready")

        child_pid = int(child_file.read_text(encoding="utf-8"))
        child_group = os.getpgid(child_pid)
        supervisor.stdin.close()  # Simulate GUI crash/Force Quit.
        try:
            status = supervisor.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.kill(supervisor.pid, signal.SIGKILL)
            os.killpg(child_group, signal.SIGKILL)
            raise RuntimeError("supervisor did not exit after lifeline EOF")

        deadline = time.monotonic() + 2
        while process_exists(child_pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        if process_exists(child_pid):
            os.killpg(child_group, signal.SIGKILL)
            raise RuntimeError(f"descendant {child_pid} survived supervisor exit")
        if status != 0:
            raise RuntimeError(f"supervisor exited with {status}")

    print("Lifecycle integration test passed: lifeline EOF removed the stubborn descendant.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

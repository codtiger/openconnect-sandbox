#!/usr/bin/env python3
"""Test fixture that behaves like OpenConnect plus a stubborn ocproxy child."""

import os
import re
import signal
import socket
import subprocess
import sys
import time


def child() -> None:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    while True:
        time.sleep(1)


def leader(arguments: list[str]) -> None:
    script = arguments[arguments.index("--script") + 1]
    port = int(script.rsplit("-D ", 1)[1].split()[0])
    pid_argument = next(value for value in arguments if value.startswith("--fixture-pid-file="))
    pid_file = pid_argument.split("=", 1)[1]

    descendant = subprocess.Popen(
        [sys.executable, __file__, "--stubborn-child"],
        start_new_session=True,
    )
    with open(pid_file, "w", encoding="utf-8") as handle:
        handle.write(str(descendant.pid))
    tracking_match = re.search(r"echo \$\$ > '([^']+)'; exec", script)
    if tracking_match:
        with open(tracking_match.group(1), "w", encoding="utf-8") as handle:
            handle.write(str(descendant.pid))

    signal.signal(signal.SIGINT, lambda _signal, _frame: sys.exit(0))
    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", port))
    server.listen()
    server.settimeout(0.25)
    while True:
        try:
            connection, _ = server.accept()
        except TimeoutError:
            continue
        with connection:
            if connection.recv(3) == b"\x05\x01\x00":
                connection.sendall(b"\x05\x00")


if __name__ == "__main__":
    if "--stubborn-child" in sys.argv:
        child()
    leader(sys.argv[1:])

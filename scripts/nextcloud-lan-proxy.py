#!/usr/bin/env python3
"""TCP proxy: listen on LAN (0.0.0.0:PORT) → forward to Nextcloud on 127.0.0.1:PORT.

Needed because Docker Desktop (vpnkit/gvisor) + VPN often accepts LAN
connections to published ports but returns empty HTTP responses.

Default maps:
  11000 → Nextcloud (AIO apache in reverse-proxy mode)
  8080  → AIO interface (HTTPS, self-signed)
"""
from __future__ import annotations

import argparse
import os
import select
import signal
import socket
import sys
import threading

DEFAULT_MAPS = ((11000, 11000), (8080, 8080))
PID_FILE_DEFAULT = os.path.join(os.path.dirname(__file__), ".nextcloud-lan-proxy.pid")


def pipe(a: socket.socket, b: socket.socket) -> None:
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                continue
            for src in r:
                dst = b if src is a else a
                data = src.recv(65536)
                if not data:
                    return
                dst.sendall(data)
    except OSError:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def handle(client: socket.socket, target: tuple[str, int]) -> None:
    upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        upstream.connect(target)
    except OSError as exc:
        print(f"proxy: connect to {target} failed: {exc}", file=sys.stderr)
        client.close()
        return
    t1 = threading.Thread(target=pipe, args=(client, upstream), daemon=True)
    t1.start()
    t1.join()


def serve_one(listen: tuple[str, int], target: tuple[str, int]) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(listen)
    srv.listen(128)
    print(
        f"nextcloud-lan-proxy listening on {listen[0]}:{listen[1]} → {target[0]}:{target[1]}",
        flush=True,
    )

    while True:
        try:
            client, _addr = srv.accept()
        except OSError:
            break
        threading.Thread(target=handle, args=(client, target), daemon=True).start()


def parse_map(value: str) -> tuple[int, int]:
    if ":" not in value:
        raise argparse.ArgumentTypeError(f"expected listen:target, got {value!r}")
    listen_s, target_s = value.split(":", 1)
    return int(listen_s), int(target_s)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--map",
        action="append",
        type=parse_map,
        dest="maps",
        help="listen_port:target_port (repeatable). Default: 11000:11000 and 8080:8080",
    )
    p.add_argument("--listen-host", default="0.0.0.0")
    p.add_argument("--target-host", default="127.0.0.1")
    p.add_argument("--pid-file", default=PID_FILE_DEFAULT)
    p.add_argument("--daemon", action="store_true", help="fork to background and write pid file")
    args = p.parse_args()

    maps = args.maps if args.maps else list(DEFAULT_MAPS)

    if args.daemon:
        if os.fork() != 0:
            sys.exit(0)
        os.setsid()
        if os.fork() != 0:
            sys.exit(0)
        with open(args.pid_file, "w", encoding="utf-8") as fh:
            fh.write(str(os.getpid()))
        sys.stdin.close()
        sys.stdout = open(os.devnull, "w")  # noqa: SIM115
        sys.stderr = open(os.devnull, "w")  # noqa: SIM115

    def _stop(*_args: object) -> None:
        sys.exit(0)

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    threads = []
    for listen_port, target_port in maps:
        t = threading.Thread(
            target=serve_one,
            args=((args.listen_host, listen_port), (args.target_host, target_port)),
            daemon=True,
        )
        t.start()
        threads.append(t)

    for t in threads:
        t.join()


if __name__ == "__main__":
    main()

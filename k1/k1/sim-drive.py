#!/usr/bin/env python3
"""Drive a robotd over its unix socket: hello -> enable -> move intents.

JSON-RPC 2.0 / NDJSON, one object per line — the same wire format `robotctl` speaks.
Run this ON the robot (K3), where `/run/robotd.sock` lives.

    python3 sim-drive.py --enable --vx 0.2 --seconds 15

`robot.move` is a *continuous intent*: a notification with no id and no reply, last-writer-wins.
The deadman is 500 ms, so anything faster than 2 Hz keeps it alive; this sends at 20 Hz.
"""
from __future__ import annotations

import argparse
import json
import socket
import time

API_VERSION = 23


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default="/run/robotd.sock")
    parser.add_argument("--vx", type=float, default=0.2, help="forward, m/s")
    parser.add_argument("--vyaw", type=float, default=0.0, help="yaw rate, rad/s")
    parser.add_argument("--seconds", type=float, default=10.0)
    parser.add_argument("--enable", action="store_true", help="send robot.enable first")
    parser.add_argument(
        "--init",
        action="store_true",
        help="send robot.init after enabling — a seated boot then rises via the sitstand policy",
    )
    args = parser.parse_args()

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(args.socket)
    stream = sock.makefile("rwb")
    next_id = 1

    def request(method: str, params: dict, reply: bool = True):
        nonlocal next_id
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if reply:
            message["id"] = next_id
            next_id += 1
        stream.write((json.dumps(message) + "\n").encode())
        stream.flush()
        if not reply:
            return None
        line = stream.readline()
        if not line:
            raise SystemExit("robotd closed the connection")
        return json.loads(line)

    print("hello ->", request("hello", {"api_version": API_VERSION}))
    if args.enable:
        print("enable ->", request("robot.enable", {"on": True, "toggle": False}))
    if args.init:
        # The rise window is `sitstand.unwind_s` = 1 s, so this has to land while the loop is
        # already driving — hence enable first, init second.
        print("init   ->", request("robot.init", {}))

    print(f"driving vx={args.vx} vyaw={args.vyaw} for {args.seconds:.0f}s …")
    started = time.perf_counter()
    while time.perf_counter() - started < args.seconds:
        request("robot.move", {"vx": args.vx, "vy": 0.0, "vyaw": args.vyaw}, reply=False)
        time.sleep(0.05)

    request("robot.move", {"vx": 0.0, "vy": 0.0, "vyaw": 0.0}, reply=False)
    print("stopped")


if __name__ == "__main__":
    main()

"""Watch a duck-body from the side: read-only, one line per sample.

The daemon holds the sim's primary connection; the simulator is a ThreadingTCPServer, so a
second connection is fine (all body reads take the world lock). This is how we see whether the
K3 daemon actually moved the duck — `trunk` is the extra field no real robot can measure.

    python observe.py --seconds 20
"""
from __future__ import annotations

import argparse
import json
import socket
import time


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7801)
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--hz", type=float, default=5.0)
    args = parser.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5.0)
    stream = sock.makefile("rwb")

    def call(**request):
        stream.write((json.dumps(request) + "\n").encode())
        stream.flush()
        line = stream.readline()
        if not line:
            raise SystemExit("simulator closed the connection")
        return json.loads(line)

    call(op="hello", protocol=1)
    started = time.perf_counter()
    print(f"{'t':>6}  {'x':>7}  {'y':>7}  {'z':>7}  {'gz':>7}")
    while time.perf_counter() - started < args.seconds:
        state = call(op="read")
        x, y, z = state["trunk"]
        print(f"{time.perf_counter() - started:6.1f}  {x:+7.3f}  {y:+7.3f}  {z:7.3f}  "
              f"{state['imu']['gravity'][2]:+7.3f}")
        time.sleep(1.0 / args.hz)


if __name__ == "__main__":
    main()

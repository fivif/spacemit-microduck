#!/usr/bin/env python3
"""A stand-in for the MuJoCo body server that lives on the board itself.

The `--sim` client in `duck-control` speaks the same NDJSON protocol as
`mjlab_microduck.sim.body_server`, so a *real* run of the simulator is normally
reached over the network — the laptop on one end, the board on the other. That
is the right way to watch the duck, and the wrong way to time the control loop:
one `read`+`write` pair through an SSH tunnel measured p50 8.7 ms / p99 63 ms
against a 20 ms tick, so the tunnel alone owns the missed ticks and the board's
own headroom is invisible behind it.

This script answers that protocol from 127.0.0.1 with a slew-limited
first-order follower standing in for the physics:

    robotd --sim 127.0.0.1:7802      # 50.0 of 50.0 Hz, 0 missed ticks

What it does *not* do is physics, contact, or anything worth watching — it
exists to take the network out of the measurement. The policy still runs on
every tick, so the loop rate it reports is the board's own.

    python3 stub-body.py [port]      # port defaults to 7801; use another one
                                     # if the tunnel already holds it
"""

import json
import socket
import socketserver
import sys
import time

NUM_JOINTS = 15

# The SIT keyframe, so robotd takes the same `seated boot detected` path it
# takes against the real simulator.
SIT = [0.0, 0.0, -0.5236, 1.0472, 0.0, 0.5, 1.6, 0.0, 0.0, 0.0,
       0.0, 0.0, 0.5236, -1.0472, 0.0]

RATE = 8.0  # rad/s the joints are allowed to move toward the commanded targets


class Plant:
    """Joints chase their targets at a fixed rate. Not physics — a clock."""

    def __init__(self) -> None:
        self.targets = list(SIT)
        self.positions = list(SIT)
        self.velocities = [0.0] * NUM_JOINTS
        self.t = time.monotonic()

    def step(self) -> None:
        now = time.monotonic()
        dt = min(max(now - self.t, 0.0), 0.1)
        self.t = now
        for i in range(NUM_JOINTS):
            error = self.targets[i] - self.positions[i]
            move = max(-RATE * dt, min(RATE * dt, error))
            self.positions[i] += move
            self.velocities[i] = move / dt if dt > 0 else 0.0


class Handler(socketserver.StreamRequestHandler):
    """One daemon per duck, one connection at a time — as on the real bus."""

    def handle(self) -> None:
        self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        plant: Plant = self.server.plant
        for raw in self.rfile:
            try:
                answer = self.dispatch(plant, json.loads(raw))
            except Exception as error:  # a bad frame must not take the stand-in down
                answer = {"error": str(error)}
            self.wfile.write((json.dumps(answer) + "\n").encode())
            self.wfile.flush()

    def dispatch(self, plant: Plant, request: dict) -> dict:
        op = request.get("op")
        if op == "hello":
            asked = request.get("protocol")
            if asked != 1:
                raise ValueError(f"the daemon speaks protocol {asked}, this stand-in speaks 1")
            return {"protocol": 1}
        if op == "read":
            plant.step()
            return {
                "positions": plant.positions,
                "velocities": plant.velocities,
                "currents_ma": [180.0] * NUM_JOINTS,
                "imu": {
                    "gyro": [0.0, 0.0, 0.0],
                    "gravity": [0.0, 0.0, -1.0],
                    "quat": [1.0, 0.0, 0.0, 0.0],
                },
            }
        if op == "write":
            plant.targets = [float(v) for v in request["targets"]]
            return {}
        if op in ("gain", "torque"):
            return {}
        if op == "slow":
            return {"volts": 7.4, "temps_c": [32.0] * NUM_JOINTS}
        raise ValueError(f"unknown op {op!r}")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7801
    server = Server(("127.0.0.1", port), Handler)
    server.plant = Plant()
    server.serve_forever()

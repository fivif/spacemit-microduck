"""Minimal robotd stand-in: drives a duck-body over the sim protocol.

Speaks the same NDJSON protocol as `duck_control::sim` (protocol 1):
    hello -> read -> gain/torque -> write targets (50 Hz) -> read

Usage:
    python test-client.py [--host 127.0.0.1] [--port 7801] [--steps 250] [--hold]

It holds the HOME pose (no policy), then reports trunk_z / a knee angle / loop rate,
so "the sim is alive and the physics settles" is a measured statement.
"""
from __future__ import annotations

import argparse
import json
import socket
import time

HOME_POSE = [
    0.0, -0.0873, -0.4579, -0.0049, 0.4530,
    0.3491, 0.3491, 0.0, 0.0, 0.0,
    0.0, 0.0873, 0.4579, 0.0049, -0.4530,
]
JOINT_NAMES = [
    "left_hip_yaw", "left_hip_roll", "left_hip_pitch", "left_knee", "left_ankle",
    "neck_pitch", "head_pitch", "head_yaw", "head_roll", "mouth",
    "right_hip_yaw", "right_hip_roll", "right_hip_pitch", "right_knee", "right_ankle",
]
LEFT_KNEE = JOINT_NAMES.index("left_knee")


class DuckBody:
    def __init__(self, host: str, port: int) -> None:
        self.sock = socket.create_connection((host, port), timeout=5.0)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.file = self.sock.makefile("rwb")

    def call(self, **request) -> dict:
        self.file.write((json.dumps(request) + "\n").encode())
        self.file.flush()
        line = self.file.readline()
        if not line:
            raise ConnectionError("simulator closed the connection")
        answer = json.loads(line)
        if "error" in answer:
            raise RuntimeError(answer["error"])
        return answer

    def close(self) -> None:
        self.file.close()
        self.sock.close()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7801)
    parser.add_argument("--steps", type=int, default=250, help="50 Hz control ticks (250 = 5 s)")
    parser.add_argument("--hold", action="store_true", help="keep holding after the report")
    args = parser.parse_args()

    duck = DuckBody(args.host, args.port)
    hello = duck.call(op="hello", protocol=1)
    print(f"hello -> {hello}")

    state = duck.call(op="read")
    print(f"first read: trunk_z={state['trunk_z']:.4f} m, sim_time={state['sim_time']:.3f} s, "
          f"imu.gravity={[round(v, 3) for v in state['imu']['gravity']]}")
    print(f"  joints on the wire: {len(state['positions'])} (daemon's JOINT_NAMES)")

    print(f"gain(kp=200) -> {duck.call(op='gain', kp=200)}")
    print(f"torque(on)   -> {duck.call(op='torque', on=True)}")

    # `robotd init` ramps to HOME over 2 s rather than jumping — a step command from SIT
    # topples the duck. Mimic that here.
    start = list(state["positions"])
    ramp_ticks = 125  # 2.5 s at 50 Hz
    print(f"ramping SIT -> HOME over {ramp_ticks * 0.02:.1f} s")

    started = time.perf_counter()
    period = 0.020
    next_tick = started
    worst = 0.0
    for step in range(args.steps):
        alpha = min(1.0, (step + 1) / ramp_ticks)
        targets = [(1.0 - alpha) * a + alpha * b for a, b in zip(start, HOME_POSE)]
        duck.call(op="write", targets=targets)
        state = duck.call(op="read")
        next_tick += period
        slack = next_tick - time.perf_counter()
        if slack > 0.001:
            time.sleep(slack)
        else:
            worst = max(worst, -slack)
        if (step + 1) % 50 == 0:
            print(f"  t={state['sim_time']:6.2f}s  trunk_z={state['trunk_z']:.4f}  "
                  f"gz={state['imu']['gravity'][2]:+.3f}  "
                  f"left_knee={state['positions'][LEFT_KNEE]:+.4f}")

    elapsed = time.perf_counter() - started
    state = duck.call(op="read")
    print(f"\n{args.steps} ticks in {elapsed:.2f}s = {args.steps / elapsed:.1f} Hz "
          f"(worst lateness {worst * 1000:.1f} ms)")
    print(f"final: trunk_z={state['trunk_z']:.4f} m  "
          f"gravity_z={state['imu']['gravity'][2]:+.3f}  "
          f"left_knee={state['positions'][LEFT_KNEE]:+.4f} rad")

    if args.hold:
        print("holding HOME (ctrl-c to stop)…")
        try:
            while True:
                duck.call(op="write", targets=HOME_POSE)
                time.sleep(period)
        except KeyboardInterrupt:
            pass
    duck.close()


if __name__ == "__main__":
    main()

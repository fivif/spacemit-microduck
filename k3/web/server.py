#!/usr/bin/env python3
"""A minimal web console for robotd — runs **on the robot**, talks to its unix socket.

Stdlib only: the board has python3.14 and no pip wheels for riscv64 worth depending on.

    python3 server.py --port 8081

Endpoints (all JSON):
    GET  /              the console (index.html)
    GET  /api/state     robot.state + robot.health, merged, plus this server's drive intent
    GET  /api/skills    what `robot.do` answers to (dynamic — the set is config)
    POST /api/move      {vx, vy, vyaw} — continuous intent, streamed at 20 Hz
    POST /api/action    {action: enable|disable|rise|init|stop|relax}
    POST /api/skill     {name}

**The drive stream lives here, not in the browser.** A phone that sleeps, a Wi-Fi hiccup or a
backgrounded tab must not leave a moving robot: the browser posts intents, this process forwards
them at a fixed rate, and both stop on their own — the server's 0.4 s TTL and robotd's own 500 ms
deadman. Three independent stops, none of them requiring the client to be well-behaved.
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
API_VERSION = 23
DRIVE_HZ = 20.0
DRIVE_TTL = 0.4  # seconds of silence before the stream stops; the daemon's deadman is 500 ms


class Robot:
    """One persistent NDJSON JSON-RPC connection to robotd, with reconnect."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.lock = threading.Lock()
        self.sock: socket.socket | None = None
        self.stream = None
        self.next_id = 1
        self.drive = {"vx": 0.0, "vy": 0.0, "vyaw": 0.0, "at": 0.0}
        self.last_error: str | None = None

    # ── the wire ──────────────────────────────────────────────────────────

    def _open(self) -> None:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(self.path)
        self.sock, self.stream = sock, sock.makefile("rwb")
        self._exchange("hello", {"api_version": API_VERSION})

    def _exchange(self, method: str, params: dict, reply: bool = True):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if reply:
            message["id"] = self.next_id
            self.next_id += 1
        self.stream.write((json.dumps(message) + "\n").encode())
        self.stream.flush()
        if not reply:
            return None
        line = self.stream.readline()
        if not line:
            raise ConnectionError("robotd closed the connection")
        return json.loads(line)

    def call(self, method: str, params: dict | None = None, reply: bool = True):
        """One call, reconnecting once on failure. `reply=False` is a notification."""
        with self.lock:
            try:
                if self.stream is None:
                    self._open()
                result = self._exchange(method, params or {}, reply)
                self.last_error = None
                return result
            except Exception as first:
                self._close()
                try:
                    self._open()
                    result = self._exchange(method, params or {}, reply)
                    self.last_error = None
                    return result
                except Exception as second:
                    self.last_error = f"{first}; retry: {second}"
                    raise

    def _close(self) -> None:
        for closer in (self.stream, self.sock):
            try:
                closer.close()
            except Exception:
                pass
        self.stream = self.sock = None

    # ── the drive stream ──────────────────────────────────────────────────

    def set_drive(self, vx: float, vy: float, vyaw: float) -> None:
        self.drive.update(vx=vx, vy=vy, vyaw=vyaw, at=time.monotonic())

    def drive_forever(self) -> None:
        period = 1.0 / DRIVE_HZ
        while True:
            time.sleep(period)
            if time.monotonic() - self.drive["at"] > DRIVE_TTL:
                continue
            try:
                self.call(
                    "robot.move",
                    {"vx": self.drive["vx"], "vy": self.drive["vy"], "vyaw": self.drive["vyaw"]},
                    reply=False,
                )
            except Exception:
                pass  # the next tick tries again; a stale stream simply goes quiet


class StateFeed:
    """A second connection that subscribes to `robot.state` and keeps the newest frame.

    `robot.state` is not a callable method — it is the notification `robot.subscribe` turns a
    connection into (calling it returns "unknown method"). So the live posture, the policy label
    and the fallen/limp flags arrive here, on their own socket, at their own rate.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.latest: dict | None = None
        self.at = 0.0
        self.error: str | None = None

    @staticmethod
    def _send(stream, method: str, params: dict, ident: int) -> None:
        stream.write((json.dumps({"jsonrpc": "2.0", "id": ident, "method": method,
                                  "params": params}) + "\n").encode())
        stream.flush()

    def run(self) -> None:
        while True:
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.settimeout(5.0)
                sock.connect(self.path)
                stream = sock.makefile("rwb")
                self._send(stream, "hello", {"api_version": API_VERSION}, 1)
                stream.readline()
                self._send(stream, "robot.subscribe", {"hz": 10}, 2)
                stream.readline()
                while True:
                    line = stream.readline()
                    if not line:
                        raise ConnectionError("robotd closed the state stream")
                    message = json.loads(line)
                    if message.get("method") == "robot.state":
                        self.latest = message.get("params")
                        self.at = time.monotonic()
                        self.error = None
            except Exception as error:
                self.error = str(error)
                self.latest = None
                time.sleep(1.0)


ROBOT: Robot
FEED: StateFeed


# ── HTTP ──────────────────────────────────────────────────────────────────


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:  # quieter than the default
        pass

    def _send(self, code: int, body: bytes, kind: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _json(self, payload: dict, code: int = 200) -> None:
        self._send(code, json.dumps(payload).encode(), "application/json")

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self) -> None:  # noqa: N802 — stdlib naming
        if self.path in ("/", "/index.html"):
            try:
                page = (ROOT / "index.html").read_bytes()
            except FileNotFoundError:
                self._send(404, b"index.html is missing", "text/plain")
                return
            self._send(200, page, "text/html; charset=utf-8")
            return
        if self.path == "/api/state":
            self._json(self.state())
            return
        if self.path == "/api/skills":
            self._json(self.skills())
            return
        self._send(404, b"not found", "text/plain")

    def do_POST(self) -> None:  # noqa: N802
        try:
            body = self._read_json()
            if self.path == "/api/move":
                ROBOT.set_drive(
                    float(body.get("vx", 0.0)),
                    float(body.get("vy", 0.0)),
                    float(body.get("vyaw", 0.0)),
                )
                self._json({"ok": True})
                return
            if self.path == "/api/action":
                self._json(self.action(str(body.get("action", ""))))
                return
            if self.path == "/api/skill":
                result = ROBOT.call("robot.do", {"skill": str(body.get("name", ""))})
                self._json({"ok": True, "result": result})
                return
            self._send(404, b"not found", "text/plain")
        except Exception as error:
            self._json({"ok": False, "error": str(error)}, 500)

    # ── endpoints ─────────────────────────────────────────────────────────

    def state(self) -> dict:
        out: dict = {"drive": dict(ROBOT.drive)}
        if FEED.latest is not None:
            out["state"] = FEED.latest
            out["state_age_ms"] = int((time.monotonic() - FEED.at) * 1000)
        elif FEED.error:
            out["state_error"] = FEED.error
        try:
            health = ROBOT.call("robot.health")
            out["health"] = (health or {}).get("result")
        except Exception as error:
            out["health_error"] = str(error)
        return out

    def skills(self) -> dict:
        try:
            result = ROBOT.call("robot.skills")
            return (result or {}).get("result") or {}
        except Exception as error:
            return {"error": str(error)}

    def action(self, action: str) -> dict:
        """The named sequences, in one place, because the order is load-bearing.

        `rise` has two shapes, and picking the wrong one puts a duck on the floor:

        * **Fresh boot, seated detection pending** — `robot.enable` then `robot.init`. The init
          path sees the seated boot and runs the sitstand network, and the policy only drives
          once `robot.enable` has been sent. The rise window is one second wide
          (`sitstand.unwind_s`).
        * **Already latched sitting** (someone pressed the sit toggle) — `sit_toggle` again. A
          second `robot.init` would re-home the joints with a *linear ramp*, which drags a folded
          duck over instead of unfolding it; the log says `re-homing from the current pose` and
          the duck ends on its side. The sitstand network is the only thing that can rise it.
        """
        match action:
            case "enable":
                ROBOT.call("robot.enable", {"on": True, "toggle": False})
            case "disable":
                ROBOT.call("robot.enable", {"on": False, "toggle": False})
            case "rise":
                ROBOT.call("robot.enable", {"on": True, "toggle": False})
                if (FEED.latest or {}).get("policy") == "sit":
                    ROBOT.call("robot.do", {"skill": "sit_toggle"})
                else:
                    ROBOT.call("robot.init", {})
            case "init":
                ROBOT.call("robot.init", {})
            case "stop":
                ROBOT.set_drive(0.0, 0.0, 0.0)
                ROBOT.call("robot.stop", {})
            case "relax":
                ROBOT.set_drive(0.0, 0.0, 0.0)
                ROBOT.call("robot.relax", {})
            case _:
                return {"ok": False, "error": f"unknown action {action!r}"}
        return {"ok": True, "action": action}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument(
        "--socket",
        default=os.environ.get("ROBOT_SOCKET", "/run/robotd.sock"),
        help="robotd's unix socket",
    )
    args = parser.parse_args()

    global ROBOT, FEED
    ROBOT = Robot(args.socket)
    FEED = StateFeed(args.socket)
    threading.Thread(target=ROBOT.drive_forever, daemon=True).start()
    threading.Thread(target=FEED.run, daemon=True).start()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"== duck console on http://{args.host}:{args.port}  (robotd at {args.socket})", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

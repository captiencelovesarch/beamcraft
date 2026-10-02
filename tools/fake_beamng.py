#!/usr/bin/env python3
"""Stand-in for BeamNG: drives the hidden Minecraft through the BeamCraft protocol.

Pretends the world is flat ground at MC y=GROUND with a 1 m kerb along x=6, then
checks the things BeamNG relies on: world comes up, atlas pages get written, Steve
stands and walks on the fake terrain, can't walk through the kerb but can jump it,
and placing / breaking a block on the ground streams block updates back.

    tools/run_backend.sh &      # in another terminal
    tools/fake_beamng.py --userpath /tmp/bc-user
"""
import argparse
import json
import math
import os
import socket
import sys
import time

GROUND = 10.0
KERB_X = 6.0       # columns with x >= KERB_X are 1 m higher
RES = 0.5


def height_at(x):
    return GROUND + (1.0 if x >= KERB_X else 0.0)


class Peer:
    def __init__(self, port):
        self.sock = None
        deadline = time.time() + 300
        while time.time() < deadline:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=2)
                break
            except OSError:
                time.sleep(1)
        if not self.sock:
            sys.exit("Minecraft never started listening")
        self.sock.setblocking(False)
        self.buf = b""
        self.pose = None
        self.blocks = {}
        self.states = {}
        self.atlas = None
        self.ready = False
        self.msgs = []
        self.sampled = {}
        self.active = False

    def send(self, msg):
        self.sock.sendall((json.dumps(msg) + "\n").encode())

    def pump(self):
        while True:
            try:
                data = self.sock.recv(1 << 20)
            except BlockingIOError:
                break
            if not data:
                sys.exit("Minecraft closed the connection")
            self.buf += data
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            if not line:
                continue
            m = json.loads(line)
            self.msgs.append(m)
            t = m.get("t")
            if t == "p":
                self.pose = m
            elif t == "ready":
                self.ready = True
            elif t == "atlas":
                self.atlas = m
            elif t == "states":
                for d in m["d"]:
                    self.states[d["i"]] = d
            elif t == "blocks":
                l = m["l"]
                for n in range(0, len(l), 4):
                    self.blocks[(l[n], l[n + 1], l[n + 2])] = l[n + 3]
            elif t == "chat":
                print("  [chat]", m.get("m"))

    def terrain(self):
        """What BeamNG's terrain.lua does: send unsampled columns around Steve's feet."""
        if not self.pose or not self.active:
            return
        fx, fz = self.pose["x"], self.pose["z"]
        ci, ck = math.floor(fx / RES), math.floor(fz / RES)
        n = 10
        cells = []
        for di in range(-n, n + 1):
            for dk in range(-n, n + 1):
                key = (ci + di, ck + dk)
                if key in self.sampled:
                    continue
                self.sampled[key] = True
                cx = (key[0] + 0.5) * RES
                cells += [key[0], key[1], height_at(cx)]
        if cells:
            self.send({"t": "ter", "r": RES, "c": cells})

    def run(self, seconds, inp=None, every=None):
        end = time.time() + seconds
        while time.time() < end:
            self.pump()
            self.terrain()
            if inp is not None:
                self.send(dict(inp, t="in"))
                inp.pop("ev", None)
            if every:
                every()
            time.sleep(0.05)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=47800)
    ap.add_argument("--userpath", default="/tmp/bc-user")
    ap.add_argument("--level", default="fake_flat")
    args = ap.parse_args()
    os.makedirs(args.userpath, exist_ok=True)

    results = []

    def check(name, ok, detail=""):
        results.append((name, ok))
        print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail else ""))

    p = Peer(args.port)
    print("connected")
    p.send({"t": "hello", "v": 1, "level": args.level, "userPath": args.userpath})
    t0 = time.time()
    while not (p.ready and p.atlas) and time.time() - t0 < 240:
        p.run(0.5)
    check("world ready", p.ready, f"{time.time() - t0:.1f}s")
    check("atlas announced", p.atlas is not None, json.dumps(p.atlas))
    if p.atlas:
        pages = [os.path.join(args.userpath, "beamcraft", "atlas", f"{p.atlas['hash']}_{i}.png") for i in range(p.atlas["pages"])]
        check("atlas pages on disk", all(os.path.exists(x) for x in pages), ", ".join(os.path.basename(x) for x in pages))
    if not p.ready:
        sys.exit(1)

    # enter on the fake ground, facing +X (MC yaw -90)
    p.send({"t": "enter", "x": 0.5, "y": GROUND + 0.05, "z": 0.5, "yaw": -90})
    p.sampled.clear()
    p.active = True
    p.pose = dict(p.pose or {}, x=0.5, y=GROUND + 0.05, z=0.5)
    look = {"yaw": -90.0, "pitch": 0.0}
    idle = dict(f=0, b=0, l=0, r=0, j=0, s=0, sp=0, at=0, us=0, **look)
    p.run(2.0, dict(idle))
    y = p.pose and p.pose["y"]
    check("standing on BeamNG ground", p.pose and abs(y - GROUND) < 0.05 and p.pose["g"] == 1, f"y={y} g={p.pose and p.pose['g']}")

    # walk +X for 1 s
    x0 = p.pose["x"]
    p.run(1.0, dict(idle, f=1))
    p.run(0.5, dict(idle))
    dx = p.pose["x"] - x0
    check("walks forward", 2.5 < dx < 6.0, f"dx={dx:.2f} m/s-ish, y={p.pose['y']:.3f}")
    check("stays on ground while walking", abs(p.pose["y"] - GROUND) < 0.05, f"y={p.pose['y']:.3f}")

    # walk into the 1 m kerb: must stop before x = KERB_X - 0.3
    p.run(2.5, dict(idle, f=1))
    xk = p.pose["x"]
    check("kerb blocks walking", xk < KERB_X - 0.25, f"x={xk:.3f} (kerb at {KERB_X})")

    # jump onto it
    p.run(1.2, dict(idle, f=1, j=1))
    p.run(0.6, dict(idle))
    check("jumps up the kerb", p.pose["x"] > KERB_X and abs(p.pose["y"] - (GROUND + 1)) < 0.05,
          f"x={p.pose['x']:.2f} y={p.pose['y']:.3f}")

    # place a block on the ground ahead: look 55 degrees down, aim from our "raycast"
    base_y = p.pose["y"]
    pitch = 55.0
    eye = (p.pose["x"], base_y + p.pose["eye"], p.pose["z"])
    yaw = math.radians(-90)
    d = (-math.sin(yaw) * math.cos(math.radians(pitch)), -math.sin(math.radians(pitch)), math.cos(yaw) * math.cos(math.radians(pitch)))
    tdist = (eye[1] - base_y) / -d[1]
    hit = (eye[0] + d[0] * tdist, base_y, eye[2] + d[2] * tdist)
    aim = {"x": hit[0], "y": hit[1], "z": hit[2], "nx": 0, "ny": 1, "nz": 0, "d": tdist}
    cell = (math.floor(hit[0]), math.floor(base_y + 0.05), math.floor(hit[2]))
    before = dict(p.blocks)
    inp = dict(idle, pitch=pitch, aim=aim, us=1, ev=[{"k": "use"}])
    p.run(0.15, inp)
    p.run(1.0, dict(idle, pitch=pitch, aim=aim))
    placed = p.blocks.get(cell)
    check("block placed on the ground", placed not in (None, 0), f"cell={cell} id={placed}")
    if placed:
        st = p.states.get(placed)
        check("block state defined with quads", st is not None and len(st.get("q", [])) >= 24,
              st and f"{st.get('n')} quads={len(st['q']) // 24} ground={st.get('g')}")

    # break it (creative: one click)
    p.run(0.15, dict(idle, pitch=pitch, aim=aim, at=1, ev=[{"k": "attack"}]))
    p.run(1.0, dict(idle, pitch=pitch, aim=aim))
    check("block broken", p.blocks.get(cell) == 0, f"id={p.blocks.get(cell)}")

    p.send({"t": "exit"})
    p.run(0.3)
    fails = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(fails)}/{len(results)} passed")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

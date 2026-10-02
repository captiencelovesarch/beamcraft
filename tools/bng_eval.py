#!/usr/bin/env python3
"""Run Lua inside a running BeamNG (BeamCraft dev console, port 47801).

Needs the flag file <userfolder>/beamcraft/dev_eval (tools/deploy.sh --dev creates it).

    tools/bng_eval.py 'return beamcraft_main.world.getTotalBlocks()'
    echo 'return be:getPlayerVehicleID(0)' | tools/bng_eval.py -
"""
import json
import socket
import sys


def main():
    code = sys.argv[1] if len(sys.argv) > 1 else "-"
    if code == "-":
        code = sys.stdin.read()
    with socket.create_connection(("127.0.0.1", 47801), timeout=10) as s:
        s.sendall((json.dumps({"code": code}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
    reply = json.loads(buf.split(b"\n", 1)[0])
    print(reply.get("result", ""))
    sys.exit(0 if reply.get("ok") else 1)


if __name__ == "__main__":
    main()

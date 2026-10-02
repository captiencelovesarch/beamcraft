#!/usr/bin/env python3
"""Connect to the hidden Minecraft's overlay WebSocket the way BeamNG's UI does,
assemble the streamed GUI frames and save the result as a PNG (over a checkerboard,
so transparency is visible).

    tools/overlay_probe.py --seconds 3 --out /tmp/overlay.png
"""
import argparse
import base64
import os
import socket
import struct
import time

from PIL import Image


def ws_connect(port):
    s = socket.create_connection(("127.0.0.1", port), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(4096)
    head, rest = buf.split(b"\r\n\r\n", 1)
    assert b" 101 " in head.split(b"\r\n")[0], head
    return s, rest


def ws_send_text(s, text):
    data = text.encode()
    mask = os.urandom(4)
    hdr = bytes([0x81])
    n = len(data)
    hdr += bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n)
    s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))


def read_exact(s, n, buf):
    while len(buf) < n:
        chunk = s.recv(1 << 20)
        if not chunk:
            raise EOFError
        buf += chunk
    return buf[:n], buf[n:]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=47802)
    ap.add_argument("--seconds", type=float, default=3)
    ap.add_argument("--out", default="overlay.png")
    a = ap.parse_args()
    s, buf = ws_connect(a.port)
    s.settimeout(10)
    img = None
    frames = 0
    pixels = 0
    end = time.time() + a.seconds
    while time.time() < end:
        hdr, buf = read_exact(s, 2, buf)
        n = hdr[1] & 0x7F
        if n == 126:
            ext, buf = read_exact(s, 2, buf)
            n = struct.unpack(">H", ext)[0]
        elif n == 127:
            ext, buf = read_exact(s, 8, buf)
            n = struct.unpack(">Q", ext)[0]
        payload, buf = read_exact(s, n, buf)
        if hdr[0] & 0x0F != 2 or payload[:4] != b"BCF1":
            continue
        fw, fh, x, y, w, h, fid = struct.unpack("<HHHHHHI", payload[4:20])
        if img is None or img.size != (fw, fh):
            img = Image.new("RGBA", (fw, fh), (0, 0, 0, 0))
        patch = Image.frombytes("RGBA", (w, h), payload[20:20 + w * h * 4])
        img.paste(patch, (x, y))
        frames += 1
        pixels += w * h
    s.close()
    if img is None:
        print("no frames received")
        return 1
    # composite over a checkerboard so transparent areas are obvious
    bg = Image.new("RGBA", img.size, (90, 90, 90, 255))
    px = bg.load()
    for yy in range(0, img.size[1], 16):
        for xx in range(0, img.size[0], 16):
            if (xx // 16 + yy // 16) % 2:
                for j in range(min(16, img.size[1] - yy)):
                    for i in range(min(16, img.size[0] - xx)):
                        px[xx + i, yy + j] = (140, 140, 140, 255)
    Image.alpha_composite(bg, img).save(a.out)
    opaque = sum(1 for p in img.getdata() if p[3] > 0)
    print(f"{frames} frames, {pixels / max(1, frames):.0f} px/frame avg, {img.size[0]}x{img.size[1]}, "
          f"{100 * opaque / (img.size[0] * img.size[1]):.1f}% non-transparent -> {a.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

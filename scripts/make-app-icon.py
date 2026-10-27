#!/usr/bin/env python3
"""Draws the app icon (white speech bubble on a green squircle) and builds packaging/icon.icns.

Writes packaging/icon.png (1024 px) and, where `sips` and `iconutil` exist (macOS),
packaging/icon.icns. Standard library only.
"""
import pathlib
import shutil
import struct
import subprocess
import tempfile
import zlib

PACKAGING = pathlib.Path(__file__).resolve().parent.parent / "packaging"
SIZE = 1024
TOP, BOTTOM = (52, 183, 96), (13, 128, 75)  # green gradient, top to bottom


def in_triangle(p, a, b, c):
    def cross(o, q):
        return (q[0] - o[0]) * (p[1] - o[1]) - (q[1] - o[1]) * (p[0] - o[0])

    d1, d2, d3 = cross(a, b), cross(b, c), cross(c, a)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


def bubble(x, y):
    # Same bubble as the menu bar icon, in a 16-unit grid.
    nx, ny = min(max(x, 4), 12), min(max(y, 5), 8)
    body = (x - nx) ** 2 + (y - ny) ** 2 <= 9
    tail = in_triangle((x, y), (4, 10), (4, 14), (8, 10))
    dot = any((x - dx) ** 2 + (y - 6.5) ** 2 <= 1.0 for dx in (5, 8, 11))
    return (body or tail) and not dot


def squircle(px, py):
    # Apple-style icon body: 824 px wide, centred in the 1024 px canvas.
    half = 412
    return abs((px - 512) / half) ** 5 + abs((py - 512) / half) ** 5 <= 1


def pixel(px, py):
    """Returns (r, g, b, a) at 2x2 supersampling."""
    cover = white = 0
    for sy in range(2):
        for sx in range(2):
            x, y = px + (sx + 0.5) / 2, py + (sy + 0.5) / 2
            if squircle(x, y):
                cover += 1
                gx, gy = (x - 512) / 35 + 8, (y - 512) / 35 + 8.4  # 35 px per grid unit
                if 1 <= gx <= 15 and 2 <= gy <= 14 and bubble(gx, gy):
                    white += 1
    if not cover:
        return (0, 0, 0, 0)
    t = py / SIZE
    bg = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]
    mix = white / cover
    rgb = [round(bg[i] * (1 - mix) + 255 * mix) for i in range(3)]
    return (*rgb, round(cover / 4 * 255))


def png(size):
    rows = []
    for py in range(size):
        row = bytearray(b"\x00")
        for px in range(size):
            row += bytes(pixel(px, py))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def build_icns(source):
    if not (shutil.which("sips") and shutil.which("iconutil")):
        print("sips/iconutil not found: skipped icon.icns")
        return
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "icon.iconset"
        iconset.mkdir()
        for base in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(["sips", "-z", str(base * scale), str(base * scale), str(source),
                                "--out", str(iconset / name)], check=True, capture_output=True)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(PACKAGING / "icon.icns")], check=True)


if __name__ == "__main__":
    PACKAGING.mkdir(exist_ok=True)
    out = PACKAGING / "icon.png"
    out.write_bytes(png(SIZE))
    build_icns(out)
    print("wrote", out, "and icon.icns")

#!/usr/bin/env python3
"""Draws the menu bar icon (a speech bubble with three dots) as template PNGs.

Writes assets/trayTemplate.png (16 px) and assets/trayTemplate@2x.png (32 px). macOS tints
template images itself, so only the alpha channel matters. Standard library only.
"""
import pathlib
import struct
import zlib

ASSETS = pathlib.Path(__file__).resolve().parent.parent / "assets"


def in_triangle(p, a, b, c):
    def cross(o, q):
        return (q[0] - o[0]) * (p[1] - o[1]) - (q[1] - o[1]) * (p[0] - o[0])

    d1, d2, d3 = cross(a, b), cross(b, c), cross(c, a)
    has_neg = d1 < 0 or d2 < 0 or d3 < 0
    has_pos = d1 > 0 or d2 > 0 or d3 > 0
    return not (has_neg and has_pos)


def shape(x, y):
    # Bubble: points within radius 3 of the inner rectangle x 4..12, y 5..8.
    nx, ny = min(max(x, 4), 12), min(max(y, 5), 8)
    body = (x - nx) ** 2 + (y - ny) ** 2 <= 9
    tail = in_triangle((x, y), (4, 10), (4, 14), (8, 10))
    dot = any((x - dx) ** 2 + (y - 6.5) ** 2 <= 1.0 for dx in (5, 8, 11))
    return (body or tail) and not dot


def alpha(size, px, py):
    # 4x4 supersampling for smooth edges. Coordinates are in a 16-unit grid.
    hits = 0
    for sy in range(4):
        for sx in range(4):
            x = (px + (sx + 0.5) / 4) * 16 / size
            y = (py + (sy + 0.5) / 4) * 16 / size
            hits += shape(x, y)
    return round(hits / 16 * 255)


def png(size):
    rows = []
    for py in range(size):
        row = bytearray(b"\x00")  # filter type 0
        for px in range(size):
            row += bytes((0, 0, 0, alpha(size, px, py)))
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(b"".join(rows), 9))
        + chunk(b"IEND", b"")
    )


if __name__ == "__main__":
    ASSETS.mkdir(exist_ok=True)
    (ASSETS / "trayTemplate.png").write_bytes(png(16))
    (ASSETS / "trayTemplate@2x.png").write_bytes(png(32))
    print("wrote", ASSETS / "trayTemplate.png", "and trayTemplate@2x.png")

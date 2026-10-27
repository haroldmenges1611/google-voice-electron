#!/usr/bin/env python3
"""Builds windows/Timbre.ico from packaging/icon.png (PNG-compressed entries, 16 to 256 px).

Needs macOS `sips` to resize. Standard library otherwise.
"""
import pathlib
import struct
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIZES = (16, 24, 32, 48, 64, 128, 256)

with tempfile.TemporaryDirectory() as tmp:
    images = []
    for size in SIZES:
        out = pathlib.Path(tmp) / f"{size}.png"
        subprocess.run(["sips", "-z", str(size), str(size), str(ROOT / "packaging/icon.png"), "--out", str(out)],
                       check=True, capture_output=True)
        images.append((size, out.read_bytes()))

header = struct.pack("<HHH", 0, 1, len(images))
offset = 6 + 16 * len(images)
entries, data = b"", b""
for size, png in images:
    dim = 0 if size >= 256 else size
    entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(png), offset + len(data))
    data += png
(ROOT / "windows/Timbre.ico").write_bytes(header + entries + data)
print("wrote windows/Timbre.ico")

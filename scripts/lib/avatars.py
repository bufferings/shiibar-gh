"""Avatars of made-up users: a 5 by 5 symmetric pattern of one color on a
light ground, so they read as avatars in the sandbox's screens (a plain
square of one color does not). PNG files written without third-party
modules."""

import struct
import zlib


def avatar(path, rgb, seed):
    """A 5 by 5 symmetric pattern on a light ground, 70 by 70 pixels."""
    size, cell, margin = 70, 10, 10
    bits = [(seed * 2654435761 >> k) & 1 for k in range(15)]
    on = [[False] * 5 for _ in range(5)]
    for row in range(5):
        for col in range(3):
            on[row][col] = on[row][4 - col] = bits[row * 3 + col] == 1
    ground = (240, 240, 240)
    raw = b""
    for y in range(size):
        line = b"\x00"
        for x in range(size):
            cx, cy = (x - margin) // cell, (y - margin) // cell
            inside = 0 <= cx < 5 and 0 <= cy < 5 and x >= margin and y >= margin
            line += bytes(rgb if inside and on[cy][cx] else ground)
        raw += line

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

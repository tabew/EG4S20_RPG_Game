# -*- coding: utf-8 -*-
"""Render the solid full-screen splash dumps into PNG frames.

tb_splash_shots stops while the block still covers all 1200 cells, so these
pictures show the colours and the centred sentence the blocking screen is
supposed to produce. tb_feature_shots only dumps after the splash collapsed
into one status line.
"""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "preview" / "sim_features"
FONT = ROOT / "rtl" / "gen" / "font.hex"
CELLS = OUT / "splash_cells.txt"

PALETTE = [
    0x0000, 0x18E3, 0x4208, 0x7BEF, 0xFFFF, 0xF800, 0x8000, 0xFD20,
    0xFFE0, 0x07E0, 0x03E0, 0x07FF, 0x001F, 0x781F, 0xF81F, 0xC618,
]

# Order must match the dump sequence in tb_splash_shots.
NAMES = [
    "27_splash_l1_dying",
    "28_splash_l1_typing",
    "29_splash_l3_shop",
    "30_splash_l2_battle",
    "31_splash_l1_emergency",
]


def rgb565(value):
    r = ((value >> 11) & 0x1F) * 255 // 31
    g = ((value >> 5) & 0x3F) * 255 // 63
    b = (value & 0x1F) * 255 // 31
    return bytes((r, g, b))


def write_png(path, raw, width, height):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 6))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def render():
    rows = [int(line, 16) for line in FONT.read_text().split()]
    shots = []
    current = None
    for line in CELLS.read_text().splitlines():
        if line.startswith("SPLASH "):
            current = []
            shots.append(current)
        elif current is not None and line:
            current.append(int(line, 16))
    if len(shots) != len(NAMES):
        raise SystemExit("expected %d splash shots, got %d" % (len(NAMES), len(shots)))
    colors = [rgb565(c) for c in PALETTE]
    for name, cells in zip(NAMES, shots):
        if len(cells) != 1200:
            raise SystemExit("%s has %d cells" % (name, len(cells)))
        raw = bytearray()
        for y in range(480):
            raw.append(0)
            cy, ry = divmod(y, 16)
            for x in range(640):
                cx, rx = divmod(x, 16)
                word = cells[cy * 40 + cx]
                glyph = word & 0x1FF
                fg = (word >> 9) & 0xF
                bg = (word >> 13) & 0xF
                bits = rows[glyph * 16 + ry] if glyph * 16 + ry < len(rows) else 0
                on = (bits >> (15 - rx)) & 1
                raw += colors[fg if on else bg]
        dest = OUT / (name + ".png")
        write_png(dest, bytes(raw), 640, 480)
        print(dest)


if __name__ == "__main__":
    render()
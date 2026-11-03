# -*- coding: utf-8 -*-
"""Render the typewriter reveal captured by tb_typing_shots.

The bench parks on R_TYPE_WAIT with exactly 1, 2 and 3 glyphs written and then
on R_TYPE_HOLD for the finished sentence, so the four frames show the splash
block growing its text one character at a time.

Each frame is also scaled into a single strip (typing_sequence.png) so the
progression is readable at a glance.
"""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "preview" / "sim_features"
FONT = ROOT / "rtl" / "gen" / "font.hex"
CELLS = OUT / "typing_cells.txt"

PALETTE = [
    0x0000, 0x18E3, 0x4208, 0x7BEF, 0xFFFF, 0xF800, 0x8000, 0xFD20,
    0xFFE0, 0x07E0, 0x03E0, 0x07FF, 0x001F, 0x781F, 0xF81F, 0xC618,
]

# Order must match the dump sequence in tb_typing_shots.
NAMES = [
    "32_typing_1_of_4",
    "33_typing_2_of_4",
    "34_typing_3_of_4",
    "35_typing_4_of_4",
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


def load_shots():
    rows = [int(line, 16) for line in FONT.read_text().split()]
    shots = []
    current = None
    meta = []
    for line in CELLS.read_text().splitlines():
        if line.startswith("TYPER "):
            if current is not None:
                meta.append(current_meta)
            parts = line.split()
            current_meta = (int(parts[2]), int(parts[3]))
            current = []
            shots.append(current)
        elif current is not None and line:
            current.append(int(line, 16))
    if current is not None:
        meta.append(current_meta)
    return rows, shots, meta


def render_frame(rows, cells):
    colors = [rgb565(c) for c in PALETTE]
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
    return bytes(raw), 640, 480


def render():
    rows, shots, meta = load_shots()
    if len(shots) != len(NAMES):
        raise SystemExit("expected %d typing shots, got %d" % (len(NAMES), len(shots)))
    for name, cells, (got, total) in zip(NAMES, shots, meta):
        if len(cells) != 1200:
            raise SystemExit("%s has %d cells" % (name, len(cells)))
        raw, w, h = render_frame(rows, cells)
        dest = OUT / (name + ".png")
        write_png(dest, raw, w, h)
        print("%s  typed %d/%d" % (dest, got, total))

    # Contact strip: four frames side by side, scaled to a quarter.
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        return
    tiles = [Image.open(OUT / (n + ".png")).convert("RGB").resize((320, 240), Image.NEAREST)
             for n in NAMES]
    pad, label = 6, 22
    width = len(tiles) * (320 + pad) + pad
    strip = Image.new("RGB", (width, 240 + pad * 2 + label), (24, 24, 28))
    draw = ImageDraw.Draw(strip)
    for i, tile in enumerate(tiles):
        x = pad + i * (320 + pad)
        strip.paste(tile, (x, pad))
        draw.rectangle([x - 1, pad - 1, x + 320, pad + 240], outline=(90, 90, 100))
        draw.text((x + 4, pad + 244), "%d/4 chars" % (i + 1), fill=(235, 235, 120))
    dest = OUT / "typing_sequence.png"
    strip.save(dest)
    print(dest)


if __name__ == "__main__":
    render()

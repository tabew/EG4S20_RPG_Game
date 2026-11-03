# -*- coding: utf-8 -*-
"""Turn feature-shot simulation dumps into PNG frames."""
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "preview" / "sim_features"
FONT = ROOT / "rtl" / "gen" / "font.hex"
CELLS = OUT / "cells.txt"
RAW = OUT / "video_raw.bin"

PALETTE = [
    0x0000, 0x18E3, 0x4208, 0x7BEF, 0xFFFF, 0xF800, 0x8000, 0xFD20,
    0xFFE0, 0x07E0, 0x03E0, 0x07FF, 0x001F, 0x781F, 0xF81F, 0xC618,
]
NAMES = [
    "01_title",
    "02_class",
    "03_map_base",
    "04_cave_ok_l2",
    "05_l1_dying",
    "06_cave_hurt_remain",
    "07_cave_hurt_cleared",
    "08_shop_l3",
    "09_shop_l1_boss",
    "10_shop_l3_back",
    "11_battle_l2",
    "12_battle_l1_boss",
    "13_emergency",
    "14_emergency_back",
]
VIDEO_NAMES = [
    "15_spectrum_monster",
    "16_spectrum_mute",
    "17_monster_rotate",
    "18_monster_mirror",
    "19_pitch_bars",
    "20_gallery_osd",
    "21_brightness_dark",
    "22_contrast_high",
    "23_zoom",
    "24_fade",
    "25_settings_osd",
    "26_alert_bar",
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


def render_cells():
    rows = [int(line, 16) for line in FONT.read_text().split()]
    shots = []
    current = None
    for line in CELLS.read_text().splitlines():
        if line.startswith("SHOT "):
            current = []
            shots.append(current)
        elif current is not None and line:
            current.append(int(line, 16))
    if len(shots) != len(NAMES):
        raise SystemExit("expected %d cell shots, got %d" % (len(NAMES), len(shots)))
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


def render_video():
    data = RAW.read_bytes()
    frame = 640 * 480 * 3
    count, extra = divmod(len(data), frame)
    if extra or count != len(VIDEO_NAMES):
        raise SystemExit("video bytes %d frames %d" % (len(data), count))
    for i, name in enumerate(VIDEO_NAMES):
        blob = data[i * frame:(i + 1) * frame]
        raw = bytearray()
        for y in range(480):
            raw.append(0)
            raw += blob[y * 640 * 3:(y + 1) * 640 * 3]
        dest = OUT / (name + ".png")
        write_png(dest, bytes(raw), 640, 480)
        print(dest)


if __name__ == "__main__":
    render_cells()
    if RAW.exists():
        render_video()

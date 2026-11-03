# -*- coding: utf-8 -*-
"""Slice the hex dump from tb_hitfx_shots into PNG frames.

The bench writes one "rrggbb" line per visible pixel. Thirteen frames are
captured: one idle reference, then four frames each for the normal attack,
the skill and the monster counterattack, so the sparks can be followed frame
by frame.
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "preview" / "sim_features"
HEX = OUT / "hitfx_raw.bin"

W, H = 640, 480

NAMES = ["40_hitfx_idle"] + \
        ["4%d_hitfx_attack_%d" % (i, i) for i in range(1, 5)] + \
        ["4%d_hitfx_skill_%d" % (i, i) for i in range(5, 9)] + \
        ["5%d_hitfx_counter_%d" % (i - 9, i - 9) for i in range(9, 13)]


def main():
    lines = [ln for ln in HEX.read_text().splitlines() if ln]
    total = W * H
    if len(lines) % total:
        raise SystemExit("pixel count %d not a multiple of %d" % (len(lines), total))
    frames = len(lines) // total
    print("frames", frames)
    for f in range(frames):
        chunk = lines[f * total:(f + 1) * total]
        data = bytes.fromhex("".join(chunk))
        img = Image.frombytes("RGB", (W, H), data)
        name = NAMES[f] if f < len(NAMES) else "99_hitfx_%d" % f
        img.save(OUT / (name + ".png"))
        print(name)


if __name__ == "__main__":
    main()

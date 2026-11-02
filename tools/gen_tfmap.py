#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_tfmap.py —— 生成 TF 卡 BMP -> 16 色调色板 的最近色映射 ROM

调色板与 rpg_video.v 中 gal_layer.ppal / anim_rom.pal_tbl 完全一致 (16 色 RGB565)。
映射规则: 取 RGB888 各通道高 4 位组成 12 位地址 (R[7:4],G[7:4],B[7:4]),
ROM 输出最近调色板色的索引, 4096 项 x 4bit。

输出: rtl/gen/tf_map.hex (每行一个 16 进制位, 供 $readmemh)
"""
import os

# gal_layer.ppal 的 16 个 RGB565 值 (顺序即索引)
PAL565 = [
    0x0000, 0x0841, 0x10A2, 0x18E3, 0x3186, 0x4208, 0x8000, 0xC000,
    0xE800, 0xFD20, 0xFE60, 0xFFE0, 0xFFFF, 0x7BEF, 0x39E7, 0x0220,
]


def rgb565_to_rgb888(c):
    r = ((c >> 11) & 0x1F)
    g = ((c >> 5) & 0x3F)
    b = (c & 0x1F)
    R = (r << 3) | (r >> 2)
    G = (g << 2) | (g >> 4)
    B = (b << 3) | (b >> 2)
    return (R, G, B)


PAL888 = [rgb565_to_rgb888(c) for c in PAL565]


def nearest(r8, g8, b8):
    """RGB888 -> 最近调色板索引 (平方距离)"""
    best, bd = 0, 1 << 30
    for i, (pr, pg, pb) in enumerate(PAL888):
        d = (r8 - pr) ** 2 + (g8 - pg) ** 2 + (b8 - pb) ** 2
        if d < bd:
            bd, best = d, i
    return best


def main():
    out = []
    for r4 in range(16):
        for g4 in range(16):
            for b4 in range(16):
                r8 = (r4 << 4) | (r4 >> 1)      # 4bit -> 8bit 近似展开
                g8 = (g4 << 4) | (g4 >> 1)
                b8 = (b4 << 4) | (b4 >> 1)
                out.append(nearest(r8, g8, b8))
    assert len(out) == 4096
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "rtl", "gen", "tf_map.hex")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join("%X" % v for v in out) + "\n")
    print("tf_map.hex written: %d entries" % len(out))
    # 打印调色板对照
    for i, c in enumerate(PAL565):
        print("  idx %X: 565=%04X 888=%s" % (i, c, PAL888[i]))


if __name__ == "__main__":
    main()

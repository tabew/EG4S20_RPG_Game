# -*- coding: utf-8 -*-
"""
make_anim.py —— 生成游戏内的动态插图（多帧 4bpp 位图 + 16 色调色板）

产物:
    rtl/gen/anim.hex      所有帧的像素，每行 1 字节（一个字节装 2 个像素）
    rtl/gen/anim_rom.v    BRAM 初始化 + 调色板表 + 参数

尺寸 128x96，4bpp，12 帧 —— 显示时 2 倍放大到 256x192（占屏幕中央）。
存储量 128*96/2 = 6144 字节/帧 × 12 = 73728 字节 ≈ 590 Kbit，EG4S20 放得下。

插图内容：夜里的营地篝火 —— 火焰跳动、火星上升、背景星光闪烁。
全部用数学画出来，不依赖任何图片素材和 PIL。
"""
import math, os

W, H = 128, 96
FRAMES = 4

# 16 色调色板（RGB565）
PALETTE = [
    0x0000,  # 0  黑
    0x0841,  # 1  深夜蓝
    0x10A2,  # 2  夜空蓝
    0x18E3,  # 3  远山蓝
    0x3186,  # 4  营地地面（暗棕）
    0x4208,  # 5  地面亮部
    0x8000,  # 6  暗红
    0xC000,  # 7  红
    0xE800,  # 8  橙红
    0xFD20,  # 9  橙
    0xFE60,  # 10 亮橙
    0xFFE0,  # 11 黄
    0xFFFF,  # 12 白
    0x7BEF,  # 13 灰（烟）
    0x39E7,  # 14 暗灰
    0x0220,  # 15 暗绿
]

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def dith(v, c0, c1, x, y):
    """v 在 [0,1] 之间：按 Bayer 抖动在两种颜色间选择"""
    t = (BAYER[y & 3][x & 3] + 0.5) / 16.0
    return c1 if v > t else c0


def noise(x, y, f):
    """确定性的伪随机，用来做纹理和火星"""
    n = (x * 374761393 + y * 668265263 + f * 2147483647) & 0xFFFFFFFF
    n = (n ^ (n >> 13)) * 1274126177 & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


def draw_frame(f):
    """画第 f 帧"""
    img = [[0] * W for _ in range(H)]
    ph = f / FRAMES * 2 * math.pi

    # ---- 夜空：上深下浅 ----
    for y in range(0, 62):
        v = y / 62.0
        for x in range(W):
            img[y][x] = dith(v * 0.85, 1, 2, x, y)

    # ---- 星星：闪烁 ----
    for i in range(26):
        sx = int(noise(i, 1, 7) * W)
        sy = int(noise(i, 2, 7) * 48)
        tw = 0.5 + 0.5 * math.sin(ph * 2 + i)
        if tw > 0.55:
            img[sy][sx % W] = 13 if tw < 0.8 else 12

    # ---- 月亮 ----
    mx, my, mr = 104, 18, 9
    for y in range(my - mr - 1, my + mr + 2):
        for x in range(mx - mr - 1, mx + mr + 2):
            if 0 <= x < W and 0 <= y < H:
                d = math.hypot(x - mx, y - my)
                if d < mr - 1.2:
                    img[y][x] = 12
                elif d < mr:
                    img[y][x] = dith(0.5, 2, 13, x, y)

    # ---- 远山 ----
    for x in range(W):
        hm = 10 * math.sin(x / 19.0 + 1.3) + 6 * math.sin(x / 7.0)
        top = int(54 - abs(hm) * 0.6)
        for y in range(top, 62):
            img[y][x] = 3 if y < top + 3 else 2

    # ---- 地面 ----
    for y in range(62, H):
        v = (y - 62) / (H - 62.0)
        for x in range(W):
            if noise(x, y, 3) > 0.93:
                img[y][x] = 5
            else:
                img[y][x] = dith(v * 0.8, 4, 5, x, y)

    # ---- 柴堆 ----
    for i in range(-14, 15):
        x = 64 + i
        y = 84 + int(abs(i) * 0.22)
        for t in range(3):
            if 0 <= x < W and 0 <= y - t < H:
                img[y - t][x] = 4 if i % 3 else 5

    # ---- 火焰：高度/宽度随帧摆动 ----
    for x in range(38, 90):
        dx = (x - 64) / 26.0
        # 火焰外轮廓
        h_f = (1 - dx * dx) * (22 + 4 * math.sin(ph + x * 0.55))
        if h_f <= 0:
            continue
        base_y = 82
        top_y = int(base_y - h_f)
        for y in range(max(0, top_y), base_y):
            t = (y - top_y) / max(1.0, base_y - top_y)
            # 内焰更亮
            core = abs(dx) < 0.42 * (1 - t * 0.5)
            n = noise(x, y, f >> 1)
            if t < 0.18:
                img[y][x] = 11 if core else 10          # 焰心黄
            elif t < 0.45:
                img[y][x] = (10 if core else 9) if n > 0.15 else 8
            elif t < 0.75:
                img[y][x] = 8 if n > 0.2 else 7
            else:
                img[y][x] = 7 if n > 0.35 else 6

    # ---- 火星：往上飘 ----
    for i in range(14):
        life = (f / FRAMES + noise(i, 5, 9)) % 1.0
        ex = int(64 + (noise(i, 6, 9) - 0.5) * 46 + math.sin(life * 6 + i) * 4)
        ey = int(80 - life * 62)
        if 0 <= ex < W and 0 <= ey < H:
            img[ey][ex] = 11 if life < 0.5 else 9
            if life < 0.3 and 0 <= ey - 1:
                img[ey - 1][ex] = 10

    # ---- 烟：越往上越散、越淡 ----
    for y in range(8, 56):
        t = (y - 8) / 48.0                     # 0=上 1=下
        half = 3 + t * 9                       # 上面的烟柱更宽
        for x in range(int(64 - half), int(64 + half)):
            if 0 <= x < W:
                thr = 0.86 - t * 0.22          # 越靠下越密
                if noise(x, y, f) > thr:
                    img[y][x] = 14

    return img


def pack(img):
    """4bpp 打包：两个像素塞一个字节（低半字节在前）"""
    out = []
    for y in range(H):
        for x in range(0, W, 2):
            out.append(((img[y][x] & 0xF) << 4) | (img[y][x + 1] & 0xF))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    gen = os.path.join(root, "rtl", "gen")
    os.makedirs(gen, exist_ok=True)

    data = []
    for f in range(FRAMES):
        data += pack(draw_frame(f))

    per_frame = W * H // 2
    assert len(data) == per_frame * FRAMES

    with open(os.path.join(gen, "anim.hex"), "w", encoding="ascii", newline="\n") as fp:
        for b in data:
            fp.write("%02x\n" % b)

    pal_init = "\n".join("        pal_tbl[%d] = 16'h%04X;" % (i, c)
                          for i, c in enumerate(PALETTE))

    v = """//=============================================================================
// anim_rom.v —— 动态插图数据（由 tools/make_anim.py 生成，不要手改）
//
//   {nf} 帧 x {w}x{h}，4bpp（每字节 2 像素，高半字节在前）
//   总计 {n} 字节 = {kb:.0f} Kbit
//=============================================================================
`timescale 1ns/1ps
module anim_rom (
    input  wire        clk,
    input  wire [{abits}:0] addr,      // 0 .. {last}
    output reg  [7:0]  data,
    input  wire [3:0]  pal_idx,
    output reg  [15:0] pal_rgb
);
    reg [7:0] mem [0:{last}];

    initial $readmemh("D:/EG4S20_RPG_Game-main/rtl/gen/anim.hex", mem);

    always @(posedge clk) data <= mem[addr];

    // 调色板：16 项，用寄存器实现（不进 BRAM）
    reg [15:0] pal_tbl [0:15];
    initial begin
{pal}
    end

    always @(posedge clk) pal_rgb <= pal_tbl[pal_idx];

endmodule
""".format(nf=FRAMES, w=W, h=H, n=len(data), kb=len(data) * 8 / 1024.0,
           last=len(data) - 1, abits=(len(data) - 1).bit_length() - 1, pal=pal_init)
    with open(os.path.join(gen, "anim_rom.v"), "w", encoding="utf-8", newline="\n") as fp:
        fp.write(v)

    print("动态插图生成完毕:")
    print("  尺寸 %dx%d，%d 帧，4bpp" % (W, H, FRAMES))
    print("  anim.hex %d 字节 (%.0f Kbit)" % (len(data), len(data) * 8 / 1024.0))
    print("  每帧 %d 字节；显示时 2 倍放大 -> %dx%d 像素" % (per_frame, W * 2, H * 2))


if __name__ == "__main__":
    main()

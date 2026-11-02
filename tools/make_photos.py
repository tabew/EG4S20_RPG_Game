# -*- coding: utf-8 -*-
"""
make_photos.py —— 相册（图片轮播）用的 4 张 128x96 4bpp 游戏主题海报

产物:
    rtl/gen/photo.hex      4 帧像素，每行 1 字节（高半字节 = 偶数像素）
    tools/out/photo_*.png  预览图（4 倍放大），仅用于肉眼检查

四张图全部取材于游戏本体内容，与游戏画风一致：
    1. camp  —— 营地篝火·启程之夜（与游戏标题插图同款场景）
    2. slime —— 史莱姆之森（游戏最初的敌人）
    3. boss  —— 熔岩魔王 BOSS 战（火山关卡头目）
    4. hero  —— 勇者与落日（冒险终点的剪影）

调色板与 anim_rom.v / rpg_video.v 的 pal() 完全一致，直接复用现有显示通路。
全部用数学画出来，不依赖任何图片素材和 PIL。
"""
import math, os, zlib, struct

W, H = 128, 96
FRAMES = 4

# 与 anim_rom.v 的 pal_tbl / rpg_video.v 的 pal() 相同
PALETTE = [
    0x0000,  # 0  黑
    0x0841,  # 1  深夜蓝
    0x10A2,  # 2  夜空蓝
    0x18E3,  # 3  远山蓝
    0x3186,  # 4  暗棕
    0x4208,  # 5  亮棕
    0x8000,  # 6  暗红
    0xC000,  # 7  红
    0xE800,  # 8  橙红
    0xFD20,  # 9  橙
    0xFE60,  # 10 亮橙
    0xFFE0,  # 11 黄
    0xFFFF,  # 12 白
    0x7BEF,  # 13 浅灰
    0x39E7,  # 14 中灰
    0x0220,  # 15 暗绿
]

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def dith(v, c0, c1, x, y):
    """v in [0,1]: Bayer 抖动在两色之间过渡"""
    t = (BAYER[y & 3][x & 3] + 0.5) / 16.0
    return c1 if v > t else c0


def clamp(v, a, b):
    return a if v < a else (b if v > b else v)


def noise(x, y, f):
    n = (x * 374761393 + y * 668265263 + f * 2147483647) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0


def lerp_stops(t, stops):
    """stops = [(pos0, c0), (pos1, c1), ...] pos 升序, 返回 (c0, c1, frac)"""
    for i in range(len(stops) - 1):
        p0, c0 = stops[i]
        p1, c1 = stops[i + 1]
        if t <= p1 or i == len(stops) - 2:
            f = (t - p0) / max(1e-6, (p1 - p0))
            return c0, c1, clamp(f, 0.0, 1.0)
    return stops[-1][1], stops[-1][1], 0.0


def vgrad(img, y0, y1, stops, xrange=(0, W)):
    for y in range(y0, y1):
        t = (y - y0) / max(1e-6, (y1 - 1 - y0))
        c0, c1, f = lerp_stops(t, stops)
        for x in range(*xrange):
            img[y][x] = dith(f, c0, c1, x, y)


def disc(img, cx, cy, r, c, soft=None):
    for y in range(int(cy - r) - 1, int(cy + r) + 2):
        for x in range(int(cx - r) - 1, int(cx + r) + 2):
            if 0 <= x < W and 0 <= y < H:
                d = math.hypot(x - cx, y - cy)
                if d <= r:
                    img[y][x] = c
                elif soft is not None and d <= r + soft:
                    img[y][x] = dith(1.0 - (d - r) / soft, c, img[y][x], x, y)


def tri(img, p0, p1, p2, c):
    """实心三角形"""
    def s(a, b, p):
        return (b[0]-a[0])*(p[1]-a[1]) - (b[1]-a[1])*(p[0]-a[0])
    xs = [p0[0], p1[0], p2[0]]
    ys = [p0[1], p1[1], p2[1]]
    for y in range(max(0, min(ys)), min(H, max(ys)+1)):
        for x in range(max(0, min(xs)), min(W, max(xs)+1)):
            d1 = s(p0, p1, (x, y))
            d2 = s(p1, p2, (x, y))
            d3 = s(p2, p0, (x, y))
            if not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0)):
                img[y][x] = c


def line(img, x0, y0, x1, y1, c, w=1):
    n = max(abs(x1-x0), abs(y1-y0), 1)
    for i in range(n + 1):
        t = i / n
        x = int(x0 + (x1-x0)*t)
        y = int(y0 + (y1-y0)*t)
        for dy in range(w):
            for dx in range(w):
                if 0 <= x+dx < W and 0 <= y+dy < H:
                    img[y+dy][x+dx] = c


def ellipse(img, cx, cy, rx, ry, c, ymax=None):
    """实心椭圆; ymax: 只画 y<=ymax 的部分(裁剪)"""
    for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
        if ymax is not None and y > ymax:
            continue
        if y < 0 or y >= H:
            continue
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            if x < 0 or x >= W:
                continue
            dx = (x - cx) / rx
            dy = (y - cy) / ry
            if dx*dx + dy*dy <= 1.0:
                img[y][x] = c


# ----------------------------------------------------------------------------
# 1) 营地篝火·启程之夜 —— 与游戏标题插图同款场景
# ----------------------------------------------------------------------------
def scene_camp():
    img = [[0] * W for _ in range(H)]

    # 夜空
    vgrad(img, 0, 62, [(0.0, 1), (1.0, 2)])
    # 星星
    for i in range(26):
        sx = int(noise(i, 1, 7) * W)
        sy = int(noise(i, 2, 7) * 48)
        if noise(i, 3, 7) > 0.35:
            img[sy][sx % W] = 13 if noise(i, 4, 7) > 0.7 else 12
    # 月亮(实心 + 一圈灰边)
    disc(img, 104, 18, 8, 12)
    for a in range(0, 360, 6):
        mx = int(104 + 8.6 * math.cos(math.radians(a)))
        my = int(18 + 8.6 * math.sin(math.radians(a)))
        if 0 <= mx < W and 0 <= my < H:
            img[my][mx] = 13

    # 远山
    for x in range(W):
        hm = 10 * math.sin(x / 19.0 + 1.3) + 6 * math.sin(x / 7.0)
        top = int(54 - abs(hm) * 0.6)
        for y in range(top, 62):
            img[y][x] = 3

    # 地面
    vgrad(img, 62, H, [(0.0, 4), (1.0, 5)])
    for i in range(60):
        gx = int(noise(i, 5, 11) * W)
        gy = 62 + int(noise(i, 6, 11) * 33)
        if noise(i, 7, 11) > 0.9:
            img[gy][gx] = 5

    # 帐篷(左) —— 冒险者营地
    tri(img, (8, 90), (40, 90), (24, 56), 4)
    tri(img, (18, 90), (30, 90), (24, 70), 0)     # 帐篷门口阴影
    line(img, 8, 90, 24, 56, 5)
    line(img, 40, 90, 24, 56, 5)
    line(img, 8, 90, 40, 90, 5)
    img[55][24] = 5                                # 帐篷顶

    # 柴堆
    for i in range(-14, 15):
        x = 74 + i
        y = 84 + int(abs(i) * 0.22)
        for t in range(3):
            if 0 <= x < W and 0 <= y - t < H:
                img[y - t][x] = 4 if i % 3 else 5

    # 火焰(窄而跳动)
    for x in range(62, 87):
        dx = (x - 74) / 12.0
        h_f = (1 - dx * dx) * 15
        if h_f <= 0:
            continue
        base_y = 82
        top_y = int(base_y - h_f)
        for y in range(max(0, top_y), base_y):
            t = (y - top_y) / max(1.0, base_y - top_y)
            cx = abs(x - 74) / 12.0
            if t < 0.30:
                img[y][x] = 11            # 焰心黄
            elif t < 0.60:
                img[y][x] = 10 if cx < 0.6 else 9
            elif t < 0.85:
                img[y][x] = 9 if cx < 0.7 else 8
            else:
                img[y][x] = 8
    # 火星(从火焰上方飘起)
    for i in range(10):
        sx = 74 + int((noise(i, 8, 11) - 0.5) * 22)
        sy = 60 + int(noise(i, 9, 11) * 18)
        if noise(i, 10, 11) > 0.4:
            img[sy][sx] = 9 if sy > 68 else 11

    return img


# ----------------------------------------------------------------------------
# 2) 史莱姆之森 —— 游戏最初的敌人
# ----------------------------------------------------------------------------
def slime(img, cx, cy, rx, ry, king=False):
    """半圆形史莱姆: 身体暗绿, 顶部高光, 黄色眼睛; king=True 加王冠"""
    ellipse(img, cx, cy, rx, ry, 15)
    # 轮廓压黑(底部一圈用黑描边感觉太重, 只压左右下角)
    for y in range(int(cy), int(cy + ry) + 1):
        for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
            if 0 <= x < W and 0 <= y < H:
                dx = (x - cx) / rx
                dy = (y - cy) / ry
                if dx*dx + dy*dy <= 1.0 and dx*dx + dy*dy > 0.78 and y > cy:
                    img[y][x] = 0
    # 顶部高光(小, 只留一点月光反光)
    ellipse(img, cx - rx * 0.4, cy - ry * 0.5, rx * 0.18, ry * 0.13, 3)
    # 眼睛
    ey = int(cy - ry * 0.15)
    ex = int(rx * 0.32)
    for sx in (int(cx - ex), int(cx + ex)):
        for h in range(4):
            img[ey - h][sx] = 11
        img[ey][sx - 0] = 11
        if king:
            img[ey - 4][sx] = 12          # 眼神高光
    # 嘴
    my = int(cy + ry * 0.25)
    for x in range(int(cx - 3), int(cx + 4)):
        img[my][x] = 0
    # 王冠
    if king:
        ky = int(cy - ry) - 1
        for x in range(int(cx - 8), int(cx + 9)):
            img[ky][x] = 11
        for tx in (int(cx - 7), int(cx), int(cx + 7)):
            for h in range(1, 5):
                img[ky - h][tx] = 11
        img[ky - 5][cx] = 12


def scene_slime():
    img = [[0] * W for _ in range(H)]

    # 暮色森林天空
    vgrad(img, 0, 56, [(0.0, 1), (0.55, 2), (1.0, 15)])
    # 树木剪影
    trees = [(10, 46, 12), (34, 52, 9), (92, 48, 11), (116, 54, 8), (64, 42, 7)]
    for tx, base, tw in trees:
        for y in range(base, 58):
            for x in range(tx - tw // 3, tx + tw // 3 + 1):
                if 0 <= x < W:
                    img[y][x] = 0
        # 树冠
        disc(img, tx, base - 10, tw + 4, 15, soft=4)
        disc(img, tx - tw // 2, base - 4, tw // 2 + 2, 15, soft=3)
        disc(img, tx + tw // 2, base - 4, tw // 2 + 2, 15, soft=3)
    # 地面(月光草地)
    vgrad(img, 56, H, [(0.0, 15), (1.0, 3)])
    for i in range(40):
        gx = int(noise(i, 20, 11) * W)
        gy = 56 + int(noise(i, 21, 11) * 39)
        if noise(i, 22, 11) > 0.88:
            img[gy][gx] = 15

    # 三只史莱姆: 两小一大(史莱姆王)
    slime(img, 26, 80, 10, 6)
    slime(img, 100, 82, 9, 5)
    slime(img, 62, 76, 18, 11, king=True)

    # 萤火虫
    for i in range(8):
        fx = int(noise(i, 30, 11) * W)
        fy = 30 + int(noise(i, 31, 11) * 40)
        img[fy][fx] = 12
        if 0 < fx < W - 1 and 0 < fy < H - 1:
            img[fy - 1][fx] = 11 if noise(i, 32, 11) > 0.5 else img[fy - 1][fx]

    return img


# ----------------------------------------------------------------------------
# 3) 熔岩魔王 BOSS 战 —— 火山关卡头目
# ----------------------------------------------------------------------------
def scene_boss():
    img = [[0] * W for _ in range(H)]

    # 灼热天空: 暗红 -> 橙
    vgrad(img, 0, 70, [(0.0, 6), (0.5, 8), (1.0, 9)])
    # 魔王背后的光环
    disc(img, 64, 40, 34, 8, soft=8)
    disc(img, 64, 40, 24, 9, soft=6)
    disc(img, 64, 40, 15, 10, soft=4)

    # 翼(暗红, 左右展开)
    tri(img, (40, 34), (8, 18), (36, 56), 6)
    tri(img, (88, 34), (120, 18), (92, 56), 6)
    tri(img, (36, 40), (16, 30), (34, 52), 7)
    tri(img, (92, 40), (112, 30), (94, 52), 7)

    # 身体
    ellipse(img, 64, 52, 16, 18, 7)
    ellipse(img, 58, 46, 6, 8, 8)              # 受光面
    # 头
    disc(img, 64, 28, 12, 7, soft=1)
    disc(img, 60, 24, 5, 8)                    # 头顶高光
    # 双角
    tri(img, (54, 20), (48, 6), (58, 18), 11)
    tri(img, (74, 20), (80, 6), (70, 18), 11)
    # 眼睛(黄, 竖瞳)
    for ex in (58, 70):
        for h in range(4):
            img[27 - h][ex] = 11
        img[28][ex] = 10
    # 嘴与獠牙
    for x in range(59, 70):
        img[33][x] = 0
    for tx in (60, 63, 66):
        img[34][tx] = 12
    # 胸口纹章
    disc(img, 64, 50, 3, 11)
    img[49][64] = 12

    # 爪(搭向画面前方)
    for sx in (44, 84):
        for h in range(3):
            img[64 - h * 2][sx + h - 1] = 7
        img[66][sx - 1] = 11
        img[66][sx + 1] = 11

    # 熔岩地面
    vgrad(img, 70, H, [(0.0, 8), (0.35, 6), (1.0, 6)])
    # 熔岩裂纹(亮色脉络)
    for i in range(6):
        vx = 8 + i * 22 + int(noise(i, 40, 11) * 8)
        vy = 72
        while vy < H:
            img[vy][vx] = 9 if noise(vx, vy, 3) > 0.7 else 11
            if vy > 78 and noise(vx, vy, 5) > 0.85:
                img[vy][vx] = 10
            vx += int(noise(vx, vy, 7) * 5) - 2
            vx = clamp(vx, 1, W - 2)
            vy += 2
    # 熔岩池
    disc(img, 22, 90, 9, 10, soft=2)
    disc(img, 104, 92, 11, 10, soft=2)
    disc(img, 22, 90, 5, 11)
    disc(img, 104, 92, 6, 11)
    # 飞散火星
    for i in range(14):
        sx = int(noise(i, 50, 11) * W)
        sy = int(noise(i, 51, 11) * 60)
        if noise(i, 52, 11) > 0.45:
            img[sy][sx] = 11 if noise(i, 53, 11) > 0.6 else 9

    return img


# ----------------------------------------------------------------------------
# 4) 勇者与落日 —— 冒险终点的剪影
# ----------------------------------------------------------------------------
def scene_hero():
    img = [[0] * W for _ in range(H)]

    # 落日天空
    vgrad(img, 0, 72, [(0.0, 6), (0.35, 8), (0.7, 9), (1.0, 11)])
    # 太阳(低垂在地平线上)
    disc(img, 56, 60, 11, 11, soft=3)
    disc(img, 56, 60, 7, 10)
    img[60][56] = 12

    # 远山剪影(暗红)
    for x in range(W):
        hm = 9 * math.sin(x / 21.0 + 0.7) + 5 * math.sin(x / 9.0 + 2.1)
        top = int(62 - abs(hm))
        for y in range(max(0, top), 72):
            img[y][x] = 6

    # 前景崖地(暗棕)
    vgrad(img, 72, H, [(0.0, 4), (1.0, 4)])
    for i in range(50):
        gx = int(noise(i, 60, 11) * W)
        gy = 72 + int(noise(i, 61, 11) * 23)
        if noise(i, 62, 11) > 0.9:
            img[gy][gx] = 5
    # 崖边凸起(勇者站立的岬角)
    tri(img, (70, 96), (104, 96), (104, 66), 4)
    tri(img, (70, 96), (104, 78), (104, 96), 0)
    line(img, 70, 96, 104, 66, 5)

    # ---- 勇者剪影(黑, 站在崖角, 举剑指天) ----
    hx, hy = 92, 66                     # 脚下基点
    # 腿
    for x in (hx - 2, hx + 2):
        line(img, hx, hy - 1, x, hy - 9, 0, 1)
    # 躯干与披风
    for y in range(hy - 17, hy - 8):
        for x in range(hx - 3, hx + 4):
            img[y][x] = 0
    tri(img, (hx - 3, hy - 17), (hx - 10, hy - 4), (hx - 3, hy - 8), 0)
    # 头
    disc(img, hx, hy - 20, 3, 0)
    # 举剑(白, 斜指天空)
    line(img, hx + 2, hy - 16, hx + 9, hy - 26, 12, 1)
    line(img, hx + 3, hy - 16, hx + 10, hy - 26, 13, 1)
    # 护手
    line(img, hx + 1, hy - 17, hx + 5, hy - 17, 13, 1)
    # 剑尖闪光
    for d in ((0, 2), (0, -2), (2, 0), (-2, 0)):
        x, y = hx + 10 + d[0], hy - 28 + d[1]
        if 0 <= x < W and 0 <= y < H:
            img[y][x] = 12

    # 归鸟
    for bx, by in ((22, 24), (32, 18), (40, 28), (96, 14)):
        img[by][bx] = 0
        img[by - 1][bx - 2] = 0
        img[by - 1][bx + 2] = 0
        img[by][bx - 1] = 0
        img[by][bx + 1] = 0

    return img


# ----------------------------------------------------------------------------
SCENES = [scene_camp, scene_slime, scene_boss, scene_hero]
NAMES = ["camp", "slime", "boss", "hero"]


def write_hex(frames, path):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for img in frames:
            for y in range(H):
                row = img[y]
                for x in range(0, W, 2):
                    f.write("%02x\n" % ((row[x] << 4) | row[x + 1]))


def write_png(rgb_rows, path, scale=4):
    """最简 PNG 编码器（真彩 8bit），scale 倍放大，纯标准库"""
    h = len(rgb_rows) * scale
    w = len(rgb_rows[0]) * scale
    raw = bytearray()
    for row in rgb_rows:
        line = bytearray()
        for r, g, b in row:
            line += bytes((r, g, b)) * scale
        for _ in range(scale):
            raw += b"\x00" + line

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def rgb565_to_rgb888(c):
    r = (c >> 11) & 0x1F
    g = (c >> 5) & 0x3F
    b = c & 0x1F
    return (r * 255 // 31, g * 255 // 63, b * 255 // 31)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    gen = os.path.join(root, "rtl", "gen")
    out = os.path.join(root, "tools", "out")
    os.makedirs(out, exist_ok=True)

    frames = [fn() for fn in SCENES]
    for img, name in zip(frames, NAMES):
        rows = [[rgb565_to_rgb888(PALETTE[i]) for i in row] for row in img]
        write_png(rows, os.path.join(out, "photo_%s.png" % name))
    write_hex(frames, os.path.join(gen, "photo.hex"))
    total = W * H // 2 * FRAMES
    print("photo.hex: %d bytes (%d frames of %dx%d 4bpp)" % (total, FRAMES, W, H))
    print("preview  : %s" % out)


if __name__ == "__main__":
    main()

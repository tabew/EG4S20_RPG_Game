# -*- coding: utf-8 -*-
"""
make_intro.py —— 开机入场动画的美术资源（魔法剑士登场）

产物（先只出预览，视觉确认后再进 RTL）:
    tools/out/intro_f0..3.png    人物精灵 4 帧 (64x96 4bpp, 3 倍放大预览)
    tools/out/intro_scr0..2.png  整屏构图预览 640x480 (滑入 / 举剑 / 爆光)

设计:
    16 色调色板 —— 深蓝夜色背景 + 钢灰盔甲 + 暗红披风 + 青白剑刃 + 金橙魔法焰
    人物 64x96，显示时 3 倍放大 192x288；4 帧: 站立 -> 抬剑 -> 举剑 -> 举剑爆光
    全部几何图元绘制，不依赖外部素材
"""
import math, os, zlib, struct

HW, HH = 64, 96          # 精灵尺寸
SW, SH = 640, 480        # 屏幕

PAL = [
    0x00000000,  # 0  黑
    0x0A1020,    # 1  深夜蓝(背景)
    0x14264A,    # 2  藏蓝
    0x24407A,    # 3  蓝
    0x2F2F3A,    # 4  暗甲
    0x4A4A5C,    # 5  甲
    0x7A7A8C,    # 6  亮甲
    0xB8BCC8,    # 7  高光甲
    0x6B1F1F,    # 8  暗红披风
    0xA83030,    # 9  红披风
    0xFF8A20,    # 10 魔焰橙
    0xFFD24A,    # 11 魔焰黄
    0xFFFFFF,    # 12 白
    0x5FD0FF,    # 13 剑刃青
    0x8A5A2A,    # 14 金饰
    0x1A2A18,    # 15 暗绿(地面)
]


def to565(c):
    r = (c >> 16) & 255
    g = (c >> 8) & 255
    b = c & 255
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def rgb565_to_rgb888(c):
    r = (c >> 11) & 0x1F
    g = (c >> 5) & 0x3F
    b = c & 0x1F
    return ((r * 255) // 31, (g * 255) // 63, (b * 255) // 31)


class Cv:
    def __init__(self, w, h, fill=0):
        self.w, self.h = w, h
        self.p = [[fill] * w for _ in range(h)]

    def put(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.p[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(self.h, y1 + 1)):
            for x in range(max(0, x0), min(self.w, x1 + 1)):
                self.p[y][x] = c

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(int(cy - ry) - 1, int(cy + ry) + 2):
            for x in range(int(cx - rx) - 1, int(cx + rx) + 2):
                dx = (x - cx) / max(0.001, rx)
                dy = (y - cy) / max(0.001, ry)
                if dx * dx + dy * dy <= 1.0:
                    self.put(x, y, c)

    def tri(self, p0, p1, p2, c):
        def s(a, b, p):
            return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
        xs = [p0[0], p1[0], p2[0]]
        ys = [p0[1], p1[1], p2[1]]
        for y in range(max(0, min(ys)), min(self.h, max(ys) + 1)):
            for x in range(max(0, min(xs)), min(self.w, max(xs) + 1)):
                d1, d2, d3 = s(p0, p1, (x, y)), s(p1, p2, (x, y)), s(p2, p0, (x, y))
                if not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0)):
                    self.p[y][x] = c

    def line(self, x0, y0, x1, y1, c, w=1):
        n = max(abs(int(x1) - int(x0)), abs(int(y1) - int(y0)), 1)
        for i in range(n + 1):
            t = i / n
            x = int(round(x0 + (x1 - x0) * t))
            y = int(round(y0 + (y1 - y0) * t))
            for dy in range(w):
                for dx in range(w):
                    self.put(x + dx, y + dy, c)


def flame(cv, cx, cy, r, outer=10, mid=11, core=12, seed=1):
    """魔法火焰: 三层同心 + 噪声抖动"""
    for y in range(int(cy - r) - 2, int(cy + r) + 3):
        for x in range(int(cx - r) - 2, int(cx + r) + 3):
            d = math.hypot(x - cx, (y - cy) * 0.85)
            n = ((x * 73856093) ^ (y * 19349663) ^ (seed * 83492791)) & 0xFF
            j = (n % 7) / 7.0
            if d <= r * (0.80 + j * 0.30):
                c = outer
                if d <= r * 0.62:
                    c = mid
                if d <= r * 0.32:
                    c = core
                cv.put(x, y, c)


def hero(frame):
    """frame 0..3: 站立 / 抬剑 / 举剑 / 举剑+爆光"""
    cv = Cv(HW, HH, 9)      # 9 = 透明标记, 合成时跳过
    cx = 30                 # 身体中轴

    # ---------- 披风(身后, 窄) ----------
    wave = [0, 2, 4, 5][frame]
    cv.tri((cx - 4, 40), (cx - 11 - wave, 82), (cx + 1, 80), 8)
    cv.tri((cx - 4, 40), (cx - 8 - wave, 80), (cx, 80), 9)
    cv.tri((cx + 5, 40), (cx + 11 + wave, 82), (cx + 1, 80), 8)

    # ---------- 腿 ----------
    for lx, swing in ((cx - 6, 2), (cx + 6, -2)):
        cv.line(lx, 74, lx + swing, 89, 4, 4)
        cv.line(lx, 74, lx + swing, 89, 5, 2)
    cv.rect(cx - 9, 87, cx - 2, 90, 4)      # 左脚
    cv.rect(cx + 4, 87, cx + 11, 90, 4)     # 右脚

    # ---------- 躯干 ----------
    cv.tri((cx - 9, 40), (cx + 9, 40), (cx, 74), 5)       # 胸甲
    cv.tri((cx - 6, 42), (cx + 6, 42), (cx, 66), 6)
    cv.line(cx, 46, cx, 68, 4)                            # 中缝
    cv.rect(cx - 9, 58, cx + 9, 60, 14)                   # 腰带(金)
    cv.put(cx, 59, 11)

    # ---------- 肩甲 ----------
    cv.ellipse(cx - 10, 43, 5, 4, 5)
    cv.ellipse(cx + 10, 43, 5, 4, 6)
    cv.put(cx - 12, 41, 6)
    cv.put(cx + 12, 41, 7)

    # ---------- 头 / 头盔 ----------
    cv.ellipse(cx, 29, 7, 8, 5)
    cv.ellipse(cx, 28, 6, 7, 6)          # 面甲
    cv.rect(cx - 5, 28, cx + 5, 30, 0)   # 面窗
    cv.put(cx - 3, 29, 13)
    cv.put(cx + 3, 29, 13)
    cv.rect(cx - 6, 22, cx + 6, 23, 14)  # 盔沿(金)

    # ---------- 右手(持剑) 与剑 ----------
    # ang: 0=竖直向上, 90=水平; f0 垂剑(≈170 向下), f1 斜举, f2/f3 高举
    if frame < 2:
        ang = [170, 25][frame]
        blen = [32, 36][frame]
        hx, hy = cx + 11, 60
    else:
        ang = 8
        blen = 36
        hx, hy = cx + 9, 50
        cv.line(cx + 10, 45, hx, hy, 5, 2)      # 抬臂
    rad = math.radians(ang)
    tx = hx + blen * math.sin(rad)
    ty = hy - blen * math.cos(rad)
    # 护手
    cv.line(int(hx - 4 * math.cos(rad)), int(hy - 4 * math.sin(rad)),
            int(hx + 4 * math.cos(rad)), int(hy + 4 * math.sin(rad)), 14, 2)
    # 刃(青白) + 白色中脊 —— 先画刃再叠焰, 焰小而贴, 不盖刃
    cv.line(hx, hy, tx, ty, 13, 2)
    cv.line(hx, hy, tx, ty, 12, 1)
    # 魔法焰贴刃
    n = [3, 4, 5, 7][frame]
    for i in range(n):
        t = (i + 1) / (n + 1.0)
        fx = hx + (tx - hx) * t
        fy = hy + (ty - hy) * t
        r = [2.2, 3.0, 4.2, 5.5][frame] * (1.1 - t * 0.45)
        flame(cv, fx, fy, r, seed=frame * 13 + i)
    # 剑柄
    cv.line(hx, hy, int(hx - 4 * math.sin(rad)), int(hy + 4 * math.cos(rad)), 14, 2)

    # ---------- 左手 ----------
    cv.ellipse(cx - 12, 62, 3, 3, 5)

    return cv


def screen(sprite, sx, sy, phase):
    """把精灵 3 倍放大贴到 640x480 屏幕上, 叠加背景光效"""
    sc = Cv(SW, SH, 1)
    # 背景: 全深蓝夜色
    for y in range(SH):
        for x in range(SW):
            sc.p[y][x] = 1
    # 中央光柱(很淡, 只在地面附近)
    for y in range(300, SH):
        t = (y - 300) / (SH - 300.0)
        w = int(50 + 60 * t)
        for x in range(SW // 2 - w, SW // 2 + w):
            if 0 <= x < SW and sc.p[y][x] == 1 and (x + y) % 3:
                sc.p[y][x] = 2
    # 星光(暗)
    for i in range(40):
        x = (i * 97 + 31) % SW
        y = (i * 53 + 17) % int(SH * 0.55)
        sc.p[y][x] = 3 if i % 4 else 6
    # 地面
    sc.rect(0, 452, SW - 1, SH - 1, 15)

    # 精灵 3x (9 = 透明)
    for y in range(HH):
        for x in range(HW):
            c = sprite.p[y][x]
            if c == 9:
                continue
            px, py = sx + x * 3, sy + y * 3
            if 0 <= px < SW - 2 and 0 <= py < SH - 2:
                sc.rect(px, py, px + 2, py + 2, c)
    return sc


def write_png(rows, path, scale=1):
    h, w = len(rows) * scale, len(rows[0]) * scale
    raw = bytearray()
    for row in rows:
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


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "tools", "out")
    os.makedirs(out, exist_ok=True)

    frames = [hero(i) for i in range(4)]
    for i, cv in enumerate(frames):
        rows = [[rgb565_to_rgb888(to565(PAL[3 if c == 9 else c])) for c in row] for row in cv.p]
        write_png(rows, os.path.join(out, "intro_f%d.png" % i), 4)

    # 整屏构图: 滑入(偏下) / 举剑定格 / 爆光
    shots = [(320 - HW * 3 // 2, 150, 1), (320 - HW * 3 // 2, 120, 2), (320 - HW * 3 // 2, 120, 3)]
    for i, (sx, sy, f) in enumerate(shots):
        sc = screen(frames[f], sx, sy, i)
        rows = [[rgb565_to_rgb888(to565(PAL[c])) for c in row] for row in sc.p]
        write_png(rows, os.path.join(out, "intro_scr%d.png" % i))
    print("intro preview: %s" % out)


if __name__ == "__main__":
    main()

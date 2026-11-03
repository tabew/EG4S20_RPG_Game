# -*- coding: utf-8 -*-
"""
make_monsters.py —— 生成 25 张怪物立绘（48x48 / 4bpp，每只独立 16 色调色板）

产物:
    rtl/gen/mon.hex       25 张立绘像素，每行 1 字节（一个字节 2 像素）
    rtl/gen/monpal.hex    25 x 16 色，每行 1 个 RGB565
    rtl/gen/mon_rom.v     两个 BRAM + 参数

显示时 3 倍放大到 144x144（正好 9x9 个字符格），嵌在战斗界面里。
淡入淡出不在这一层做：调色板只有 16 项，改缩放系数重新算一遍就行，零逐像素开销。

全部用几何图元画，不依赖任何图片素材和 PIL。
"""
import math, os

W, H = 48, 48
NUM = 25

# ══════════════════════════════════════════════════════════════
# 调色板：从主色/副色/眼睛色派生 16 阶
# ══════════════════════════════════════════════════════════════
def scale(c, k):
    r = min(255, int(((c >> 16) & 255) * k))
    g = min(255, int(((c >> 8) & 255) * k))
    b = min(255, int((c & 255) * k))
    return (r << 16) | (g << 8) | b


def to565(c):
    r = (c >> 16) & 255
    g = (c >> 8) & 255
    b = c & 255
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


def make_pal(body, accent, eye):
    return [to565(c) for c in (
        0x000000,
        scale(body, 0.30), scale(body, 0.50), scale(body, 0.75), body,
        scale(accent, 0.45), scale(accent, 0.72), scale(accent, 1.0),
        0xFFFFFF, eye,
        0x1A1A1A, 0x5A5A5A,
        scale(body, 0.90), scale(accent, 0.90), 0xE8E8E8, 0x101010,
    )]


# ══════════════════════════════════════════════════════════════
# 画布与图元
# ══════════════════════════════════════════════════════════════
class Canvas:
    def __init__(self):
        self.p = [[0] * W for _ in range(H)]

    def put(self, x, y, c):
        if 0 <= x < W and 0 <= y < H:
            self.p[y][x] = c

    def ellipse(self, cx, cy, rx, ry, c, shade=True, light=-1):
        for y in range(H):
            for x in range(W):
                dx = (x - cx) / rx
                dy = (y - cy) / ry
                d = dx * dx + dy * dy
                if d <= 1.0:
                    col = c
                    if shade:
                        # 左上受光：用主色的 4 档做明暗
                        t = (-dx * 0.55 - dy * 0.55) if light < 0 else (dx * 0.55 + dy * 0.55)
                        if t > 0.45:
                            col = c + 1
                        elif t < -0.35:
                            col = c - 1
                        if d > 0.80:
                            col = max(1, c - 1)          # 边缘压暗
                    self.p[y][x] = col

    def rect(self, x0, y0, x1, y1, c):
        for y in range(max(0, y0), min(H, y1 + 1)):
            for x in range(max(0, x0), min(W, x1 + 1)):
                self.p[y][x] = c

    def tri(self, p0, p1, p2, c):
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
                    self.p[y][x] = c

    def line(self, x0, y0, x1, y1, c, w=1):
        n = max(abs(x1-x0), abs(y1-y0), 1)
        for i in range(n + 1):
            t = i / n
            x = int(x0 + (x1-x0)*t)
            y = int(y0 + (y1-y0)*t)
            for k in range(w):
                self.put(x + k, y, c)

    def eyes(self, x1, x2, y, c=9, white=True):
        if white:
            self.rect(x1-1, y-1, x1+2, y+2, 8)
            self.rect(x2-1, y-1, x2+2, y+2, 8)
        self.put(x1, y, c); self.put(x1, y+1, c)
        self.put(x2, y, c); self.put(x2, y+1, c)


# ══════════════════════════════════════════════════════════════
# 25 只怪物
# ══════════════════════════════════════════════════════════════
def m_slime(cv, big=False):
    r = 15 if big else 12
    cv.ellipse(24, 32, r, r, 3)
    cv.ellipse(24, 30, r-3, r-4, 4)
    cv.eyes(19, 28, 27)
    if big:
        for i, dx in enumerate((-9, -3, 3, 9)):
            cv.tri((24+dx, 12), (24+dx-3, 5), (24+dx+3, 5), 7)
        cv.rect(14, 11, 34, 13, 6)


def m_rabbit(cv):
    cv.ellipse(24, 34, 11, 9, 3)
    cv.ellipse(30, 22, 7, 7, 4)
    cv.ellipse(29, 11, 2, 8, 4)          # 耳朵
    cv.ellipse(34, 12, 2, 7, 3)
    cv.ellipse(18, 32, 5, 5, 4)          # 尾巴
    cv.eyes(28, 33, 21)
    cv.rect(33, 25, 35, 25, 9)


def m_mouse(cv):
    cv.ellipse(24, 35, 10, 8, 3)
    cv.ellipse(31, 26, 6, 6, 4)
    cv.ellipse(27, 20, 3, 3, 4)          # 大耳朵
    cv.ellipse(35, 21, 3, 3, 4)
    cv.line(14, 34, 7, 28, 2)            # 尾巴
    cv.eyes(29, 34, 25)


def m_swarm(cv):
    for (x, y, r) in ((14, 26, 6), (30, 20, 5), (34, 34, 6), (18, 38, 4), (40, 27, 4)):
        cv.ellipse(x, y, r, r-1, 3)
        cv.ellipse(x, y-1, r-2, r-3, 4)
        cv.line(x-2, y-2, x-2, y-4, 10)
        cv.line(x+2, y-2, x+2, y-4, 10)
    cv.ellipse(24, 30, 3, 3, 9)


def m_wolf(cv):
    cv.ellipse(24, 32, 14, 8, 3)         # 身体
    cv.ellipse(35, 22, 7, 7, 4)          # 头
    cv.tri((30, 16), (32, 9), (35, 15), 3)
    cv.tri((37, 16), (39, 9), (42, 15), 3)
    cv.tri((41, 22), (47, 24), (41, 26), 2)   # 吻部
    for x in (14, 20, 28, 34):           # 腿
        cv.rect(x, 38, x+2, 44, 2)
    cv.line(10, 30, 4, 24, 3, 2)         # 尾巴
    cv.eyes(33, 38, 21)


def m_treant(cv):
    cv.rect(20, 20, 27, 45, 2)           # 树干
    cv.ellipse(24, 16, 13, 11, 4)        # 树冠
    cv.ellipse(16, 22, 8, 7, 3)
    cv.ellipse(32, 22, 8, 7, 3)
    cv.line(20, 30, 12, 24, 2, 2)        # 枝
    cv.line(27, 32, 36, 26, 2, 2)
    cv.eyes(21, 26, 14)


def m_bat(cv, big=False):
    span = 24 if big else 16
    cv.tri((24, 20), (24-span, 12), (24-span+4, 34), 3)
    cv.tri((24, 20), (24+span, 12), (24+span-4, 34), 3)
    cv.ellipse(24, 26, 8, 10, 4)
    cv.tri((19, 18), (18, 11), (23, 17), 3)
    cv.tri((29, 18), (30, 11), (25, 17), 3)
    cv.eyes(20, 27, 24)
    cv.rect(22, 30, 23, 32, 8)           # 牙
    cv.rect(25, 30, 26, 32, 8)


def m_vine(cv):
    for i, x in enumerate((12, 20, 28, 36)):
        for y in range(6, 46):
            xx = int(x + 3 * math.sin(y / 6.0 + i))
            cv.put(xx, y, 3 if (y + i) % 5 else 4)
            if y % 7 == 0:
                cv.put(xx-1, y, 3); cv.put(xx+1, y, 3)
    cv.ellipse(24, 24, 6, 6, 4)
    cv.eyes(22, 26, 23)


def m_warden(cv):
    cv.rect(20, 24, 27, 46, 2)           # 躯干
    cv.ellipse(24, 16, 8, 8, 4)          # 头
    cv.line(18, 26, 10, 20, 2, 2)
    cv.line(30, 26, 38, 20, 2, 2)
    # 鹿角
    cv.line(20, 10, 14, 2, 6, 2)
    cv.line(14, 2, 10, 0, 6, 2)
    cv.line(28, 10, 34, 2, 6, 2)
    cv.line(34, 2, 38, 0, 6, 2)
    cv.eyes(21, 26, 15)


def m_golem(cv):
    cv.rect(14, 18, 33, 40, 3)           # 身体
    cv.rect(18, 8, 29, 17, 4)            # 头
    cv.rect(8, 20, 13, 36, 2)            # 手臂
    cv.rect(34, 20, 39, 36, 2)
    cv.rect(16, 40, 21, 46, 2)
    cv.rect(27, 40, 32, 46, 2)
    for (x, y) in ((18, 22), (26, 26), (21, 32), (30, 34)):
        cv.rect(x, y, x+2, y+2, 11)
    cv.eyes(19, 26, 12)


def m_spider(cv):
    cv.ellipse(24, 30, 10, 8, 3)
    cv.ellipse(24, 20, 6, 5, 4)
    for s in (-1, 1):
        for k, y in enumerate((18, 24, 30, 36)):
            cv.line(24 + s*8, 28, 24 + s*(20 - k), y - 6, 2, 1)
    cv.eyes(20, 27, 19)
    cv.rect(22, 14, 23, 16, 9)
    cv.rect(25, 14, 26, 16, 9)


def m_ghost(cv, miner=False):
    cv.ellipse(24, 24, 13, 15, 3)
    cv.rect(11, 30, 37, 40, 3)
    for i, x in enumerate((12, 18, 24, 30, 36)):   # 下摆
        cv.ellipse(x, 40, 3, 4, 3)
    cv.ellipse(24, 22, 10, 11, 4)
    cv.eyes(19, 28, 20)
    if miner:
        cv.ellipse(24, 12, 9, 4, 6)                # 矿工帽
        cv.rect(22, 6, 26, 12, 6)
        cv.ellipse(24, 6, 2, 2, 7)                 # 矿灯


def m_troll(cv):
    cv.rect(16, 22, 32, 42, 3)
    cv.ellipse(24, 16, 10, 9, 4)
    cv.rect(8, 24, 15, 40, 2)
    cv.rect(33, 24, 40, 40, 2)
    cv.rect(17, 42, 22, 47, 2)
    cv.rect(27, 42, 32, 47, 2)
    cv.tri((16, 9), (13, 2), (20, 8), 6)           # 角
    cv.tri((32, 9), (35, 2), (28, 8), 6)
    cv.eyes(20, 27, 15)
    cv.rect(21, 20, 27, 21, 10)                     # 嘴


def m_lizard(cv):
    cv.ellipse(22, 30, 14, 9, 3)
    cv.ellipse(34, 24, 7, 6, 4)
    cv.line(8, 30, 0, 24, 2, 2)                     # 尾巴
    for x in (14, 20, 26, 32):
        cv.rect(x, 36, x+2, 42, 2)
    for (x, y) in ((12, 26), (18, 24), (24, 27), (30, 26)):
        cv.rect(x, y, x+2, y+1, 6)
    cv.eyes(33, 37, 22)
    cv.line(34, 18, 38, 12, 6, 1)


def m_lavagolem(cv):
    cv.rect(15, 18, 33, 42, 2)
    cv.rect(18, 7, 30, 17, 3)
    cv.rect(8, 22, 14, 38, 2)
    cv.rect(34, 22, 40, 38, 2)
    cv.rect(17, 42, 22, 47, 2)
    cv.rect(27, 42, 32, 47, 2)
    for (x, y, w) in ((19, 21, 9), (17, 27, 6), (25, 33, 7), (21, 12, 7), (28, 24, 4)):
        cv.rect(x, y, x+w, y+1, 7)                  # 熔岩缝
    cv.rect(21, 26, 27, 31, 6)                      # 胸口熔岩口
    cv.rect(22, 27, 26, 30, 7)
    cv.tri((16, 8), (13, 1), (21, 7), 6)            # 岩角
    cv.tri((32, 8), (35, 1), (27, 7), 6)
    cv.eyes(20, 27, 12)


def m_flame(cv):
    # 三个火舌：中间高、两侧矮，用椭圆叠出圆润的轮廓
    for (cx, base, top, wmax) in ((24, 46, 4, 9), (15, 44, 16, 6), (33, 44, 18, 6)):
        for y in range(top, base + 1):
            t = (y - top) / float(base - top)
            w = int(wmax * (0.35 + 0.65 * t))
            col = 7 if t > 0.55 else 6
            cv.rect(cx - w, y, cx + w, y, col)
    # 焰心
    cv.ellipse(24, 38, 5, 7, 7)
    cv.ellipse(24, 40, 3, 4, 4)
    cv.ellipse(15, 40, 3, 4, 7)
    cv.ellipse(33, 40, 3, 4, 7)
    cv.eyes(21, 26, 33)


def m_bird(cv):
    cv.ellipse(24, 30, 10, 12, 3)
    cv.tri((14, 26), (0, 12), (14, 38), 2)          # 翅膀
    cv.tri((34, 26), (47, 12), (34, 38), 2)
    cv.ellipse(24, 16, 6, 6, 4)
    cv.tri((30, 15), (39, 17), (30, 19), 7)         # 喙
    cv.eyes(22, 27, 14)
    cv.line(20, 42, 18, 47, 7, 2)


def m_demon(cv):
    cv.ellipse(24, 30, 13, 14, 3)
    cv.ellipse(24, 14, 9, 8, 4)
    cv.tri((15, 8), (9, 0), (20, 6), 6)             # 大角
    cv.tri((33, 8), (39, 0), (28, 6), 6)
    cv.tri((16, 30), (2, 24), (16, 40), 2)          # 翼
    cv.tri((32, 30), (46, 24), (32, 40), 2)
    cv.eyes(20, 27, 13)
    cv.rect(21, 20, 27, 21, 9)


def m_knight(cv):
    cv.rect(17, 20, 31, 42, 3)                      # 铠甲
    cv.rect(19, 8, 29, 20, 4)                       # 头盔
    cv.rect(21, 13, 27, 15, 9)                      # 面罩缝
    cv.rect(9, 22, 16, 38, 2)
    cv.rect(32, 22, 39, 38, 2)
    cv.rect(18, 42, 23, 47, 2)
    cv.rect(25, 42, 30, 47, 2)
    cv.rect(22, 4, 26, 8, 6)                        # 盔缨
    cv.line(34, 40, 34, 16, 6, 2)                   # 剑
    cv.line(31, 34, 38, 34, 6, 2)


def m_skeleton(cv):
    cv.ellipse(24, 13, 8, 8, 14)                    # 头骨
    cv.rect(20, 16, 23, 20, 14)
    cv.rect(25, 16, 28, 20, 14)
    cv.rect(22, 22, 26, 38, 14)                     # 脊柱
    for y in (25, 29, 33):
        cv.rect(16, y, 32, y+1, 14)
    cv.rect(17, 38, 21, 46, 14)
    cv.rect(27, 38, 31, 46, 14)
    cv.ellipse(20, 12, 2, 2, 9)
    cv.ellipse(28, 12, 2, 2, 9)
    cv.line(36, 44, 36, 12, 6, 2)                   # 法杖
    cv.ellipse(36, 9, 3, 3, 7)


def m_servant(cv):
    cv.ellipse(24, 34, 13, 11, 3)
    cv.ellipse(24, 18, 7, 7, 4)
    cv.ellipse(14, 12, 3, 5, 2)                     # 耳朵
    cv.ellipse(34, 12, 3, 5, 2)
    cv.rect(12, 36, 36, 46, 6)                      # 斗篷
    cv.eyes(21, 27, 17)
    cv.rect(22, 22, 23, 24, 8)                      # 獠牙
    cv.rect(25, 22, 26, 24, 8)


def m_shadow(cv):
    cv.ellipse(24, 26, 14, 16, 1)
    cv.ellipse(24, 24, 11, 13, 2)
    for i, x in enumerate((14, 21, 28, 35)):
        cv.ellipse(x, 40, 3, 5, 1)
    cv.ellipse(19, 22, 3, 2, 9)
    cv.ellipse(29, 22, 3, 2, 9)


def m_lord(cv):
    cv.ellipse(24, 30, 15, 15, 2)
    cv.ellipse(24, 13, 9, 8, 3)
    cv.tri((14, 7), (6, 0), (20, 4), 6)
    cv.tri((34, 7), (42, 0), (28, 4), 6)
    cv.tri((12, 30), (0, 20), (12, 42), 1)
    cv.tri((36, 30), (48, 20), (36, 42), 1)
    cv.eyes(20, 27, 11)
    cv.rect(21, 19, 27, 20, 9)
    for x in (18, 24, 30):                          # 胸前尖刺
        cv.tri((x, 26), (x+2, 20), (x+4, 26), 7)


SPECS = [
    ("史莱姆",   0x3CB44B, 0x9BE07A, 0x112211, lambda c: m_slime(c)),
    ("野兔",     0xB0A090, 0xE8E0D0, 0x7A2A2A, lambda c: m_rabbit(c)),
    ("田鼠",     0x8A7C6A, 0xC8BAA4, 0x2A1A1A, lambda c: m_mouse(c)),
    ("蜂群",     0xE8B020, 0x3A2A0A, 0x1A1A1A, lambda c: m_swarm(c)),
    ("史莱姆王", 0x2A9A3A, 0xFFD24A, 0x0A1A0A, lambda c: m_slime(c, True)),
    ("灰狼",     0x707A88, 0xC8D0DC, 0xC03A2A, lambda c: m_wolf(c)),
    ("树精",     0x4A6A2A, 0x8FBF52, 0x2A3A10, lambda c: m_treant(c)),
    ("毒蝠",     0x6A3A8A, 0xB07ADC, 0xC8E020, lambda c: m_bat(c)),
    ("藤蔓",     0x2A6A3A, 0x6AC87A, 0x1A2A10, lambda c: m_vine(c)),
    ("森林守望者", 0x3A6A2A, 0xC8B060, 0xE0E0A0, lambda c: m_warden(c)),
    ("石魔",     0x7A7A80, 0xB8B8C0, 0xE05020, lambda c: m_golem(c)),
    ("岩蜘蛛",   0x5A5048, 0x9A8A7A, 0xE03010, lambda c: m_spider(c)),
    ("矿工幽灵", 0x8A9AB0, 0xE8F0FF, 0x60E0FF, lambda c: m_ghost(c, True)),
    ("洞穴蝙蝠", 0x4A3A5A, 0x9A7AB0, 0xE0C020, lambda c: m_bat(c)),
    ("矿洞巨魔", 0x6A5A4A, 0xA89A80, 0xE04020, lambda c: m_troll(c)),
    ("火蜥蜴",   0xD05A20, 0xFFD040, 0x1A1A0A, lambda c: m_lizard(c)),
    ("熔岩傀儡", 0x8A2A10, 0xFFB020, 0xFFE060, lambda c: m_lavagolem(c)),
    ("火元素",   0xE06010, 0xFFE040, 0x3A0A00, lambda c: m_flame(c)),
    ("灰烬鸟",   0x8A7A70, 0xD8C8B8, 0xE06030, lambda c: m_bird(c)),
    ("熔岩魔王", 0xA02010, 0xFFC030, 0xFFF0A0, lambda c: m_demon(c)),
    ("不死骑士", 0x4A4A58, 0x8A8AA0, 0xC03A2A, lambda c: m_knight(c)),
    ("骨法师",   0xD8D0B8, 0x8A7A5A, 0x60C0FF, lambda c: m_skeleton(c)),
    ("血仆",     0x8A2A3A, 0x3A1A20, 0xE0E0E0, lambda c: m_servant(c)),
    ("幽影",     0x2A2030, 0x50406A, 0xB060FF, lambda c: m_shadow(c)),
    ("深渊领主", 0x3A2A5A, 0x9A60E0, 0xFF6020, lambda c: m_lord(c)),
]


def pack(cv):
    out = []
    for y in range(H):
        for x in range(0, W, 2):
            out.append(((cv.p[y][x] & 0xF) << 4) | (cv.p[y][x+1] & 0xF))
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    gen = os.path.join(root, "rtl", "gen")
    os.makedirs(gen, exist_ok=True)

    pix, pals = [], []
    for (nm, body, accent, eye, fn) in SPECS:
        cv = Canvas()
        fn(cv)
        pix += pack(cv)
        pals += make_pal(body, accent, eye)

    per = W * H // 2
    assert len(pix) == per * NUM, (len(pix), per * NUM)
    assert len(pals) == 16 * NUM

    with open(os.path.join(gen, "mon.hex"), "w", encoding="ascii", newline="\n") as f:
        for b in pix:
            f.write("%02x\n" % b)
    with open(os.path.join(gen, "monpal.hex"), "w", encoding="ascii", newline="\n") as f:
        for c in pals:
            f.write("%04x\n" % c)

    v = """//=============================================================================
// mon_rom.v —— 怪物立绘（由 tools/make_monsters.py 生成，不要手改）
//
//   {num} 张 x {w}x{h}，4bpp（每字节 2 像素，高半字节在前）
//   像素 {np} 字节 = {kb:.0f} Kbit；调色板 {num} x 16 色
//   显示时 3 倍放大 -> {dw}x{dh} 像素（正好 9x9 个字符格）
//=============================================================================
`timescale 1ns/1ps
module mon_rom (
    input  wire        clk,
    input  wire [14:0] addr,      // 0 .. {lastp}
    output reg  [7:0]  data,
    input  wire [9:0]  paddr,     // 0 .. {lastc}  (编号*16 + 色号)
    output reg  [15:0] pal
);
    reg [7:0]  mem  [0:{lastp}];
    reg [15:0] pmem [0:{lastc}];

    initial $readmemh("rtl/gen/mon.hex", mem);
    initial $readmemh("rtl/gen/monpal.hex", pmem);

    always @(posedge clk) data <= mem[addr];
    always @(posedge clk) pal  <= pmem[paddr];

endmodule
""".format(num=NUM, w=W, h=H, np=len(pix), kb=len(pix) * 8 / 1024.0,
           dw=W*3, dh=H*3, lastp=len(pix)-1, lastc=len(pals)-1)
    with open(os.path.join(gen, "mon_rom.v"), "w", encoding="utf-8", newline="\n") as f:
        f.write(v)

    print("怪物立绘生成完毕:")
    print("  %d 张 x %dx%d 4bpp，像素 %d 字节 (%.0f Kbit)"
          % (NUM, W, H, len(pix), len(pix) * 8 / 1024.0))
    print("  调色板 %d x 16 色" % NUM)
    print("  显示时 3 倍放大 -> %dx%d" % (W*3, H*3))


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""逐位复刻 RTL 的定点实现, 验证零乘法器版 spec_bars

严格按 Verilog 语义: 固定位宽整数, >>> 对负数是 floor 除法 (Python >> 一致)
"""
import os

FS = 32000
BPM = 120
BTK = int(FS * 60 / (BPM * 4))          # 4000 采样 / 四分音符

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

rows = [int(l.strip(), 16) for l in open(os.path.join(ROOT, 'rtl/gen/music.hex')) if l.strip()]
pitch = [int(l.strip(), 16) for l in open(os.path.join(ROOT, 'rtl/gen/pitch.hex')) if l.strip()]

K = {
    150: [(1, 5), (-1, 9)],
    198: [(1, 5), (1, 7), (-1, 10)],
    262: [(1, 4), (-1, 6), (1, 8)],
    346: [(1, 4), (1, 8)],
    457: [(1, 3), (-1, 5), (-1, 7)],
    603: [(1, 3), (-1, 6), (1, 9)],
    797: [(1, 3), (1, 6), (1, 8)],
    1053: [(1, 2), (-1, 4)],
    1391: [(1, 2), (-1, 7)],
}
EDGES = [150, 198, 262, 346, 457, 603, 797, 1053, 1391]


def s12(v):
    v &= 0xFFF
    return v - 4096 if v & 0x800 else v


def sh(v, terms):
    return sum(s * (v >> k) for s, k in terms)


class Psg:
    """sound 模块三声部 PSG + 音符包络 + 2 点平均"""

    def __init__(self):
        self.si = 0
        self.left = max(1, (rows[0] >> 21) & 0x7F)
        self.n = [rows[0] & 0x7F, (rows[0] >> 7) & 0x7F, (rows[0] >> 14) & 0x7F]
        self.ph = [0, 0, 0]
        self.env = [0x3FFFF] * 3
        self.beat = 0
        self.dprev = 128
        self._new = 1

    def step(self):
        self.beat += 1
        if self.beat >= BTK:
            self.beat = 0
            self.left -= 1
            if self.left <= 0:
                self.si = (self.si + 1) % 64
                self.left = max(1, (rows[self.si] >> 21) & 0x7F)
                self.n = [rows[self.si] & 0x7F,
                          (rows[self.si] >> 7) & 0x7F,
                          (rows[self.si] >> 14) & 0x7F]
                self._new = 1
        if self._new:
            self._new = 0
            self.env = [0x3FFFF] * 3
        else:
            self.env = [e - ((e >> 14) + 1) for e in self.env]

        for i in range(3):
            nid = self.n[i]
            stp = 0 if nid == 0x7F else pitch[nid]
            self.ph[i] = (self.ph[i] + stp) & 0xFFFFFF

        p = self.ph
        s0 = -52 if p[0] >= (1 << 23) else 52
        s1 = 28 if (p[1] >> 22) == 0 else -28
        tri = (~(p[2] >> 17) & 0x3F) if p[2] >= (1 << 23) else ((p[2] >> 17) & 0x3F)
        s2 = tri - 32
        g = [e >> 10 for e in self.env]
        mix = (s0 * g[0] >> 8) + (s1 * g[1] >> 8) + (s2 * g[2] >> 8)
        mix = 120 if mix > 120 else (-120 if mix < -120 else mix)
        dout = (mix + 128) & 0xFF
        dac = ((dout + self.dprev) >> 1) & 0xFF
        self.dprev = dout
        return dac


class Spec:
    def __init__(self):
        self.pl = [0, 0]
        self.h = [0] * 8
        self.l = [0] * 8
        self.xp = [0] * 8
        self.f = [0] * 8         # 12 位信号 + 4 位小数

    def step(self, pcm):
        xin = s12((pcm & 0xFF) - 128)

        self.pl[0] = self.pl[0] + (((xin << 2) - self.pl[0]) >> 2)
        self.pl[1] = self.pl[1] + ((self.pl[0] - self.pl[1]) >> 2)
        xs = self.pl[1] >> 2

        bars = []
        for i in range(8):
            lo, hi = EDGES[i], EDGES[i + 1]
            t = s12(self.h[i] + xs - self.xp[i])
            hp = s12(t - sh(t, K[lo]))
            d = s12(hp - self.l[i])
            y = s12(self.l[i] + sh(d, K[hi]))
            ab = ((~y + 1) & 0xFFF) if y < 0 else (y & 0xFFF)
            ax = (ab << 4) & 0xFFFF
            dv = ax - self.f[i]
            nf = self.f[i] + (dv >> 5)
            self.h[i] = hp
            self.l[i] = y
            self.xp[i] = xs
            self.f[i] = 0 if (nf < 0 or nf > 0xFFFF) else nf

        fsum = sum(self.f)
        favg = (fsum >> 3) & 0x1FFFF
        for i in range(8):
            d = 7 * self.f[i] - 6 * favg + 160     # 10 << 4
            d >>= 4
            bars.append(0 if d < 0 else min(120, d))
        return bars


def avg_bars(hist, tail_n=4000):
    t = hist[-tail_n:]
    return [sum(r[i] for r in t) / float(len(t)) for i in range(8)]


print("=== 单音扫描 (方波 52, 稳态平均柱高) ===")
print("    Hz |  0    1    2    3    4    5    6    7  | 峰值")
prev = -1
mono = True
for fr in (150, 200, 260, 340, 450, 600, 800, 1050, 1400):
    s = Spec()
    step = int(round(fr * (1 << 24) / FS))
    ph = 0
    dprev = 128
    hist = []
    for _ in range(16000):
        ph = (ph + step) & 0xFFFFFF
        s0 = -52 if ph >= (1 << 23) else 52
        dout = (s0 + 128) & 0xFF
        dac = ((dout + dprev) >> 1) & 0xFF
        dprev = dout
        hist.append(s.step(dac))
    a = avg_bars(hist)
    pk = a.index(max(a))
    if pk < prev:
        mono = False
    prev = pk
    print("  %5d | %s | seg%d" % (fr, " ".join("%4.0f" % v for v in a), pk))
print("   单调右移:", "通过" if mono else "不通过")

for tr in range(3):
    p = Psg()
    s = Spec()
    hist = [s.step(p.step()) for _ in range(int(12.0 * FS))]
    tail = hist[4000:]
    vals = [v for r in tail for v in r]
    print("\n=== 曲目 %d ===  柱高平均 %.1f  最大 %d  饱和 %.1f%%"
          % (tr, sum(vals) / float(len(vals)), max(vals),
             100.0 * sum(1 for v in vals if v >= 119) / len(vals)))
    print("时间曲线 (每 0.5s, 八根柱子):")
    for k in range(0, len(hist), 16000):
        print("  %5.2fs | %s" % (k / float(FS), " ".join("%3d" % v for v in hist[k])))
    same = tot = 0
    for a_, b_ in zip(tail, tail[1:]):
        d = [b_[i] - a_[i] for i in range(8)]
        nz = [x for x in d if x]
        if len(nz) >= 4:
            tot += 1
            pos = sum(1 for x in nz if x > 0)
            if pos >= len(nz) * 0.75 or pos <= len(nz) * 0.25:
                same += 1
    print("八根同向摆动: %.0f%%" % (100.0 * same / max(1, tot)))
